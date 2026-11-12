import Foundation

public struct HookDiagnostic: Codable, Hashable {
  public let provider: String
  public let path: String
  public let status: String
}

public enum Hooks {
  static let base = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
  static let more = ["PreCompact", "PostCompact", "SubagentStop"]
  static let events = [
    "codex": base + more + ["PermissionRequest", "SubagentStart", "Interrupt"],
    "claude": base + more + [
      "PostToolUseFailure", "PermissionRequest", "Notification", "StopFailure", "SessionEnd",
    ],
    "grok": base + more + [
      "PostToolUseFailure", "PermissionDenied", "Notification", "SubagentStart", "StopFailure",
      "SessionEnd",
    ],
    "cursor": [
      "sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "beforeShellExecution",
      "afterShellExecution", "afterFileEdit", "postToolUse", "postToolUseFailure", "stop",
    ],
    // A successful Junie PermissionRequest hook grants permission. An observer must omit it.
    "junie": [
      "SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "StopFailure", "SessionEnd",
    ],
  ]
  static let configs = [
    "codex": ".codex/config.toml", "claude": ".claude/settings.json",
    "grok": ".grok/hooks/sidepulse-swift.json", "cursor": ".cursor/hooks.json",
    "junie": ".junie/config.json",
  ]
  public static func diagnostics(home: URL = Paths.home) -> [HookDiagnostic] {
    providers.compactMap { provider in
      guard let path = configs[provider] else { return nil }
      let url = home.appendingPathComponent(path)
      let text = try? String(contentsOf: url, encoding: .utf8)
      let installed =
        text?.contains(provider == "codex" ? "# BEGIN SidePulse Swift hooks" : "# sidepulse-swift")
        == true
      return HookDiagnostic(
        provider: provider, path: url.path,
        status: installed ? "installed" : (text == nil ? "missing" : "unconfigured"))
    }
  }
  public static func configure(
    _ provider: String, executable: URL, install: Bool, home: URL = Paths.home, log: URL? = nil
  ) throws {
    guard let relative = configs[provider], let names = events[provider] else {
      throw PulseError("Choose one of: \(providers.joined(separator: ", ")).")
    }
    let file = home.appendingPathComponent(relative)
    try withLock(Paths.support.appendingPathComponent("hooks.lock")) {
      let exists = FileManager.default.fileExists(atPath: file.path)
      if !install && !exists { return }
      let original = exists ? try Data(contentsOf: file) : Data()
      let path = shellQuote(executable.standardizedFileURL.path)
      let prefix =
        path + " hook-log --provider " + provider
        + (log.map { " --log " + shellQuote($0.standardizedFileURL.path) } ?? "")
      let output: Data
      if provider == "codex" {
        guard var text = String(data: original, encoding: .utf8) else {
          throw PulseError("Invalid Codex configuration encoding.")
        }
        let begin = "# BEGIN SidePulse Swift hooks"
        let end = "# END SidePulse Swift hooks"
        if let first = text.range(of: begin) {
          guard let last = text.range(of: end, range: first.upperBound..<text.endIndex) else {
            throw PulseError("Incomplete managed hook block.")
          }
          text.removeSubrange(first.lowerBound..<last.upperBound)
        }
        if install {
          let features = try NSRegularExpression(
            pattern: #"(?ms)^\[features\][ \t]*(?:#[^\n]*)?\n.*?(?=^\[|\z)"#)
          if let section = features.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(section.range, in: text)
          {
            var block = String(text[range])
            if block.range(of: #"(?m)^hooks\s*="#, options: .regularExpression) != nil {
              block = block.replacingOccurrences(
                of: #"(?m)^hooks\s*=\s*(true|false)"#, with: "hooks = true",
                options: .regularExpression)
            } else {
              block += "\nhooks = true\n"
            }
            text.replaceSubrange(range, with: block)
          } else {
            text += "\n[features]\nhooks = true\n"
          }
          let quoted = String(
            decoding: try JSONEncoder().encode(prefix + " || true"), as: UTF8.self)
          while text.last?.isNewline == true { text.removeLast() }
          text += "\n\n" + begin + "\n"
          for name in names {
            text +=
              "[[hooks.\(name)]]\nmatcher = \"*\"\n[[hooks.\(name).hooks]]\ntype = \"command\"\ncommand = \(quoted.replacingOccurrences(of: "\\/",with: "/"))\n"
          }
          text += end
        }
        output = Data((text.trimmingCharacters(in: .newlines) + "\n").utf8)
      } else {
        var config = exists ? try object(file) : [:]
        if let hooks = config["hooks"], !(hooks is JSONObject) {
          throw PulseError("Unsupported hooks configuration.")
        }
        var hooks = config["hooks"] as? JSONObject ?? [:]
        for name in names {
          if let value = hooks[name], !(value is [Any]) {
            throw PulseError("Unsupported entries for \(name).")
          }
          var entries = hooks[name] as? [Any] ?? []
          entries.removeAll { value in
            guard let entry = value as? JSONObject else { return false }
            let nested = entry["hooks"] as? [JSONObject]
            let command =
              entry["command"] as? String
              ?? (nested?.count == 1 ? nested?.first?["command"] as? String : nil)
            return command?.contains(" hook-log --provider \(provider)") == true
              && command?.hasSuffix(" --event \(name) # sidepulse-swift") == true
          }
          if install {
            let command = prefix + " --event " + name + " # sidepulse-swift"
            if provider == "cursor" {
              entries.append(["command": command])
            } else {
              var entry: JSONObject = ["hooks": [["type": "command", "command": command]]]
              if provider != "junie" { entry["matcher"] = "*" }
              entries.append(entry)
            }
          }
          hooks[name] = entries.isEmpty ? nil : entries
        }
        config["hooks"] = hooks
        if provider == "cursor", config["version"] == nil { config["version"] = 1 }
        output = try JSONSerialization.data(
          withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      }
      guard output != original else { return }
      try Paths.directory(file.deletingLastPathComponent())
      if exists {
        let backups = Paths.support.appendingPathComponent("Hook Backups")
        try Paths.directory(backups)
        try original.write(
          to: backups.appendingPathComponent(provider + "-" + UUID().uuidString), options: .atomic)
      }
      try output.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }
}
