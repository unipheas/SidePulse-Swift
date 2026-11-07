import Foundation
import PulseCore

/// A stable text snapshot also works in redirected logs; ANSI is opt-in for an interactive watch.
enum ConsoleSnapshot {
  static func render(mode: Mode, sessions: [Session], now: Date = Date(), color: Bool) -> String {
    func clean(_ text: String) -> String {
      String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }
    func status(_ mode: Mode) -> String {
      guard color else { return mode.label }
      let code: Int
      switch mode {
      case .blocked: code = 31
      case .waiting: code = 33
      case .working, .tool, .progress: code = 36
      case .done: code = 32
      case .idle, .unknown: code = 90
      }
      return "\u{1B}[\(code)m" + mode.label + "\u{1B}[0m"
    }
    var lines = ["SidePulse · " + status(mode), ""]
    if sessions.isEmpty { lines.append("Waiting for agent activity.") }
    for session in sessions {
      let age = max(0, Int(now.timeIntervalSince(session.date)))
      let elapsed =
        age >= 3600
        ? "\(age / 3600)h \((age % 3600) / 60)m"
        : age >= 60 ? "\(age / 60)m \(age % 60)s" : "\(age)s"
      lines.append(
        "\(clean(session.name)) · \(status(session.mode)) · \(clean(session.provider)) · \(elapsed)"
      )
    }
    return lines.joined(separator: "\n")
  }
}
