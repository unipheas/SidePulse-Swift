import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class ViewActionTests: IsolatedTests {
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
