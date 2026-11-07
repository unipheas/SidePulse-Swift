import XCTest

@testable import PulseCLI
@testable import PulseCore

final class CommandTests: IsolatedTests {
  func testAppStopTargetsOnlyNativeBundleAndReportsRefusal() throws {
    try AppInstallation.stop { identifier in
      XCTAssertEqual(identifier, "com.unipheas.SidePulseSwift")
      return true
    }
    XCTAssertThrowsError(try AppInstallation.stop { _ in false })
  }
  func testBatteryCommandsUseMeasuredSnapshotAndHandleUnavailableBattery() async throws {
    let device = try volume()
    let battery = Battery(percent: 45, charging: true, plugged: true, watts: 60)
    for args in [
      ["status"], ["status", "--json"], ["status", "--json", "--full-watts", "96"],
      ["leds", "--device", device.root.path, "--once"],
      ["leds", "--device", device.root.path, "--once", "--dry-run"],
    ] {
      Args.words = args
      try await CLI.batteryCommand(read: { battery }, diagnostics: { _ in nil })
    }
    XCTAssertTrue(
      try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")).contains("repeat"))
    for args in [
      ["status", "--full-watts", "bad"], ["status", "--interval", "0"], ["unknown"],
      ["configure", "--show-on-power-change", "maybe"],
    ] {
      Args.words = args
      do {
        try await CLI.batteryCommand(read: { battery })
        XCTFail("Expected invalid arguments")
      } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    Args.words = ["status"]
    do {
      try await CLI.batteryCommand(read: { nil })
      XCTFail("Expected no-battery error")
    } catch { XCTAssertTrue(error.localizedDescription.contains("No internal battery")) }
  }
  func testCustomHookLogCLIAndRecentWindowValidation() async throws {
    let log = root.appendingPathComponent("custom/codex.jsonl")
    Args.words = [
      "agent-monitor", "install", "codex", "--log-dir", log.deletingLastPathComponent().path,
    ]
    try await CLI.run()
    XCTAssertEqual((try Settings.read()["hook_logs"] as? [String: String])?["codex"], log.path)
    try Events.record(provider: "codex", raw: ["session_id": "path-check"], named: "Stop")
    Args.words = ["agent-monitor", "status", "--max-lines", "1", "--recent-seconds", "0", "--json"]
    try await CLI.run()
    for option in ["--max-lines", "--recent-seconds"] {
      Args.words = ["agent-monitor", "status", option, "-1"]
      do {
        try await CLI.run()
        XCTFail("Expected invalid window")
      } catch {}
    }
    Args.words = ["agent-monitor", "uninstall", "codex", "--codex-log", log.path]
    try await CLI.run()
    XCTAssertNil((try Settings.read()["hook_logs"] as? [String: String])?["codex"])
  }
}
