import XCTest

@testable import PulseCore

final class ParityTests: IsolatedTests {
  func testCustomHookPathsRoundTripAndBoundedMonitor() throws {
    let executable = root.appendingPathComponent("tool with spaces")
    let log = root.appendingPathComponent("logs/custom codex.jsonl")
    try Hooks.configure("codex", executable: executable, install: true, log: log)
    let config = try String(contentsOf: Paths.home.appendingPathComponent(".codex/config.toml"))
    XCTAssertTrue(config.contains("--log '" + log.path + "'"))
    try Settings.update { $0["hook_logs"] = ["codex": log.path] }
    let monitor = Monitor(maxLines: 1)
    try Events.record(provider: "codex", raw: ["session_id": "first"], named: "UserPromptSubmit")
    XCTAssertEqual(monitor.sessions().first?.session, "first")
    try Events.record(provider: "codex", raw: ["session_id": "second"], named: "Stop")
    XCTAssertEqual(monitor.sessions().map(\.session), ["second"])
    let override = root.appendingPathComponent("override.jsonl")
    try Events.record(provider: "codex", raw: ["session_id": "third"], named: "Stop", log: override)
    XCTAssertEqual(Monitor(logs: ["codex": override]).sessions().map(\.session), ["third"])
    for provider in ["claude", "cursor", "grok", "junie"] {
      try Hooks.configure(provider, executable: executable, install: true, log: log)
      try Hooks.configure(provider, executable: executable, install: true, log: override)
      let file = Paths.home.appendingPathComponent(Hooks.configs[provider]!)
      let text = try String(contentsOf: file)
      XCTAssertFalse(text.contains(log.path))
      XCTAssertTrue(text.contains(override.path))
      try Hooks.configure(provider, executable: executable, install: false)
      XCTAssertFalse(try String(contentsOf: file).contains("# sidepulse-swift"))
    }
  }

  func testLegacyHistoryImportPreservesPowerAndIsIdempotent() throws {
    try History.importLegacy()
    XCTAssertTrue(History.recent().isEmpty)
    try Paths.directory(Paths.legacyState)
    let row: JSONObject = [
      "recorded_at": "2026-11-06T12:00:00Z", "agent_status": "working",
      "battery_level": 80, "battery_charging": true, "charger_power_watts": 65.5,
      "battery_power_watts": 42.2, "sidepulse_keep_awake_active": true, "lid_closed": false,
      "mac_sleep_disabled": false, "mac_prevent_system_sleep": true,
      "mac_prevent_user_idle_system_sleep": true, "mac_prevent_user_idle_display_sleep": false,
      "mac_user_is_active": true,
    ]
    var data = Data("malformed\n{}\n".utf8)
    data.append(try JSONSerialization.data(withJSONObject: row))
    data.append(10)
    try data.write(to: Paths.legacyState.appendingPathComponent("status-history.jsonl"))
    try Settings.migrate()
    try History.importLegacy()
    XCTAssertEqual(History.recent().count, 1)
    let entry = try XCTUnwrap(History.recent().first)
    XCTAssertEqual(entry.mode, .working)
    XCTAssertEqual(entry.battery, 80)
    XCTAssertEqual(entry.chargerWatts, 65.5)
    XCTAssertEqual(entry.batteryWatts, 42.2)
    XCTAssertEqual(entry.power?.preventsIdleSleep, true)
    try History.record(.done, battery: 81)
    XCTAssertEqual(History.recent().count, 2)
    let export = root.appendingPathComponent("history.csv")
    try History.export(to: export)
    XCTAssertTrue(try String(contentsOf: export).contains("65.5"))
  }
}

extension ParityTests {
  func testLaunchScopesStopVersusUninstallAndDeferredAppStart() throws {
    let executable = root.appendingPathComponent("SidePulse.app/Contents/MacOS/SidePulse")
    var calls = [[String]]()
    let run: (String, [String]) throws -> Data = { _, args in
      calls.append(args)
      if args.first == "print" { throw PulseError("not loaded") }
      return Data()
    }
    try Jobs.configure("app", executable: executable, start: true, run: run, launch: false)
    XCTAssertFalse(calls.contains { $0.first == "bootstrap" })
    let appFile = Jobs.plist(Jobs.prefix + "app")
    let config =
      try PropertyListSerialization.propertyList(from: Data(contentsOf: appFile), format: nil)
      as? JSONObject
    XCTAssertEqual(config?["ProgramArguments"] as? [String], [executable.path])
    try Jobs.configure("app", executable: executable, start: false, run: run, remove: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: appFile.path))
    try Jobs.configure("app", executable: executable, start: false, run: run)
    XCTAssertFalse(FileManager.default.fileExists(atPath: appFile.path))
    try Jobs.configure(
      "sdejectguard", executable: executable, start: true, run: run, system: true,
      systemDirectory: root.appendingPathComponent("LaunchDaemons"))
    XCTAssertTrue(calls.contains { $0.first == "bootstrap" && $0[1] == "system" })
    XCTAssertThrowsError(
      try Jobs.configure("app", executable: executable, start: true, run: run, system: true))
  }
  func testPackagedAppAndSleepHelperOperations() throws {
    XCTAssertThrowsError(try AppInstallation.bundle(for: URL(fileURLWithPath: "/usr/bin/tool")))
    let app = root.appendingPathComponent("SidePulse.app")
    let exe = app.appendingPathComponent("Contents/MacOS/sidepulsectl")
    XCTAssertEqual(try AppInstallation.bundle(for: exe).path, app.path)
    var calls = [(String, [String])]()
    let run: (String, [String]) throws -> Data = { tool, args in
      calls.append((tool, args))
      return Data()
    }
    try AppInstallation.open(executable: exe, run: run)
    XCTAssertEqual(calls[0].1, [app.path])
    XCTAssertTrue(
      try AppInstallation.sleepHelper(action: "install", executable: exe, dryRun: true).contains(
        "sudo"))
    XCTAssertThrowsError(
      try AppInstallation.sleepHelper(action: "install", executable: exe, dryRun: false, run: run))
    let script = app.appendingPathComponent("Contents/Resources/sleep-helper.sh")
    try Paths.directory(script.deletingLastPathComponent())
    try Data().write(to: script)
    for action in ["install", "uninstall"] {
      _ = try AppInstallation.sleepHelper(action: action, executable: exe, dryRun: false, run: run)
      XCTAssertEqual(calls.last?.0, "/usr/bin/sudo")
      XCTAssertEqual(calls.last?.1.last, action)
    }
    _ = try AppInstallation.sleepHelper(action: "status", executable: exe, dryRun: false)
    XCTAssertThrowsError(
      try AppInstallation.sleepHelper(action: "bad", executable: exe, dryRun: true))
  }
  func testExplicitLEDFileTargetsRemainInsideSelectedDevice() throws {
    let device = try volume()
    let custom = try Device.inspect(device.root.appendingPathComponent("PREVIEW.LED"))
    try custom.write("#123456")
    XCTAssertEqual(
      try String(contentsOf: device.root.appendingPathComponent("PREVIEW.LED")), "#123456")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: device.root.appendingPathComponent("LEDS.LED").path))
    XCTAssertThrowsError(try Device.inspect(device.root, fileName: "../other.LED"))
    XCTAssertThrowsError(try Device.inspect(device.root, fileName: "STATUS.TXT"))
  }
}

extension ParityTests {
  func testUpdatingInstalledAppRestartsExistingAgentsOnlyOnce() throws {
    var calls = [[String]]()
    let run: (String, [String]) throws -> Data = { _, args in
      calls.append(args)
      if args.first == "print", args.last?.hasSuffix("sdejectguard") == true {
        throw PulseError("not running")
      }
      return Data()
    }
    let executable = root.appendingPathComponent("sidepulsectl")
    try AppInstallation.refreshServices(executable: executable, version: "4", run: run)
    XCTAssertEqual(calls.filter { $0.first == "bootstrap" }.count, 1)
    calls.removeAll()
    try AppInstallation.refreshServices(executable: executable, version: "4", run: run)
    XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(Jobs.logDirectory(scope: .user), Paths.support)
    XCTAssertEqual(Jobs.logDirectory(scope: .system).path, "/Library/Logs/SidePulse")
  }
}

extension ParityTests {
  func testSleepSafeguardAcceptsFractionalThresholdAndRejectsInvalidValues() throws {
    for text in ["", "-1", "101", "nan", "inf"] {
      XCTAssertThrowsError(try Settings.setSleepMinimum(text))
    }
    try Settings.setSleepMinimum("20.5")
    XCTAssertEqual(
      (try Settings.read()["sleep_prevention"] as? JSONObject)?["min_battery_percent"] as? Double,
      20.5)
    let executable = root.appendingPathComponent("SidePulse.app/Contents/MacOS/sidepulsectl")
    let script = try AppInstallation.bundle(for: executable).appendingPathComponent(
      "Contents/Resources/sleep-helper.sh")
    try Paths.directory(script.deletingLastPathComponent())
    try Data().write(to: script)
    var arguments = [String]()
    _ = try AppInstallation.sleepHelper(
      action: "install", executable: executable, dryRun: false, administratorPrompt: true,
      run: { tool, args in
        XCTAssertEqual(tool, "/usr/bin/osascript")
        arguments = args
        return Data()
      })
    XCTAssertTrue(
      arguments.contains("do shell script (item 1 of argv) with administrator privileges"))
    XCTAssertTrue(arguments.last!.contains("SUDO_USER="))
  }
}

extension ParityTests {
  func testReusableAnimationsAndLidProgramsSurviveProfileRoundTrips() throws {
    XCTAssertThrowsError(try Settings.saveAnimation(name: " ", program: "off"))
    XCTAssertThrowsError(try Settings.saveAnimation(name: "bad", program: "nonsense"))
    let id = try Settings.saveAnimation(name: "Custom green", program: "#00FF00")
    XCTAssertEqual(
      (try Settings.read()["custom_agent_animations"] as? [String: JSONObject])?[id]?["program"]
        as? String, "#00FF00")
    try Settings.setLidAnimation("lid_open", program: "#123456", duration: 2)
    let profile = try Profiles.save(name: "Lid fixture")
    try Profiles.select("ember")
    XCTAssertNotEqual(
      (try Settings.read()["lid_open_animation"] as? JSONObject)?["program"] as? String, "#123456")
    try Profiles.select(profile)
    XCTAssertEqual(
      (try Settings.read()["lid_open_animation"] as? JSONObject)?["program"] as? String, "#123456")
    let file = root.appendingPathComponent("profile.json")
    try Profiles.export(to: file)
    try Profiles.select("cyan")
    try Profiles.load(from: file)
    XCTAssertEqual(
      (try Settings.read()["lid_open_animation"] as? JSONObject)?["program"] as? String, "#123456")
  }
}
