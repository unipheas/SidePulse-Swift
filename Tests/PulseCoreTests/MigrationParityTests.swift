import XCTest

@testable import PulseCLI
@testable import PulseCore

final class MigrationParityTests: IsolatedTests {
  func testLegacyTimingAndSleepSettingsPreservePreferences() {
    for name in ["idle_timeout_seconds", "recent_session_retention_seconds"] {
      XCTAssertEqual(Settings.seconds([name: 42], name, default: 10), 42)
      XCTAssertEqual(Settings.seconds([name: 42, "agent_list": [name: 13]], name, default: 10), 13)
      XCTAssertEqual(Settings.seconds([name: 42, "agent_list": [name: -1]], name, default: 10), 10)
    }
    XCTAssertEqual(
      Settings.seconds(["completed_visible_seconds": 42], "completed_visible_seconds", default: 15),
      15)
    XCTAssertEqual(SleepSettings.policy([:]), "agents")
    for policy in ["always", "agents", "never"] {
      XCTAssertEqual(SleepSettings.policy(["sleep_prevention_policy": policy]), policy)
      XCTAssertEqual(SleepSettings.policy(["open_lid_awake_policy": policy]), policy)
      XCTAssertEqual(SleepSettings.policy(["closed_lid_awake_policy": policy]), policy)
      XCTAssertEqual(
        SleepSettings.closedLid([
          "closed_lid_system_override_enabled": true, "sleep_prevention_policy": policy,
        ]), policy)
      XCTAssertEqual(SleepSettings.closedLid(["swift_closed_lid": policy]), policy)
    }
    XCTAssertEqual(
      SleepSettings.policy([
        "sleep_prevention_policy": "invalid", "open_lid_awake_policy": "never",
        "closed_lid_awake_policy": "always",
      ]), "always")
    XCTAssertEqual(
      SleepSettings.policy([
        "sleep_prevention_policy": "never", "closed_lid_awake_policy": "always",
      ]), "never")
    XCTAssertEqual(SleepSettings.closedLid([:]), "never")
    XCTAssertEqual(SleepSettings.minimum([:]), 20)
    XCTAssertEqual(SleepSettings.minimum(["sleep_prevention_min_battery_percent": 35]), 35)
    XCTAssertEqual(
      SleepSettings.minimum([
        "sleep_prevention_min_battery_percent": 35, "sleep_prevention": ["min_battery_percent": 15],
      ]), 15)
    XCTAssertEqual(SleepSettings.minimum(["sleep_prevention_min_battery_percent": Double.nan]), 20)
    XCTAssertEqual(SleepSettings.minimum(["sleep_prevention_min_battery_percent": -1]), 0)
    XCTAssertEqual(SleepSettings.minimum(["sleep_prevention_min_battery_percent": 120]), 100)
  }

  func testReusableAnimationUpdatesKeepReferencesAndCurrentKeepsMapping() throws {
    let id = try Settings.saveAnimation(name: "Original", program: "#00FF00")
    try Settings.setAnimation(.working, program: "#00FF00", libraryID: id)
    try Settings.setAnimation(.done, program: "#00FF00", libraryID: id)
    let profile = try Profiles.save(name: "Reusable")
    XCTAssertEqual(
      try Settings.saveAnimation(name: "Renamed", program: "#0000FF", replacing: id), id)
    let library = try XCTUnwrap(Settings.read()["custom_agent_animations"] as? [String: JSONObject])
    XCTAssertEqual(library.count, 1)
    XCTAssertEqual(library[id]?["name"] as? String, "Renamed")
    try Profiles.select(profile)
    for mode in [Mode.working, .done] {
      XCTAssertEqual(try Programs.program(mode, count: 8, settings: Settings.read()), "#0000FF")
    }
    let before = try JSONSerialization.data(
      withJSONObject: Settings.read()["agent_animations"]!, options: .sortedKeys)
    try Profiles.select("current")
    XCTAssertEqual(try Settings.read()["swift_profile"] as? String, "current")
    XCTAssertEqual(
      before,
      try JSONSerialization.data(
        withJSONObject: Settings.read()["agent_animations"]!, options: .sortedKeys))
    XCTAssertThrowsError(
      try Settings.saveAnimation(name: "Missing", program: "off", replacing: "custom:missing"))
    XCTAssertThrowsError(
      try Settings.setAnimation(.idle, program: "off", libraryID: "custom:missing"))
  }

  func testProgramOutputDeduplicatesRetriesAndReconnects() throws {
    let device = try volume()
    var now = Date(timeIntervalSince1970: 100)
    var writes: [String] = []
    var fail = false
    let output = ProgramOutput(
      now: { now },
      write: { _, program in
        writes.append(program)
        if fail { throw PulseError("Transport unavailable") }
      })
    try output.send("#00FF00", to: device)
    try output.send("#00FF00", to: device)
    XCTAssertEqual(writes.count, 1)
    fail = true
    XCTAssertThrowsError(try output.send("off", to: device))
    try output.send("off", to: device)
    XCTAssertEqual(writes.count, 2)
    now.addTimeInterval(10)
    fail = false
    try output.send("off", to: device)
    XCTAssertEqual(writes.count, 3)
    output.retain([device])
    try output.send("off", to: device)
    XCTAssertEqual(writes.count, 3)
    output.retain([])
    try output.send("off", to: device)
    XCTAssertEqual(writes.count, 4)
    let replacement = Device(
      root: device.root, model: device.model, firmware: device.firmware, serial: "replacement")
    try output.send("off", to: replacement)
    XCTAssertEqual(writes.count, 5)
    output.forget(device.id)
    try output.send("off", to: replacement)
    XCTAssertEqual(writes.count, 6)
    // A failed replacement may partially change the LEDs: reverting must send again.
    fail = true
    XCTAssertThrowsError(try output.send("#FFFFFF", to: replacement))
    fail = false
    try output.send("off", to: replacement)
    XCTAssertEqual(writes.count, 8)
  }

  func testContinuousBatteryOutputSurvivesDisconnectAndDoesNotRestartAnimation() async throws {
    let device = try volume()
    let battery = Battery(percent: 50, charging: true, plugged: true, watts: 60)
    var iteration = 0
    var writes = 0
    var errors: [String] = []
    Args.words = ["leds"]
    try await Task {
      try await CLI.batteryCommand(
        read: { battery }, discover: { iteration == 2 ? [] : [device] },
        wait: { _ in
          iteration += 1
          if iteration == 5 { withUnsafeCurrentTask { $0?.cancel() } }
        }, output: ProgramOutput(write: { _, _ in writes += 1 }), report: { errors.append($0) })
    }.value
    XCTAssertEqual(writes, 2)
    XCTAssertEqual(errors.count, 1)
    Args.words = ["leds", "--once"]
    do {
      try await CLI.batteryCommand(read: { battery }, discover: { [] })
      XCTFail("One-shot output must report a missing device")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Connect")) }
  }
}

extension MigrationParityTests {
  func testConsoleSnapshotsShowEveryStateAgeAndSanitizeControlCharacters() {
    let now = Date(timeIntervalSince1970: 10000)
    let sessions = Mode.allCases.enumerated().map { index, mode in
      Session(
        provider: "codex", session: "s\(index)", name: "Task\u{1B}\n", event: "Stop",
        date: now.addingTimeInterval(-Double(index * 700)), mode: mode)
    }
    for color in [false, true] {
      let text = ConsoleSnapshot.render(mode: .working, sessions: sessions, now: now, color: color)
      for mode in Mode.allCases { XCTAssertTrue(text.contains(mode.label)) }
      XCTAssertTrue(text.contains("0s"))
      XCTAssertTrue(text.contains("11m 40s"))
      XCTAssertTrue(text.contains("1h 10m"))
      XCTAssertFalse(text.contains("Task\u{1B}"))
      XCTAssertEqual(text.contains("\u{1B}["), color)
    }
    XCTAssertTrue(
      ConsoleSnapshot.render(mode: .idle, sessions: [], now: now, color: false).contains(
        "Waiting for agent activity"))
  }
  func testMonitorRetriesMissingExplicitDeviceAndRestoresInteractiveCursor() async throws {
    try Settings.update { $0["sleep_prevention_policy"] = "never" }
    Args.words = ["--device", root.appendingPathComponent("missing").path]
    var errors = [String]()
    try await Task {
      try await CLI.monitor(
        "leds", legacyRunning: { false },
        wait: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
        }, report: { errors.append($0) })
    }.value
    XCTAssertEqual(errors.count, 1)
    Args.words = []
    try await Task {
      try await CLI.monitor(
        "watch", wait: { _ in withUnsafeCurrentTask { $0?.cancel() } }, interactive: true)
    }.value
  }
}
