import Foundation
import PulseCore

extension CLI {
  static func setup(
    executable: URL = Bundle.main.executableURL!,
    hooks: (Bool) throws -> Void = configure,
    receiver: () throws -> RelayConfiguration = RelayConfiguration.receiver,
    install: (String, URL, Jobs.Scope) throws -> Void = {
      try Jobs.configure($0, executable: $1, start: true, scope: $2)
    }
  ) throws {
    let noApp = Args.flag("--no-status-bar")
    let scopeName = try Args.option("--sd-eject-guard-scope") ?? "auto"
    guard let scope = Jobs.Scope(rawValue: scopeName) else {
      throw PulseError("Choose auto, user or system scope.")
    }
    let dry = Args.words.contains("--dry-run")
    let bundle = !noApp && !dry ? try AppInstallation.bundle(for: executable) : nil
    guard dry || scope != .system || getuid() == 0 else {
      throw PulseError("System scope requires root.")
    }
    try hooks(true)
    if dry {
      print("Would install the device output service and Pro eject protection.")
      if !noApp { print("Would start SidePulse.") }
      return
    }
    let configuration = try receiver()
    try install("service", executable, .user)
    try install("sdejectguard", executable, scope)
    if let bundle {
      try install("app", bundle.appendingPathComponent("Contents/MacOS/SidePulse"), .user)
    }
    print("Remote computer: sidepulsectl link " + configuration.receiverChannel)
  }
}
