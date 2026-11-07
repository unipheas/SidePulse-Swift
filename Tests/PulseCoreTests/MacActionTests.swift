import SwiftUI
import XCTest

@testable import PulseCore
@testable import SidePulse

final class MacActionTests: IsolatedTests {
  @MainActor func testMacActionsValidateBundleAndForwardChoices() throws {
    var actions = MacActions()
    actions.executable = nil
    XCTAssertThrowsError(try actions.cli())
    actions.executable = root.appendingPathComponent("sidepulsectl")
    actions.executableExists = { _ in false }
    XCTAssertThrowsError(try actions.cli())
    actions.executableExists = { _ in true }
    var jobs: [String] = []
    actions.configureJob = { name, executable, enabled in
      XCTAssertEqual(executable.lastPathComponent, "sidepulsectl")
      jobs.append(name + ":" + String(enabled))
    }
    actions.jobRunning = { $0 == "service" }
    XCTAssertTrue(try actions.job("service", start: true))
    XCTAssertFalse(try actions.job("sdejectguard", start: false))
    XCTAssertEqual(jobs, ["service:true", "sdejectguard:false"])
    actions.hooks = { provider, executable, install in
      XCTAssertEqual(provider, "codex")
      XCTAssertFalse(install)
      XCTAssertEqual(executable.lastPathComponent, "sidepulsectl")
    }
    try actions.configureHooks("codex", install: false)
  }

  @MainActor func testDashboardActionsPersistChoicesAndReportBoundaryFailures() throws {
    try Settings.update { $0["sleep_prevention_policy"] = "never" }
    var actions = MacActions()
    var fail = false
    var controlled = false
    var helperInstalled = false
    actions.login = { enabled in
      if fail { throw PulseError("Login refused") }
      return enabled
    }
    actions.takeControl = {
      if fail { throw PulseError("Control refused") }
      controlled = true
    }
    actions.giveBack = {
      if fail { throw PulseError("Restore refused") }
      controlled = false
    }
    actions.executableExists = { _ in true }
    actions.hooks = { _, _, _ in if fail { throw PulseError("Hooks refused") } }
    actions.helperInstalled = { helperInstalled }
    let model = Dashboard(
      discover: { [] }, outputInUse: { !controlled }, poll: false, actions: actions)
    model.setLogin(true)
    XCTAssertTrue(model.login)
    model.setLogin(false)
    XCTAssertFalse(model.login)
    model.takeControl()
    XCTAssertTrue(controlled)
    model.restorePrevious()
    XCTAssertFalse(controlled)
    model.configureHooks("codex", install: true)
    XCTAssertNil(model.problem)
    model.setClosedLid("always")
    XCTAssertTrue(model.problem!.contains("Install the sleep helper"))
    XCTAssertNil(try Settings.read()["swift_closed_lid"])
    helperInstalled = true
    model.problem = nil
    model.setClosedLid("agents")
    XCTAssertEqual(try Settings.read()["swift_closed_lid"] as? String, "agents")
    model.setClosedLid("never")
    XCTAssertEqual(try Settings.read()["swift_closed_lid"] as? String, "never")
    fail = true
    model.setLogin(true)
    XCTAssertEqual(model.problem, "Login refused")
    model.takeControl()
    XCTAssertEqual(model.problem, "Control refused")
    model.restorePrevious()
    XCTAssertEqual(model.problem, "Restore refused")
    model.configureHooks("codex", install: false)
    XCTAssertEqual(model.problem, "Hooks refused")
    model.problem = nil
    let device = try volume()
    model.preview("#123456", on: device)
    XCTAssertEqual(
      try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")), "#123456")
    XCTAssertEqual(
      Settings.device(device.id, in: try Settings.read())["led_display"] as? String, "custom")
    model.preview("not a program", on: device)
    XCTAssertNotNil(model.problem)
  }

  @MainActor func testSetupCompletesOnlyAfterChosenOperationsSucceed() async throws {
    try Settings.update { $0["sleep_prevention_policy"] = "never" }
    var actions = MacActions()
    var calls: [String] = []
    var fail = false
    actions.executableExists = { _ in true }
    actions.configureJob = { name, _, _ in
      if fail { throw PulseError("Service unavailable") }
      calls.append(name)
    }
    actions.jobRunning = { _ in true }
    actions.hooks = { provider, _, _ in calls.append(provider) }
    actions.login = { enabled in
      calls.append("login")
      return enabled
    }
    actions.helper = { action, _ in
      calls.append(action)
      return "installed"
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let setup = Setup()
    setup.login = true
    setup.sleepHelper = true
    await setup.finish(using: model)
    XCTAssertEqual(calls, providers + ["service", "sdejectguard", "login", "install"])
    XCTAssertEqual(try Settings.read()["setup_screen_completed"] as? Bool, true)
    XCTAssertFalse(setup.busy)
    XCTAssertNil(setup.problem)
    calls = []
    setup.login = false
    setup.sleepHelper = false
    setup.protectCard = false
    setup.installHooks = false
    await setup.finish(using: model)
    XCTAssertEqual(calls, ["service"])
    try Settings.update { $0["setup_screen_completed"] = false }
    fail = true
    await setup.finish(using: model)
    XCTAssertEqual(setup.problem, "Service unavailable")
    XCTAssertFalse(setup.busy)
    XCTAssertEqual(try Settings.read()["setup_screen_completed"] as? Bool, false)
  }

  @MainActor func testFirmwareControllerConfirmsSerializesAndReportsOutcome() async throws {
    let device = try volume()
    var fail = false
    var calls: [Bool] = []
    let updater = FirmwareUpdate(upgrade: { received, dry in
      XCTAssertEqual(received, device)
      calls.append(dry)
      if fail { throw PulseError("Transfer failed") }
      return dry ? "Ready" : "Installed"
    })
    await updater.install()
    XCTAssertTrue(calls.isEmpty)
    await updater.update(device, dry: true)
    XCTAssertEqual(updater.status, "Ready")
    updater.request(device)
    XCTAssertTrue(updater.confirm)
    await updater.install()
    XCTAssertFalse(updater.confirm)
    XCTAssertEqual(updater.status, "Installed")
    fail = true
    await updater.update(device, dry: false)
    XCTAssertEqual(updater.status, "Transfer failed")
    XCTAssertFalse(updater.busy)
    XCTAssertEqual(calls, [true, false, false])

    var continuation: CheckedContinuation<String, Never>?
    let waiting = FirmwareUpdate(upgrade: { _, _ in
      await withCheckedContinuation { continuation = $0 }
    })
    let task = Task { await waiting.update(device, dry: true) }
    while continuation == nil { await Task.yield() }
    XCTAssertTrue(waiting.busy)
    await waiting.update(device, dry: false)
    XCTAssertEqual(waiting.status, "Checking firmware…")
    continuation?.resume(returning: "Checked")
    await task.value
    XCTAssertFalse(waiting.busy)
    XCTAssertEqual(waiting.status, "Checked")
  }
}

extension MacActionTests {
  @MainActor func testHelperAndBackgroundServiceControllersKeepActualStateOnFailure() async throws {
    try Settings.update { $0["sleep_prevention_policy"] = "never" }
    var installed = false
    var running = false
    var failure = false
    var actions = MacActions()
    actions.executableExists = { _ in true }
    actions.jobRunning = { _ in running }
    actions.configureJob = { _, _, start in
      if failure { throw PulseError("Job failed") }
      running = start
    }
    actions.helperInstalled = { installed }
    actions.helper = { action, _ in
      if failure { throw PulseError("Permission declined") }
      installed = action == "install"
      return "Finished"
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    XCTAssertTrue(model.toggleService("service"))
    XCTAssertFalse(model.toggleService("service"))
    let helper = SleepHelper()
    helper.refresh(using: actions)
    XCTAssertEqual(helper.status, "Helper not installed")
    await helper.perform("install", using: model)
    XCTAssertTrue(installed)
    XCTAssertEqual(helper.status, "Helper installed")
    XCTAssertFalse(helper.busy)
    await helper.perform("uninstall", using: model)
    XCTAssertFalse(installed)
    failure = true
    XCTAssertFalse(model.toggleService("service"))
    XCTAssertEqual(model.problem, "Job failed")
    await helper.perform("install", using: model)
    XCTAssertFalse(helper.busy)
    XCTAssertFalse(installed)
    XCTAssertEqual(model.problem, "Permission declined")
  }
}

extension MacActionTests {
  @MainActor func testDefaultMacAdaptersValidateUnknownJobsAndConfigureIsolatedHooks() async throws
  {
    var actions = MacActions()
    actions.executable = root.appendingPathComponent("sidepulsectl")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: actions.executable!)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: actions.executable!.path)
    XCTAssertThrowsError(try actions.job("invalid-fixture", start: true))
    XCTAssertFalse(actions.jobRunning("invalid-fixture"))
    try actions.configureHooks("codex", install: true)
    let config = Paths.home.appendingPathComponent(".codex/config.toml")
    XCTAssertTrue(try String(contentsOf: config).contains("SidePulse Swift hooks"))
    try actions.configureHooks("codex", install: false)
    XCTAssertFalse(try String(contentsOf: config).contains("SidePulse Swift hooks"))
    let status = try await actions.helper("status", actions.executable!)
    XCTAssertTrue(["installed", "not installed"].contains(status))
  }
  @MainActor func testDeferringSetupPersistsAndReportsUnwritableSettings() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    XCTAssertTrue(model.needsSetup)
    model.deferSetup()
    XCTAssertFalse(model.needsSetup)
    XCTAssertEqual(try Settings.read()["setup_screen_completed"] as? Bool, true)
    try FileManager.default.removeItem(at: Settings.url)
    try FileManager.default.createDirectory(at: Settings.url, withIntermediateDirectories: false)
    model.needsSetup = true
    model.deferSetup()
    XCTAssertTrue(model.needsSetup)
    XCTAssertNotNil(model.problem)
  }
}

extension MacActionTests {
  @MainActor func testMissingSleepHelperDoesNotPreventDashboardLEDOutput() throws {
    let device = try volume()
    try Settings.update {
      $0["swift_closed_lid"] = "always"
      $0["sleep_prevention_policy"] = "never"
    }
    var system = SleepOverride.System()
    system.helperInstalled = { false }
    system.disable = { _ in XCTFail("Must not change system sleep") }
    let model = Dashboard(
      discover: { [device] }, outputInUse: { false }, poll: false,
      sleepOverride: SleepOverride(system: system))
    XCTAssertTrue(model.problem?.contains("optional sleep helper") == true)
    XCTAssertFalse(try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")).isEmpty)
  }
}

extension MacActionTests {
  @MainActor func testLoginRegistrationReportsActualStatusAndFailures() throws {
    var enabled = false
    for desired in [true, false] {
      XCTAssertEqual(
        try MacActions.setLogin(
          desired, register: { enabled = true },
          unregister: { enabled = false }, status: { enabled }), desired)
    }
    XCTAssertThrowsError(
      try MacActions.setLogin(
        true, register: { throw PulseError("Denied") },
        unregister: {}, status: { false }))
    XCTAssertThrowsError(
      try MacActions.setLogin(
        false, register: {},
        unregister: { throw PulseError("Denied") }, status: { true }))
  }

  @MainActor func testDashboardReportsPhoneAndNotchErrorsWithoutStoppingLocalOutput() async throws {
    let device = try volume()
    try Settings.update {
      $0["swift_phone_mirror"] = true
      $0["virtual_status_device_enabled"] = true
      $0["sleep_prevention_policy"] = "never"
      $0["agent_animations"] = [
        Mode.idle.rawValue: ["style": "custom", "custom_program": "invalid command"]
      ]
    }
    let phoneOutput = PhoneOutput(phones: { throw PulseError("Pairing data unreadable") })
    let model = Dashboard(
      discover: { [device] }, outputInUse: { false }, poll: false, phoneOutput: phoneOutput)
    XCTAssertTrue(model.problem?.contains("Notch lights") == true)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(model.problem, "Pairing data unreadable")
    XCTAssertFalse(try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")).isEmpty)
    model.change { $0["virtual_status_device_enabled"] = false }
    for _ in 0..<10 { await Task.yield() }
  }
}

extension MacActionTests {
  @MainActor func testDashboardReportsInvalidRelayConfigurationAndKeepsLocalOutput() async throws {
    let device = try volume()
    try Settings.update { $0["sleep_prevention_policy"] = "never" }
    try saveObject(["version": 99], to: RelayConfiguration.file)
    let model = Dashboard(discover: { [device] }, outputInUse: { false }, poll: false)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(model.problem, "Unsupported relay configuration.")
    XCTAssertFalse(try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")).isEmpty)
  }
}

extension MacActionTests {
  @MainActor func testInstallationPreparationUsesBundleMetadataAndReportsUpgradeFailure() throws {
    let app = root.appendingPathComponent("Fixture.app")
    let contents = app.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/SidePulse")
    try Paths.directory(executable.deletingLastPathComponent())
    try Data("fixture".utf8).write(to: executable)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.unipheas.SidePulseSwift",
        "CFBundleExecutable": "SidePulse", "CFBundleVersion": "fixture-4",
        "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0
    ).write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: app))
    var actions = MacActions()
    var calls = 0
    actions.refreshServices = { url, version in
      calls += 1
      XCTAssertEqual(url.standardizedFileURL, contents.appendingPathComponent("MacOS/sidepulsectl"))
      XCTAssertEqual(version, "fixture-4")
      if calls == 2 { throw PulseError("Upgrade failed") }
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    model.prepareInstallation()
    XCTAssertEqual(calls, 0)
    model.prepareInstallation(bundle: bundle)
    XCTAssertEqual(calls, 1)
    model.prepareInstallation(bundle: bundle)
    XCTAssertEqual(model.problem, "Upgrade failed")
    try Settings.update { $0["installed_build"] = "fixture-4" }
    XCTAssertNoThrow(try MacActions().refreshServices(executable, "fixture-4"))
  }

  @MainActor func testMenuBarSceneChangesPersistAfterSceneReconciliation() async throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    XCTAssertTrue(model.menuBarInsertion.wrappedValue)
    model.menuBarInsertion.wrappedValue = true
    XCTAssertNil(try Settings.read()["show_menu_bar_icon"])
    model.menuBarInsertion.wrappedValue = false
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(model.menuBarVisible)
    XCTAssertEqual(try Settings.read()["show_menu_bar_icon"] as? Bool, false)
    model.menuBarInsertion.wrappedValue = true
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(model.menuBarInsertion.wrappedValue)
    XCTAssertEqual(try Settings.read()["show_menu_bar_icon"] as? Bool, true)
  }
}

extension MacActionTests {
  @MainActor func testLoginAdapterHandlesTheNonApplicationTestHost() throws {
    XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.unipheas.SidePulseSwift")
    let actions = MacActions()
    defer { _ = try? actions.login(false) }
    do { _ = try actions.login(true) } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    do { XCTAssertFalse(try actions.login(false)) } catch {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
    XCTAssertFalse(try MacActions.setLogin(false, unregister: {}))
  }
}
