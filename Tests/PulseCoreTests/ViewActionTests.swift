import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class ViewActionTests: IsolatedTests {
  @MainActor func testFirmwareConfirmationInvokesOnlyTheSelectedFixture() async throws {
    let device = try volume()
    let model = Dashboard(discover: { [device] }, outputInUse: { true }, poll: false)
    var writes = [Device]()
    let firmware = FirmwareUpdate(upgrade: { selected, dry in
      XCTAssertFalse(dry)
      writes.append(selected)
      return "Fixture installed"
    })
    let view = DeviceManagement(firmware: firmware).environmentObject(model)
    firmware.request(device)
    try view.inspect().find(ViewType.Form.self).confirmationDialog().actions().find(
      button: "Install firmware"
    ).tap()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(writes, [device])
    XCTAssertEqual(firmware.status, "Fixture installed")
    XCTAssertFalse(firmware.confirm)
    let diagnostics = DiagnosticsView(readBattery: { nil }).environmentObject(model)
    XCTAssertNoThrow(try diagnostics.inspect().find(text: "No internal battery found."))
  }

  @MainActor func testHelperButtonsRunOnlyInjectedActions() async throws {
    var actions = MacActions()
    var installed = false
    var operations: [String] = []
    actions.executableExists = { _ in true }
    actions.helperInstalled = { installed }
    actions.helper = { action, _ in
      operations.append(action)
      installed = action == "install"
      return "Finished"
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let helper = SleepHelper()
    let view = PowerPreferences(helper: helper).environmentObject(model)
    try view.inspect().find(button: "Install sleep helper…").tap()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(helper.status, "Helper installed")
    try view.inspect().find(button: "Remove sleep helper…").tap()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(helper.status, "Helper not installed")
    XCTAssertEqual(operations, ["install", "uninstall"])
  }
  @MainActor func testServiceButtonStartsOnlyInjectedJob() throws {
    var actions = MacActions()
    var running = false
    actions.executableExists = { _ in true }
    actions.jobRunning = { _ in running }
    actions.configureJob = { job, _, start in
      XCTAssertEqual(job, "service")
      running = start
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let view = BackgroundServicePreference(job: "service", title: "Monitoring").environmentObject(
      model)
    try view.inspect().find(button: "Start").tap()
    XCTAssertTrue(running)
  }
}

extension ViewActionTests {
  @MainActor func testSetupButtonCompletesSelectedActionsAndShowsFailures() async throws {
    var actions = MacActions()
    var jobs = [String]()
    actions.executableExists = { _ in true }
    actions.configureJob = { name, _, _ in jobs.append(name) }
    actions.jobRunning = { _ in false }
    actions.hooks = { _, _, _ in }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let setup = Setup()
    let view = SetupView(setup: setup).environmentObject(model)
    try view.inspect().find(button: "Set up SidePulse").tap()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(jobs, ["service", "sdejectguard"])
    XCTAssertFalse(model.needsSetup)
    setup.problem = "Setup needs attention"
    XCTAssertEqual(
      try view.inspect().find(text: "Setup needs attention").string(), "Setup needs attention")
  }

  @MainActor func testDevicePreviewAndBrightnessPersistToIsolatedDevice() throws {
    let device = try volume()
    let model = Dashboard(discover: { [device] }, outputInUse: { true }, poll: false)
    model.legacy = false  // This fixture owns its output on CI as well as the development Mac.
    let preview = DevicePreviewMenu(source: "#FF0000").environmentObject(model)
    try preview.inspect().find(button: device.name).tap()
    XCTAssertEqual(
      try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")), "#FF0000")
    let slider = DeviceBrightnessPreference(id: device.id).environmentObject(model)
    try slider.inspect().find(ViewType.Slider.self).setValue(128.0 / 255.0)
    XCTAssertEqual(Settings.device(device.id, in: try Settings.read())["brightness"] as? Int, 128)
  }

  @MainActor func testSessionMenuPrimaryAndAlternateActionsReportFailure() throws {
    var actions = MacActions()
    var targets = [SessionTarget?]()
    var fail = false
    actions.openSession = { target, _, _ in
      targets.append(target)
      if fail { throw PulseError("Session unavailable") }
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let session = Session(
      provider: "codex", session: "fixture", name: "Task", event: "Stop", date: Date(),
      threadID: "id", mode: .done)
    let view = SessionOpenMenu(session: session) { Text("Open") }.environmentObject(model)
    try view.inspect().find(ViewType.Menu.self).callPrimaryAction()
    fail = true
    let buttons = try view.inspect().findAll(ViewType.Button.self)
    XCTAssertFalse(buttons.isEmpty)
    for button in buttons { try button.tap() }
    XCTAssertEqual(model.problem, "Session unavailable")
    XCTAssertGreaterThan(targets.count, 1)
  }

  @MainActor func testFirmwareViewRequestsConfirmationAndShowsProgressAndResult() async throws {
    let device = try volume()
    let model = Dashboard(discover: { [device] }, outputInUse: { true }, poll: false)
    var continuation: CheckedContinuation<String, Never>?
    let firmware = FirmwareUpdate(upgrade: { _, _ in
      await withCheckedContinuation { continuation = $0 }
    })
    let view = DeviceManagement(firmware: firmware).environmentObject(model)
    try view.inspect().find(button: "Update firmware…").tap()
    XCTAssertTrue(firmware.confirm)
    XCTAssertEqual(firmware.selected, device)
    try view.inspect().find(button: "Check firmware").tap()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(firmware.busy)
    XCTAssertNoThrow(try view.inspect().find(ViewType.ProgressView.self))
    continuation?.resume(returning: "Verified fixture firmware")
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(
      try view.inspect().find(text: "Verified fixture firmware").string(),
      "Verified fixture firmware")
  }
}

extension ViewActionTests {
  @MainActor func testPreferenceBindingsPersistAndLoginUsesInjectedAction() throws {
    var actions = MacActions()
    var loginRequests = [Bool]()
    actions.login = {
      loginRequests.append($0)
      return $0
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let view = Preferences().environmentObject(model)
    for (label, key, value) in [
      ("Mirror status on connected devices", "swift_mirror", false),
      ("Mirror LED states to paired phones", "swift_phone_mirror", true),
      ("Show menu bar icon", "show_menu_bar_icon", false),
    ] {
      let toggle = try view.inspect().find(
        ViewType.Toggle.self, where: { try $0.labelView().text().string() == label })
      if try toggle.isOn() != value { try toggle.tap() }
      XCTAssertEqual(try Settings.read()[key] as? Bool, value)
    }
    let login = try view.inspect().find(
      ViewType.Toggle.self, where: { try $0.labelView().text().string() == "Open at login" })
    if try !login.isOn() { try login.tap() }
    XCTAssertEqual(loginRequests, [true])
    XCTAssertTrue(model.login)
    let power = PowerPreferences().environmentObject(model)
    try power.inspect().find(
      ViewType.Picker.self,
      where: { try $0.labelView().text().string() == "Keep awake with lid closed" }
    ).select(value: "never")
    XCTAssertEqual(try Settings.read()["swift_closed_lid"] as? String, "never")
  }

  @MainActor func testBatteryBindingsAndExistingChargerSetting() throws {
    try Settings.update { $0["battery_monitoring"] = ["full_charge_watts": 96] }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let view = BatteryPreferences().environmentObject(model)
    try view.inspect().find(ViewType.Picker.self).select(value: "battery")
    XCTAssertEqual(try Settings.read()["led_display"] as? String, "battery")
    try view.inspect().find(ViewType.Toggle.self).tap()
    XCTAssertEqual(
      (try Settings.read()["battery_monitoring"] as? JSONObject)?["show_on_power_change"] as? Bool,
      false)
    try view.inspect().find(ViewType.Section.self).callOnAppear()
  }
}

extension ViewActionTests {
  @MainActor func testPhonePreviewMenuUsesManualModeAndReportsInvalidPrograms() async throws {
    try Bridge.store(token: String(repeating: "a", count: 64), name: "Fixture Phone")
    let phone = try XCTUnwrap(Bridge.phones().first)
    var actions = MacActions()
    var sent = [String]()
    actions.previewPhone = { target, program in
      XCTAssertEqual(target.id, phone.id)
      sent.append(program)
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    model.legacy = false
    let view = DevicePreviewMenu(source: "#FF0000").environmentObject(model)
    try view.inspect().find(button: "Fixture Phone").tap()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(sent, ["#FF0000"])
    XCTAssertEqual(
      Settings.device(phone.deviceID, in: try Settings.read())["led_display"] as? String, "custom")
    await model.preview("invalid command", on: phone)
    XCTAssertNotNil(model.problem)
    XCTAssertEqual(sent.count, 1)
    let picker = DeviceDisplayPreference(id: phone.deviceID, title: "Display", allowsBattery: false)
      .environmentObject(model)
    XCTAssertThrowsError(try picker.inspect().find(text: "Battery"))
    try picker.inspect().find(ViewType.Picker.self).select(value: "agent")
    XCTAssertEqual(
      Settings.device(phone.deviceID, in: try Settings.read())["led_display"] as? String, "agent")
  }
}
