import AppKit
import PulseCore
import ServiceManagement

/// Side effects used by settings and initial setup; each boundary can be exercised independently.
@MainActor struct MacActions {
  var executable: URL? = Bundle.main.executableURL?.deletingLastPathComponent()
    .appendingPathComponent("sidepulsectl")
  var executableExists: (String) -> Bool = FileManager.default.isExecutableFile
  var configureJob: (String, URL, Bool) throws -> Void = {
    try Jobs.configure($0, executable: $1, start: $2)
  }
  var jobRunning: (String) -> Bool = { Jobs.running(Jobs.prefix + $0) }
  var login: (Bool) throws -> Bool = { try MacActions.setLogin($0) }
  var helperInstalled: () -> Bool = {
    FileManager.default.fileExists(atPath: "/etc/sudoers.d/sidepulse-swift-disablesleep")
  }
  var helper: (String, URL) async throws -> String = MacActions.manageHelper
  var takeControl: () throws -> Void = Jobs.takeControl
  var giveBack: () throws -> Void = Jobs.giveBack
  var previewPhone: (Phone, String) async throws -> Void = {
    try await Bridge.push(to: $0.id, program: $1, title: nil, message: nil)
  }
  var openSession: (SessionTarget?, Session, JSONObject) throws -> Void = {
    try SessionOpening.open($0, session: $1, settings: $2)
  }
  var hooks: (String, URL, Bool) throws -> Void = {
    try Hooks.configure($0, executable: $1, install: $2)
  }

  static func setLogin(
    _ enabled: Bool,
    register: () throws -> Void = SMAppService.mainApp.register,
    unregister: () throws -> Void = SMAppService.mainApp.unregister,
    status: () -> Bool = { SMAppService.mainApp.status == .enabled }
  ) throws -> Bool {
    if enabled {
      try register()
    } else {
      try unregister()
    }
    return status()
  }
  nonisolated static func manageHelper(_ action: String, executable: URL) async throws -> String {
    try await Task.detached {
      try AppInstallation.sleepHelper(
        action: action, executable: executable, dryRun: false, administratorPrompt: true)
    }.value
  }
  func cli() throws -> URL {
    guard let executable, executableExists(executable.path) else {
      throw PulseError("Install SidePulse.app before managing background services or hooks.")
    }
    return executable
  }
  func job(_ name: String, start: Bool) throws -> Bool {
    try configureJob(name, cli(), start)
    return jobRunning(name)
  }
  func configureHooks(_ provider: String, install: Bool) throws {
    try hooks(provider, cli(), install)
  }
}
