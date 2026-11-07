import Foundation

public enum Terminal {
  public static let choices = [
    "terminal", "iterm", "ghostty", "warp", "kitty", "wezterm", "alacritty", "custom",
  ]
  public static func open(_ command: String, settings: JSONObject) throws {
    try open(command, settings: settings, run: { try SystemCommand.run($0, $1) })
  }
  static func open(_ command: String, settings: JSONObject, run: (String, [String]) throws -> Data)
    throws
  {
    let config = settings["session_terminal"] as? JSONObject ?? [:]
    let selection = config["app"] as? String ?? "terminal"
    var name =
      [
        "iterm": "iTerm", "ghostty": "Ghostty", "warp": "Warp", "kitty": "kitty",
        "wezterm": "WezTerm", "alacritty": "Alacritty",
      ][selection] ?? "Terminal"
    if selection == "custom", let path = config["custom_path"] as? String, !path.isEmpty {
      name = path
    }
    func terminal() throws {
      _ = try run(
        "/usr/bin/osascript",
        [
          "-e", "on run argv", "-e",
          "tell application \"Terminal\" to do script (item 1 of argv)", "-e",
          "tell application \"Terminal\" to activate", "-e", "end run", "--", command,
        ])
    }
    if name == "Terminal" {
      try terminal()
      return
    }
    do {
      if name.lowercased().contains("iterm") {
        let script = """
          on run argv
            tell application "iTerm"
              activate
              if (count of windows) = 0 then
                create window with default profile command (item 1 of argv)
              else
                tell current window to create tab with default profile command (item 1 of argv)
              end if
            end tell
          end run
          """
        _ = try run("/usr/bin/osascript", ["-e", script, "--", command])
      } else if name.lowercased().contains("warp") {
        let file = Paths.support.appendingPathComponent("resume-" + UUID().uuidString + ".command")
        try Paths.directory(Paths.support)
        try Data(("#!/bin/zsh\n" + command + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        _ = try run("/usr/bin/open", ["-a", name, file.path])
      } else {
        let args = name.lowercased().contains("wezterm") ? ["start", "--new-tab", "--"] : ["-e"]
        _ = try run(
          "/usr/bin/open", ["-n", "-a", name, "--args"] + args + ["/bin/zsh", "-lc", command])
      }
    } catch { try terminal() }
  }
}
