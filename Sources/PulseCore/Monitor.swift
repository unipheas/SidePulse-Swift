import Foundation

public enum Mode: String, Codable, CaseIterable {
  case blocked = "blocked_error"
  case waiting = "waiting_for_input"
  case tool = "tool_running"
  case progress = "long_task_progress"
  case working
  case done = "completed"
  case idle = "idle_ready"
  case unknown
  public var label: String {
    switch self {
    case .blocked: return "Blocked"
    case .waiting: return "Needs input"
    case .tool: return "Running a tool"
    case .progress: return "In progress"
    case .working: return "Working"
    case .done: return "Done"
    case .idle: return "Idle"
    case .unknown: return "Unknown"
    }
  }
  var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public let providers = ["codex", "claude", "cursor", "grok", "junie"]
public struct Session: Codable, Identifiable, Equatable {
  public let provider: String, session: String, name: String, event: String
  public let date: Date
  public var mode: Mode
  public var id: String { provider + ":" + session }
}

public enum Events {
  public static func date(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    if let time = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
      return time
    }
    return try? Date.ISO8601FormatStyle().parse(string)
  }

  public static func parse(provider: String, row: JSONObject) -> Session? {
    let raw = row["event"] as? JSONObject ?? row
    guard
      let event = (raw["hook_event_name"] ?? raw["hookEventName"] ?? raw["event_name"]) as? String,
      let time = date(row["logged_at"] ?? raw["logged_at"] ?? raw["timestamp"])
    else { return nil }
    let identity =
      (raw["agent_id"] ?? raw["session_id"] ?? raw["sessionId"] ?? raw["conversation_id"])
      as? String ?? "default"
    let cwd = (raw["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    let name = (raw["session_title"] as? String) ?? cwd ?? provider.capitalized
    let message = (raw["last_assistant_message"] ?? raw["message"]) as? String ?? ""
    let mode: Mode
    if event.lowercased() == "interrupt" {
      mode = .idle
    } else if let explicit = Mode(
      rawValue: (raw["sidepulse_status"] ?? raw["sidepulse_mode"]) as? String ?? "")
    {
      mode = explicit
    } else if message.contains("<!-- sidepulse:ask -->") {
      mode = .waiting
    } else if message.contains("<!-- sidepulse:done -->") {
      mode = .done
    } else {
      switch event.lowercased() {
      case "stopfailure", "posttoolusefailure", "permissiondenied": mode = .blocked
      case "permissionrequest": mode = .waiting
      case "pretooluse", "beforeshellexecution": mode = .tool
      case "posttooluse", "aftershellexecution", "afterfileedit":
        let result = raw["tool_response"] as? JSONObject
        mode =
          result?["is_error"] as? Bool == true || (result?["exit_code"] as? Int ?? 0) != 0
          ? .blocked : .working
      case "userpromptsubmit", "beforesubmitprompt", "precompact", "postcompact", "subagentstart":
        mode = .working
      case "stop", "subagentstop":
        mode =
          message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? .waiting : .done
      case "sessionend": mode = .done
      case "sessionstart": mode = .idle
      case "notification":
        let text = ((raw["notification_type"] as? String ?? "") + " " + message).lowercased()
        if ["permission", "input", "approval"].contains(where: text.contains) {
          mode = .waiting
        } else if ["idle", "complete", "finished"].contains(where: text.contains) {
          mode = .done
        } else {
          mode = .working
        }
      default: return nil
      }
    }
    return Session(
      provider: provider, session: identity, name: name, event: event, date: time, mode: mode)
  }

  public static func record(provider: String, raw: JSONObject, named event: String? = nil) throws {
    guard providers.contains(provider) else { throw PulseError("Unknown agent provider.") }
    var payload = raw
    if let event { payload["hook_event_name"] = event }
    let row: JSONObject = [
      "event": payload,
      "logged_at": Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true)),
    ]
    let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
    guard data.count <= 2_097_152 else { throw PulseError("Hook payload exceeds 2 MiB.") }
    let directory = Paths.support.appendingPathComponent("events")
    try withLock(directory.appendingPathComponent(provider + ".lock")) {
      let url = directory.appendingPathComponent(provider + ".jsonl")
      let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw POSIXError(.EACCES) }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try file.write(contentsOf: data)
    }
  }
}

/// Keep only the last event per agent. Read appended bytes on subsequent polls.
public final class Monitor {
  private struct Tail {
    var inode: UInt64 = 0, offset: UInt64 = 0
    var partial = Data()
    var sessions = [String: Session]()
  }
  private let transcripts = TranscriptReader()
  private var tails = [URL: Tail]()
  public init() {}
  public func sessions() -> [Session] {
    var latest = [String: Session]()
    for directory in [Paths.legacyState, Paths.support.appendingPathComponent("events")] {
      for provider in providers {
        let url = directory.appendingPathComponent(provider + ".jsonl")
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attr[.size] as? UInt64, let inode = attr[.systemFileNumber] as? UInt64
        else {
          tails[url] = nil
          continue
        }
        var tail = tails[url] ?? Tail()
        if inode != tail.inode || size < tail.offset { tail = Tail(inode: inode) }
        if size > tail.offset, let file = try? FileHandle(forReadingFrom: url) {
          defer { try? file.close() }
          var start = tail.offset
          if size - start > 2_097_152 {
            start = size - 2_097_152
            tail.partial = Data()
          }
          do {
            try file.seek(toOffset: start)
            let chunk = try file.read(upToCount: Int(size - start)) ?? Data()
            tail.offset = start + UInt64(chunk.count)
            var lines = (tail.partial + chunk).split(
              separator: 10, omittingEmptySubsequences: false)
            tail.partial = Data(lines.popLast() ?? Data())
            for line in lines {
              guard let row = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject,
                let session = Events.parse(provider: provider, row: row)
              else { continue }
              if tail.sessions[session.id].map({ $0.date > session.date }) != true {
                tail.sessions[session.id] = session
              }
            }
            tails[url] = tail
          } catch { continue }
        }
        latest.merge(tail.sessions) { $0.date > $1.date ? $0 : $1 }
      }
    }
    for row in transcripts.read(settings: (try? Settings.read()) ?? [:])
    where latest[row.id].map({ $0.date < row.date }) ?? true { latest[row.id] = row }
    return latest.values.sorted { $0.date > $1.date }
  }

  public static func aggregate(_ sessions: [Session], settings: JSONObject, now: Date = Date())
    -> Mode
  {
    let done = Settings.seconds(settings, "completed_visible_seconds", default: 1200)
    let stale = Settings.seconds(settings, "idle_timeout_seconds", default: 3600)
    return sessions.compactMap { item -> Mode? in
      let age = max(0, now.timeIntervalSince(item.date))
      var mode = item.mode
      if mode == .working && item.event.lowercased() == "posttooluse" && age > 120 { mode = .done }
      if mode == .done { return age < done ? mode : nil }
      return age < stale ? mode : nil
    }.min { $0.rank < $1.rank } ?? .idle
  }
}
