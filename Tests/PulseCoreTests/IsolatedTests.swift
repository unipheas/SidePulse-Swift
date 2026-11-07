import XCTest

@testable import PulseCore

/// Each test owns its settings, hook logs, locks, and mounted-volume fixtures.
class IsolatedTests: XCTestCase {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var saved: [String: String] = [:]
  let keys = ["SIDEPULSE_USER_HOME", "SIDEPULSE_SWIFT_HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME"]
  override func setUpWithError() throws {
    try super.setUpWithError()
    try Paths.directory(root)
    for (key, folder) in zip(keys, ["home", "support", "state", "config"]) {
      saved[key] = ProcessInfo.processInfo.environment[key]
      setenv(key, root.appendingPathComponent(folder).path, 1)
    }
  }
  override func tearDownWithError() throws {
    for key in keys {
      if let value = saved[key] { setenv(key, value, 1) } else { unsetenv(key) }
    }
    try FileManager.default.removeItem(at: root)
    try super.tearDownWithError()
  }
  func volume(_ model: String = "Pro", version: String = "1.0.0") throws -> Device {
    let url = root.appendingPathComponent(model)
    try Paths.directory(url)
    try Data(
      ((model == "Dot" ? "app_version " : "release_version ") + version + "\nserial fixture\n").utf8
    )
    .write(to: url.appendingPathComponent("STATUS.TXT"))
    return try Device.inspect(url)
  }
}
