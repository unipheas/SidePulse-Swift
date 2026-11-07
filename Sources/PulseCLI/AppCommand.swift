import Foundation
import PulseCore

extension CLI {
  static func appCommand() throws {
    let foreground = Args.flag("--foreground")
    let remove = Args.flag("--uninstall")
    let noStart = Args.flag("--no-start")
    let dry = Args.flag("--dry-run")
    let action = Args.pop() ?? (remove ? "stop" : "start")
    try Args.end()
    let executable = Bundle.main.executableURL!
    if ["install-sleep-helper", "uninstall-sleep-helper", "sleep-helper-status"].contains(action) {
      let operation =
        action == "sleep-helper-status" ? "status" : String(action.split(separator: "-")[0])
      print(try AppInstallation.sleepHelper(action: operation, executable: executable, dryRun: dry))
      return
    }
    guard ["start", "stop"].contains(action) else {
      throw PulseError("Choose start, stop or a sleep-helper command.")
    }
    guard !(foreground && noStart) else {
      throw PulseError("--foreground conflicts with --no-start.")
    }
    if dry {
      print("Would \(action) SidePulse")
      return
    }
    let app = try AppInstallation.bundle(for: executable)
    if foreground {
      guard action == "start" else { throw PulseError("--foreground requires start.") }
      try AppInstallation.open(executable: executable)
    } else {
      try Jobs.configure(
        "app", executable: app.appendingPathComponent("Contents/MacOS/SidePulse"),
        start: action == "start", launch: !noStart)
      if action == "stop" { try AppInstallation.stop() }
    }
  }
}
