import Foundation
import PulseCore

extension CLI {
  static func appCommand(
    executable: URL = Bundle.main.executableURL!,
    configure: (String, URL, Bool, Bool) throws -> Void = {
      try Jobs.configure($0, executable: $1, start: $2, launch: $3)
    },
    open: (URL) throws -> Void = { try AppInstallation.open(executable: $0) },
    stop: () throws -> Void = { try AppInstallation.stop() },
    helper: (String, URL, Bool) throws -> String = {
      try AppInstallation.sleepHelper(action: $0, executable: $1, dryRun: $2)
    }
  ) throws {
    let foreground = Args.flag("--foreground")
    let remove = Args.flag("--uninstall")
    let noStart = Args.flag("--no-start")
    let dry = Args.flag("--dry-run")
    let action = Args.pop() ?? (remove ? "stop" : "start")
    try Args.end()
    if ["install-sleep-helper", "uninstall-sleep-helper", "sleep-helper-status"].contains(action) {
      let operation =
        action == "sleep-helper-status" ? "status" : String(action.split(separator: "-")[0])
      print(try helper(operation, executable, dry))
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
      try open(executable)
    } else {
      try configure(
        "app", app.appendingPathComponent("Contents/MacOS/SidePulse"), action == "start", !noStart)
      if action == "stop" { try stop() }
    }
  }
}
