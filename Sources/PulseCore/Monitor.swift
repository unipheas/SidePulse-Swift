import Foundation

public enum Mode: String, Codable, CaseIterable, Sendable {
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
public struct Session: Codable, Identifiable, Equatable, Sendable {
  public let provider: String, session: String
  public var name: String
  public let event: String
  public let date: Date
  public var cwd: String? = nil, origin: String? = nil, threadID: String? = nil
  public var mode: Mode
  public var id: String { provider + ":" + session }
}

public enum Events {
  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
  public static func date(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    if let time = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
      return time
    }
    return try? Date.ISO8601FormatStyle().parse(string)
  }

  private static func modeKey(_ value: String) -> String {
    value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter {
      !$0.isEmpty
    }.joined(separator: "_")
  }

  static func explicit(_ raw: JSONObject, message: String) -> Mode? {
    var names = [
      "ask": Mode.waiting, "question": .waiting, "waiting": .waiting, "input": .waiting,
      "blocked": .blocked, "error": .blocked, "progress": .progress, "done": .done,
      "complete": .done, "idle": .idle, "ready": .idle,
    ]
    for mode in Mode.allCases { names[mode.rawValue] = mode }
    if let value = (raw["sidepulse_status"] ?? raw["sidepulse_mode"]) as? String,
      let mode = names[modeKey(value)]
    {
      return mode
    }
    let outsideCode = message.replacingOccurrences(
      of: #"(?s)`{3}.*?`{3}"#, with: "", options: .regularExpression)
    for line in outsideCode.split(whereSeparator: \.isNewline) {
      for pattern in [
        #"(?i)^\s*<!--\s*(?:sidepulse|agent[-_ ]monitor)(?:\s+(?:status|mode))?\s*:\s*([a-z0-9_ -]+?)\s*-->\s*$"#,
        #"(?i)^\s*\[(?:sidepulse|agent[-_ ]monitor)\s+(?:status|mode)\s*:\s*([a-z0-9_ -]+?)\]\s*$"#,
      ]
      where line.range(of: pattern, options: .regularExpression) != nil {
        let key = String(line).replacingOccurrences(
          of: pattern, with: "$1", options: .regularExpression)
        if let mode = names[modeKey(key)] { return mode }
      }
    }
    return nil
  }

  public static func parse(provider: String, row: JSONObject) -> Session? {
    let original = row["event"] as? JSONObject ?? row
    guard let raw = HookPayload.normalized(original, provider: provider),
      let event = raw["hook_event_name"] as? String,
      let time = date(row["logged_at"] ?? raw["logged_at"] ?? raw["timestamp"])
    else { return nil }
    if provider == "codex" {
      let text = ["session_title", "prompt", "message", "last_assistant_message"]
        .compactMap { raw[$0] as? String }.joined(separator: " ").lowercased()
      if [
        "generate 0 to 3 hyperpersonalized suggestions",
        "you are an expert at upholding safety and compliance standards",
      ].contains(where: text.contains) {
        return nil
      }
    }
    let identity =
      (raw["agent_id"] ?? raw["session_id"] ?? raw["sessionId"] ?? raw["conversation_id"])
      as? String ?? "default"
    let cwd = (raw["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    let prompt = (raw["prompt"] as? String)?.components(separatedBy: .newlines).first
    let name =
      (raw["session_title"] as? String) ?? prompt.map { String($0.prefix(72)) } ?? cwd
      ?? provider.capitalized
    let message = (raw["last_assistant_message"] ?? raw["message"]) as? String ?? ""
    let mode: Mode
    if event.lowercased() == "interrupt" {
      mode = .idle
    } else if let explicit = explicit(raw, message: message) {
      mode = explicit
    } else {
      switch event.lowercased() {
      case "stopfailure", "posttoolusefailure", "permissiondenied": mode = .blocked
      case "permissionrequest": mode = .waiting
      case "pretooluse", "beforeshellexecution": mode = .tool
      case "posttooluse", "aftershellexecution", "afterfileedit":
        mode = HookPayload.failed(raw["tool_response"]) ? .blocked : .working
      case "userpromptsubmit", "beforesubmitprompt", "precompact", "postcompact", "subagentstart":
        mode = .working
      case "stop", "subagentstop":
        mode =
          HookPayload.asksQuestion(message) ? .waiting : .done
      case "sessionend": mode = .done
      case "sessionstart": mode = .idle
      case "notification":
        let text = ((raw["notification_type"] as? String ?? "") + " " + message).lowercased()
        if ["turn complete", "task complete", "work complete", "completed successfully"]
          .contains(where: text.contains)
          || (raw["notification_type"] as? String == "idle_prompt"
            && ["done", "complete", "completed"].contains(message.lowercased()))
        {
          mode = .done
        } else if [
          "waiting for your input", "waiting for input", "needs your input", "needs input",
          "permission", "approval", "confirm",
        ].contains(where: text.contains) {
          mode = .waiting
        } else {
          mode = .working
        }
      default: return nil
      }
    }
    return Session(
      provider: provider, session: identity, name: name, event: event, date: time,
      cwd: raw["cwd"] as? String, origin: raw["agent_origin"] as? String,
      threadID: raw["session_id"] as? String, mode: mode)
  }

  public static func record(
    provider: String, raw: JSONObject, named event: String? = nil, log: URL? = nil
  ) throws {
    guard providers.contains(provider) else { throw PulseError("Unknown agent provider.") }
    var payload = raw
    if let event { payload["hook_event_name"] = event }
    let row: JSONObject = [
      "event": payload,
      "logged_at": timestamp(Date()),
    ]
    let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
    guard data.count <= 2_097_152 else { throw PulseError("Hook payload exceeds 2 MiB.") }
    let configured = (try Settings.read()["hook_logs"] as? [String: String])?[provider]
    let url =
      log ?? configured.map { URL(fileURLWithPath: $0) }
      ?? Paths.support.appendingPathComponent("events/" + provider + ".jsonl")
    try withLock(url.appendingPathExtension("lock")) {
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
    struct Record {
      let size: Int
      let row: JSONObject?
      let session: Session?
      init(_ data: Data, provider: String) {
        size = data.count
        row = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
        session = row.flatMap { Events.parse(provider: provider, row: $0) }
      }
    }
    var inode: UInt64 = 0, offset: UInt64 = 0
    var partial = Data()
    var records = [Record]()
    var recordBytes = 0
    var sessions = [String: Session]()
    var permissions = [String: Set<String>]()
    mutating func ingest(_ incoming: Session, row: JSONObject) {
      var session = incoming
      let key = session.id
      let previous = sessions[key]
      if let previous, previous.date > session.date { return }
      let raw =
        HookPayload.normalized(row["event"] as? JSONObject ?? row, provider: session.provider)
        ?? [:]
      let command = (raw["tool_input"] as? JSONObject)?["command"] as? String
      let signature = command.map { (raw["tool_name"] as? String ?? "") + "\u{0}" + $0 }
      switch session.event {
      case "PermissionRequest": if let signature { permissions[key, default: []].insert(signature) }
      case "PostToolUse": if let signature { permissions[key]?.remove(signature) }
      case "Stop", "Interrupt", "SessionEnd", "UserPromptSubmit":
        permissions.removeValue(forKey: key)
      default: break
      }
      if let previous {
        session.cwd = session.cwd ?? previous.cwd
        session.origin = session.origin ?? previous.origin
        session.threadID = session.threadID ?? previous.threadID
        if session.name == session.provider.capitalized { session.name = previous.name }
      }
      if previous?.mode == .done && session.event == "Notification" { return }
      if previous?.event == "PermissionRequest", session.event != "PermissionRequest",
        permissions[key]?.isEmpty == false
      {
        return
      }
      sessions[key] = session
    }
  }
  private let transcripts = TranscriptReader()
  private var tails = [URL: Tail]()
  private let sources: [(String, URL)]
  private let maxLines: Int
  public init(logs: [String: URL] = [:], maxLines: Int = 5000) {
    self.maxLines = max(1, maxLines)
    let configured = (try? Settings.read()["hook_logs"] as? [String: String]) ?? [:]
    let logs = configured.mapValues { URL(fileURLWithPath: $0) }.merging(logs) { _, explicit in
      explicit
    }
    sources =
      [Paths.legacyState, Paths.support.appendingPathComponent("events")].flatMap { directory in
        providers.filter { logs[$0] == nil }.map {
          ($0, directory.appendingPathComponent($0 + ".jsonl"))
        }
      } + logs.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
  }
  public func sessions() -> [Session] {
    var latest = [String: Session]()
    var audit = [Audit.Input]()
    for (provider, url) in sources {
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
          tail.records = []
          tail.recordBytes = 0
          tail.sessions = [:]
          tail.permissions = [:]
        }
        do {
          try file.seek(toOffset: start)
          let chunk = try file.read(upToCount: Int(size - start)) ?? Data()
          tail.offset = start + UInt64(chunk.count)
          var lines = (tail.partial + chunk).split(
            separator: 10, omittingEmptySubsequences: false)
          tail.partial = Data(lines.popLast() ?? Data())
          if tail.partial.count > 2_097_152 { tail.partial = Data() }
          let incoming = lines.suffix(maxLines).map { Tail.Record(Data($0), provider: provider) }
          tail.records += incoming
          tail.recordBytes += incoming.reduce(0) { $0 + $1.size }
          var removed = 0
          while tail.records.count - removed > maxLines || tail.recordBytes > 2_097_152 {
            tail.recordBytes -= tail.records[removed].size
            removed += 1
          }
          if removed > 0 {
            tail.records.removeFirst(removed)
            tail.sessions.removeAll()
            tail.permissions.removeAll()
          }
          let historical = max(0, tail.records.count - incoming.count)
          for (index, record) in tail.records.enumerated() where removed > 0 || index >= historical
          {
            guard let row = record.row, let session = record.session else { continue }
            tail.ingest(session, row: row)
            if index >= historical { audit.append((provider, row, tail.sessions[session.id])) }
          }
          tails[url] = tail
        } catch { continue }
      }
      latest.merge(tail.sessions) { $0.date > $1.date ? $0 : $1 }
    }
    try? Audit.records(audit)
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
      let toolTimeout = Settings.seconds(settings, "tool_running_timeout_seconds", default: 0)
      if mode == .tool && toolTimeout > 0 && age > toolTimeout { return nil }
      return age < stale ? mode : nil
    }.min { $0.rank < $1.rank } ?? .idle
  }
}
