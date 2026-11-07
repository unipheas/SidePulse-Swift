import XCTest

@testable import PulseCore
@testable import SidePulse

final class DisplayPolicyTests: IsolatedTests {
  func testBatteryPreviewStartsOnlyOnPowerChangesAndExpiresAtTheConfiguredBoundary() {
    let base = Date(timeIntervalSince1970: 100)
    let battery = Battery(percent: 40, charging: false, plugged: false, watts: 0)
    let power = Battery(percent: 40, charging: true, plugged: true, watts: 60)
    var preview = PowerChangePreview()
    XCTAssertFalse(preview.update(battery: nil, settings: [:], now: base))
    XCTAssertFalse(preview.update(battery: battery, settings: [:], now: base))
    XCTAssertTrue(preview.update(battery: power, settings: [:], now: base))
    XCTAssertTrue(preview.update(battery: power, settings: [:], now: base.addingTimeInterval(6.9)))
    XCTAssertFalse(preview.update(battery: power, settings: [:], now: base.addingTimeInterval(7)))
    let short: JSONObject = ["battery_monitoring": ["power_change_preview_seconds": 2.0]]
    XCTAssertTrue(
      preview.update(battery: battery, settings: short, now: base.addingTimeInterval(8)))
    XCTAssertFalse(
      preview.update(battery: battery, settings: short, now: base.addingTimeInterval(10)))
    let disabled: JSONObject = ["battery_monitoring": ["show_on_power_change": false]]
    XCTAssertFalse(
      preview.update(battery: power, settings: disabled, now: base.addingTimeInterval(11)))
  }
  func testAwakeGraceSurvivesDoneToIdleAndExpiresWithoutRepeatedExtension() {
    let start = Date(timeIntervalSince1970: 100)
    var request = AgentAwakeRequest()
    XCTAssertFalse(request.update(mode: .idle, now: start))
    XCTAssertTrue(request.update(mode: .working, now: start))
    XCTAssertTrue(request.update(mode: .done, now: start))
    XCTAssertTrue(request.update(mode: .idle, now: start.addingTimeInterval(299)))
    XCTAssertFalse(request.update(mode: .idle, now: start.addingTimeInterval(300)))
    XCTAssertTrue(request.update(mode: .waiting, now: start.addingTimeInterval(301)))
    XCTAssertFalse(request.update(mode: .waiting, now: start.addingTimeInterval(602)))
    XCTAssertTrue(request.update(mode: .blocked, now: start.addingTimeInterval(603)))
    XCTAssertTrue(request.update(mode: .tool, now: start.addingTimeInterval(604)))
    XCTAssertFalse(request.update(mode: .unknown, now: start.addingTimeInterval(605)))
  }
  func testLidPolicyMatchesSleepChoicesAndBatterySafeguard() {
    let low = Battery(percent: 5, charging: false, plugged: false, watts: 0)
    for policy in ["never", "agents", "always"] {
      for active in [false, true] {
        let settings: JSONObject = ["sleep_prevention_policy": policy]
        let shouldClose = policy == "never" || (policy == "agents" && !active)
        XCTAssertEqual(
          LidAnimationPolicy.shouldClose(settings: settings, agentsActive: active), shouldClose)
        XCTAssertEqual(
          LidAnimationPolicy.shouldHold(
            closed: true, settings: settings, agentsActive: active, battery: nil), shouldClose)
        XCTAssertTrue(
          LidAnimationPolicy.shouldHold(
            closed: true, settings: settings, agentsActive: active, battery: low))
        XCTAssertFalse(
          LidAnimationPolicy.shouldHold(
            closed: false, settings: settings, agentsActive: active, battery: low))
      }
    }
  }
  func testClosedLidKeepsFinalFrameUntilWorkResumesAndSkipsCloseWhenAlwaysAwake() throws {
    let device = try volume()
    var now = Date()
    var closed = false
    let output = Output(now: { now }, lidClosed: { closed })
    let file = device.root.appendingPathComponent("LEDS.LED")
    try output.sync(devices: [device], mode: .idle, settings: [:], battery: nil)
    closed = true
    try output.sync(devices: [device], mode: .idle, settings: [:], battery: nil)
    let shutdown = try String(contentsOf: file)
    XCTAssertEqual(shutdown, try Programs.preset("lid-closed", count: 8))
    now.addTimeInterval(60)
    try output.sync(devices: [device], mode: .idle, settings: [:], battery: nil)
    XCTAssertEqual(try String(contentsOf: file), shutdown)
    try output.sync(devices: [device], mode: .working, settings: [:], battery: nil)
    XCTAssertEqual(
      try String(contentsOf: file), try Programs.program(.working, count: 8, settings: [:]))
    closed = false
    try output.sync(devices: [device], mode: .working, settings: [:], battery: nil)
    XCTAssertEqual(try String(contentsOf: file), try Programs.preset("lid-open", count: 8))
    now.addTimeInterval(2)
    let settings: JSONObject = ["sleep_prevention_policy": "always"]
    closed = true
    try output.sync(devices: [device], mode: .working, settings: settings, battery: nil)
    XCTAssertEqual(
      try String(contentsOf: file), try Programs.program(.working, count: 8, settings: settings))
  }
  @MainActor func testPhoneAndNotchUseBatteryPreviewWithoutOverridingManualMode() async throws {
    let phone = try Phone(
      token: String(repeating: "a", count: 64), name: "Phone", server: "https://example.invalid")
    var now = Date()
    var sent = [String]()
    let output = PhoneOutput(
      phones: { [phone] }, send: { _, program in sent.append(program) }, now: { now })
    let battery = Battery(percent: 42, charging: false, plugged: false, watts: 0)
    let power = Battery(percent: 42, charging: true, plugged: true, watts: 60)
    var settings: JSONObject = [
      "swift_phone_mirror": true, "virtual_status_device_enabled": true,
      "battery_monitoring": ["full_charge_watts": 60.0],
    ]
    try await output.sync(mode: .working, settings: settings, battery: battery)
    try await output.sync(mode: .working, settings: settings, battery: power)
    XCTAssertEqual(sent.last, power.program(count: 8, settings: settings))
    XCTAssertEqual(
      try NotchDisplay.program(
        settings: settings, mode: .working, battery: power, previewingBattery: true), sent.last)
    now.addTimeInterval(8)
    try await output.sync(mode: .working, settings: settings, battery: power)
    XCTAssertEqual(sent.last, try Programs.program(.working, count: 8, settings: settings))
    Settings.editDevice(phone.deviceID, in: &settings, values: ["led_display": "custom"])
    Settings.editDevice(NotchDisplay.deviceID, in: &settings, values: ["led_display": "custom"])
    try await output.sync(mode: .working, settings: settings, battery: battery)
    XCTAssertEqual(sent.count, 3)
    XCTAssertNil(
      try NotchDisplay.program(
        settings: settings, mode: .working, battery: battery, previewingBattery: true))
  }
  func testExternalDisplayWithACUsesNormalClamshellAndPreservesGraceOnBattery() throws {
    var now = Date()
    var changes = [Bool]()
    var external = false
    let system = SleepOverride.System(
      now: { now }, helperInstalled: { true }, disabled: { false }, lidClosed: { false },
      externalDisplay: { external }, disable: { changes.append($0) },
      sleepDisplay: { XCTFail("Lid is open") })
    let control = SleepOverride(system: system)
    let settings: JSONObject = ["swift_closed_lid": "agents"]
    let power = Battery(percent: 100, charging: false, plugged: true, watts: 0)
    try control.update(mode: .working, settings: settings, battery: power, owner: true)
    external = true
    try control.update(mode: .working, settings: settings, battery: power, owner: true)
    XCTAssertEqual(changes, [true, false])
    external = false
    try control.update(mode: .done, settings: settings, battery: power, owner: true)
    now.addTimeInterval(15)
    try control.update(mode: .idle, settings: settings, battery: power, owner: true)
    XCTAssertEqual(changes, [true, false, true])
    now.addTimeInterval(300)
    try control.update(mode: .idle, settings: settings, battery: power, owner: true)
    XCTAssertEqual(changes, [true, false, true, false])
  }
}
