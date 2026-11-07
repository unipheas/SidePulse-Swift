import Foundation

final class TranscriptReader {
  struct Entry { let date: Date, size: Int, session: Session? }
  private var files = [URL: Entry]()
  private var nextScan = Date.distantPast
  func read(settings: JSONObject) -> [Session] {
    if Date() >= nextScan {
      nextScan = Date().addingTimeInterval(5)
      var next = [URL: Entry]()
      let enabled = settings["transcript_monitoring"] as? [String: Bool] ?? [:]
      for (provider, path) in [("codex", ".codex/sessions"), ("claude", ".claude/projects")]
      where enabled[provider] == true {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard
          let walker = FileManager.default.enumerator(
            at: Paths.home.appendingPathComponent(path), includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        else { continue }
        var recent = [(URL, Date, Int)]()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
          guard let info = try? url.resourceValues(forKeys: keys),
            let date = info.contentModificationDate,
            Date().timeIntervalSince(date) < 172800
          else { continue }
          recent.append((url, date, info.fileSize ?? 0))
        }
        for (url, date, size) in recent.sorted(by: { $0.1 > $1.1 }).prefix(
          provider == "claude" ? 24 : 12)
        {
          if let entry = files[url], entry.date == date, entry.size == size {
            next[url] = entry
          } else {
            next[url] = Entry(
              date: date, size: size, session: Self.last(url, provider: provider, size: size))
          }
        }
      }
      files = next
    }
    return files.values.compactMap(\.session)
  }
  static func last(_ url: URL, provider: String, size: Int) -> Session? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(max(0, size - 1_048_576)))
    guard let data = try? handle.read(upToCount: 1_048_576) else { return nil }
    let name = url.deletingPathExtension().lastPathComponent
    guard
      let range = name.range(
        of: #"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"#, options: .regularExpression)
    else { return nil }
    let id = String(name[range])
    var cwd: String?
    var latest: Session?
    for line in data.split(separator: 10).suffix(500) {
      guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject,
        let timestamp = row["timestamp"] as? String
      else { continue }
      let p = row["payload"] as? JSONObject ?? [:]
      let msg = row["message"] as? JSONObject ?? [:]
      cwd = (p["cwd"] ?? row["cwd"]) as? String ?? cwd
      let content = (p["content"] ?? msg["content"]) as? [JSONObject] ?? []
      var raw: JSONObject = ["session_id": id, "agent_origin": provider.capitalized + " app"]
      if let cwd { raw["cwd"] = cwd }
      switch (p["type"] ?? row["type"]) as? String {
      case "task_started", "user_message", "user":
        raw["hook_event_name"] =
          content.contains { $0["type"] as? String == "tool_result" }
          ? "PostToolUse" : "UserPromptSubmit"
        if content.contains(where: {
          $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool == true
        }) {
          raw["tool_response"] = ["success": false]
        }
        raw["prompt"] = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
      case "task_complete", "task_completed":
        raw["hook_event_name"] = "Stop"
        raw["last_assistant_message"] = p["last_agent_message"]
      case "turn_aborted": raw["hook_event_name"] = "Interrupt"
      case "function_call", "custom_tool_call": raw["hook_event_name"] = "PreToolUse"
      case "function_call_output", "custom_tool_call_output":
        raw["hook_event_name"] = "PostToolUse"
        raw["tool_response"] = p["output"]
      case "message", "assistant":
        if content.contains(where: { $0["type"] as? String == "tool_use" }) {
          raw["hook_event_name"] = "PreToolUse"
        } else if p["role"] as? String == "user" {
          raw["hook_event_name"] = "UserPromptSubmit"
        } else if p["phase"] as? String == "final_answer"
          || msg["stop_reason"] as? String == "end_turn"
        {
          raw["hook_event_name"] = "Stop"
          raw["last_assistant_message"] = content.compactMap { $0["text"] as? String }.joined(
            separator: "\n")
        }
      default: continue
      }
      if let parsed = Events.parse(provider: provider, row: ["logged_at": timestamp, "event": raw])
      {
        latest = parsed
      }
    }
    return latest
  }
}
