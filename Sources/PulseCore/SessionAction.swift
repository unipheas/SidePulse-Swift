import Foundation

public enum SessionAction: String, CaseIterable {
  case app, vscode, terminal
  public var label: String {
    switch self {
    case .app: return "Open in app"
    case .vscode: return "Open in VS Code"
    case .terminal: return "Resume in Terminal"
    }
  }
}
public enum SessionTarget: Equatable {
  case link(URL)
  case terminal(String)
}
extension Session {
  public func target(for action: SessionAction) -> SessionTarget? {
    if action == .app, provider == "claude" { return .link(URL(string: "claude://")!) }
    guard let threadID, !threadID.isEmpty, !threadID.hasPrefix("-"),
      threadID.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    switch action {
    case .app:
      guard provider == "codex",
        let id = threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
        let url = URL(string: "codex://threads/" + id)
      else { return nil }
      return .link(url)
    case .vscode:
      guard provider == "claude" else { return nil }
      var url = URLComponents(string: "vscode://anthropic.claude-code/open")!
      url.queryItems = [URLQueryItem(name: "session", value: threadID)]
      return url.url.map(SessionTarget.link)
    case .terminal:
      let id = shellQuote(threadID)
      let command: String
      switch provider {
      case "codex": command = "codex resume " + id
      case "claude", "grok": command = provider + " --resume " + id
      case "junie": command = "junie --session-id=" + id + " --resume"
      default: return nil
      }
      return .terminal("cd -- " + shellQuote(cwd ?? Paths.home.path) + " && " + command)
    }
  }
  public func actions(preferences: [String: String]) -> [SessionAction] {
    let surface = origin?.lowercased() ?? ""
    var choices: [SessionAction] = [.app, .terminal, .vscode]
    let preferred = preferences[provider].flatMap(SessionAction.init(rawValue:))
    if let first = preferred
      ?? (surface.contains("cli") || surface.contains("terminal")
        ? .terminal
        : (surface.contains("vs code") || surface.contains("vscode")
          || (surface.isEmpty && provider == "claude") ? .vscode : nil))
    {
      choices.removeAll { $0 == first }
      choices.insert(first, at: 0)
    }
    return choices.filter { target(for: $0) != nil }
  }
}
func shellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
