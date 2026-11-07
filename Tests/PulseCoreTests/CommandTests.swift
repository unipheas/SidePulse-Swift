import XCTest

@testable import PulseCLI
@testable import PulseCore

final class CommandTests: IsolatedTests {
  func testUnknownServiceCannotReachLaunchdMutation() async {
    Args.words = ["start"]
    do {
      try await CLI.serviceCommand("unknown-fixture")
      XCTFail("An unknown job must never be installed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Unknown job")) }
  }

  func testDeviceSelectionRejectsAmbiguityAndListsEmptyOrConnectedVolumes() throws {
    let device = try volume()
    XCTAssertThrowsError(try Args.one([])) {
      XCTAssertTrue($0.localizedDescription.contains("Connect"))
    }
    XCTAssertThrowsError(try Args.one([device, device])) {
      XCTAssertTrue($0.localizedDescription.contains("Select"))
    }
    for devices in [[], [device]] {
      Args.words = []
      try CLI.listDevices(discover: { devices })
    }
  }

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

extension CommandTests {
  func testSetupInstallsServiceGuardAndOptionalAppWithoutDroppingHooks() throws {
    let executable = root.appendingPathComponent("SidePulse.app/Contents/MacOS/sidepulsectl")
    let configuration = RelayConfiguration(
      server: "https://fixture.invalid", receiverChannel: "fixture_receiver", outboundChannel: "",
      machineName: "Fixture")
    for noApp in [false, true] {
      var jobs: [String] = []
      var hooked = false
      Args.words = noApp ? ["--no-status-bar"] : []
      try CLI.setup(
        executable: executable, hooks: { hooked = $0 }, receiver: { configuration },
        install: { job, path, scope in
          XCTAssertTrue(hooked)
          jobs.append(job)
          XCTAssertEqual(path.lastPathComponent, job == "app" ? "SidePulse" : "sidepulsectl")
          XCTAssertEqual(scope, job == "sdejectguard" ? .auto : .user)
        })
      XCTAssertEqual(
        jobs, noApp ? ["service", "sdejectguard"] : ["service", "sdejectguard", "app"])
    }
    for noApp in [false, true] {
      Args.words =
        ["--dry-run", "--sd-eject-guard-scope", "system"] + (noApp ? ["--no-status-bar"] : [])
      try CLI.setup(
        executable: executable,
        hooks: { _ in
          XCTAssertTrue(Args.flag("--dry-run"))
          try Args.end()
        },
        receiver: {
          XCTFail("Dry run changed receiver configuration")
          return configuration
        }, install: { _, _, _ in XCTFail("Dry run installed a job") })
    }
    Args.words = []
    XCTAssertThrowsError(
      try CLI.setup(
        executable: root.appendingPathComponent("cli"),
        hooks: { _ in XCTFail("Invalid install changed hooks") }))
    Args.words = ["--no-status-bar"]
    XCTAssertThrowsError(
      try CLI.setup(
        hooks: { _ in throw PulseError("Hook failure") },
        receiver: {
          XCTFail()
          return configuration
        }, install: { _, _, _ in XCTFail() }))
    Args.words = ["--no-status-bar"]
    XCTAssertThrowsError(
      try CLI.setup(
        hooks: { _ in }, receiver: { configuration },
        install: { _, _, _ in throw PulseError("Service failure") }))
  }

  func testPollingLoopsReturnWhenCancellationArrivesAfterSuccessfulWait() async throws {
    let device = try volume()
    let battery = Battery(percent: 60, charging: false, plugged: false, watts: 0)
    func cancel() { withUnsafeCurrentTask { $0?.cancel() } }
    Args.words = ["leds", "--dry-run", "--interval", "0.25"]
    try await Task {
      try await CLI.batteryCommand(
        read: { battery }, discover: { [device] },
        wait: {
          XCTAssertEqual($0, 0.25)
          cancel()
        })
    }.value
    Args.words = ["--interval", "0.5"]
    try await Task {
      try await CLI.monitor(
        "live", discover: { [] },
        wait: {
          XCTAssertEqual($0, 0.5)
          cancel()
        })
    }.value
    Args.words = ["logs", "--follow"]
    try await Task {
      try await CLI.serviceCommand("service", wait: { cancel() })
    }.value
    XCTAssertFalse(Task.isCancelled, "Cancellation must stay within the child task")
  }

  func testAppLifecycleRoutesActionsWithoutTouchingInstalledJobs() throws {
    let executable = root.appendingPathComponent("SidePulse.app/Contents/MacOS/sidepulsectl")
    var configured: [(String, URL, Bool, Bool)] = []
    var opened: [URL] = []
    var stopped = 0
    var helpers: [(String, URL, Bool)] = []
    func run(_ arguments: [String]) throws {
      Args.words = arguments
      try CLI.appCommand(
        executable: executable,
        configure: { configured.append(($0, $1, $2, $3)) },
        open: { opened.append($0) }, stop: { stopped += 1 },
        helper: {
          helpers.append(($0, $1, $2))
          return "fixture"
        })
    }
    try run([])
    try run(["start", "--no-start"])
    try run(["--uninstall"])
    XCTAssertEqual(configured.map(\.0), ["app", "app", "app"])
    XCTAssertEqual(configured.map(\.2), [true, true, false])
    XCTAssertEqual(configured.map(\.3), [true, false, true])
    XCTAssertTrue(configured.allSatisfy { $0.1.lastPathComponent == "SidePulse" })
    XCTAssertEqual(stopped, 1)
    try run(["start", "--foreground"])
    XCTAssertEqual(opened, [executable])
    try run(["stop", "--dry-run"])
    XCTAssertEqual(stopped, 1)
    for command in ["install-sleep-helper", "uninstall-sleep-helper", "sleep-helper-status"] {
      try run([command, "--dry-run"])
    }
    XCTAssertEqual(helpers.map(\.0), ["install", "uninstall", "status"])
    XCTAssertTrue(helpers.allSatisfy { $0.1 == executable && $0.2 })
    for args in [
      ["invalid"], ["start", "--foreground", "--no-start"], ["stop", "--foreground"],
      ["start", "unexpected"],
    ] {
      XCTAssertThrowsError(try run(args))
    }
  }

  func testHistoryTimeframeAcceptsLegacyAndNestedSettings() {
    XCTAssertEqual(Settings.historyHours(in: [:]), 24)
    for hours in [0, 1, 6, 12, 24, 48, 168] {
      XCTAssertEqual(
        Settings.historyHours(in: ["history_timeframe_seconds": Double(hours * 3600)]), hours)
      XCTAssertEqual(
        Settings.historyHours(in: ["history": ["timeframe_seconds": Double(hours * 3600)]]), hours)
    }
    for seconds in [-1.0, .infinity, .nan, 900_000, 7200] {
      XCTAssertEqual(Settings.historyHours(in: ["history": ["timeframe_seconds": seconds]]), 24)
    }
  }
}

extension CommandTests {
  func testServiceLifecycleLogsAndInteractiveRouting() async throws {
    var actions: [(String, Bool, Jobs.Scope, Bool)] = []
    var guards = 0
    var monitors = [String]()
    func run(_ job: String, _ arguments: [String]) async throws {
      Args.words = arguments
      try await CLI.serviceCommand(
        job, configure: { actions.append(($0, $1, $2, $3)) },
        running: { name, scope in name == "service" && scope == .user },
        guardRun: { guards += 1 }, monitorRun: { monitors.append($0) })
    }
    for action in ["start", "restart", "stop", "uninstall"] {
      try await run("service", [action])
      try await run("sdejectguard", [action, "--scope", "system", "--dry-run"])
    }
    XCTAssertEqual(actions.map(\.1), [true, true, false, false])
    XCTAssertEqual(actions.map(\.3), [false, false, false, true])
    try await run("service", [])
    try await run("sdejectguard", ["status", "--scope", "auto"])
    try await run("sdejectguard", ["start", "-it"])
    try await run("sdejectguard", ["run"])
    try await run("service", ["run"])
    XCTAssertEqual(guards, 2)
    XCTAssertEqual(monitors, ["leds"])
    try await run("service", ["logs", "--lines", "0"])
    try await run("service", ["code"])
    for args in [
      ["--scope", "invalid"], ["start", "--interactive"], ["logs", "--lines", "-1"],
      ["logs", "--lines", "oops"], ["unknown"],
    ] {
      do {
        try await run("service", args)
        XCTFail("Invalid command accepted")
      } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
  }

  func testFollowingServiceLogsHandlesAppendTruncationAndMissingFiles() async throws {
    let out = Paths.support.appendingPathComponent("service.out.log")
    let err = Paths.support.appendingPathComponent("service.err.log")
    try Paths.directory(Paths.support)
    try Data("original line\n".utf8).write(to: out)
    Args.words = ["logs", "--follow", "--lines", "1"]
    var passes = 0
    do {
      try await CLI.serviceCommand(
        "service",
        wait: {
          passes += 1
          switch passes {
          case 1:
            try Data("original line\nappended\n".utf8).write(to: out)
            try Data("new error file\n".utf8).write(to: err)
          case 2: try Data("reset\n".utf8).write(to: out)
          case 3:
            try FileManager.default.removeItem(at: out)
            try FileManager.default.removeItem(at: err)
          default: throw CancellationError()
          }
        })
      XCTFail("Expected cancellation")
    } catch is CancellationError { XCTAssertEqual(passes, 4) }
  }
}

extension CommandTests {
  func testMonitorCustomSourcesOutputAndCancellation() async throws {
    let device = try volume()
    try Settings.update {
      $0["swift_keep_awake"] = false
      $0["swift_closed_lid"] = "never"
      $0["swift_phone_mirror"] = true
    }
    let log = root.appendingPathComponent("custom-events.jsonl")
    try Events.record(
      provider: "codex", raw: ["session_id": "monitor-fixture", "session_title": "Fixture"],
      named: "Stop", log: log)
    for (sub, arguments) in [
      ("status", ["--all"]), ("live", ["--once", "--recent-seconds", "999"]),
      ("leds", ["--once", "--dry-run"]), ("leds", ["--once", "--file-name", "CUSTOM.LED"]),
    ] {
      Args.words =
        arguments + [
          "--codex-log", log.path, "--stale-after", "60", "--tool-running-timeout", "30",
        ]
      try await CLI.monitor(sub, discover: { [device] }, legacyRunning: { false })
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: device.root.appendingPathComponent("CUSTOM.LED").path))
    for arguments in [
      ["--interval", "0"], ["--stale-after", "nan"], ["--tool-running-timeout", "bad"],
    ] {
      Args.words = arguments
      do {
        try await CLI.monitor("status")
        XCTFail("Expected invalid timing")
      } catch {}
    }
    Args.words = ["--once"]
    do {
      try await CLI.monitor("leds", discover: { [device] }, legacyRunning: { true })
      XCTFail("Expected output ownership conflict")
    } catch { XCTAssertTrue(error.localizedDescription.contains("owns LED output")) }
    Args.words = ["--interval", "0.01", "--json"]
    let task = Task { try await CLI.monitor("live", discover: { [] }) }
    try await Task.sleep(for: .milliseconds(35))
    task.cancel()
    do { try await task.value } catch is CancellationError {}
  }
  func testBatteryDiscoveredDeviceHonorsCustomFilenameAndPollingCancellation() async throws {
    let device = try volume()
    let battery = Battery(percent: 60, charging: false, plugged: false, watts: 0)
    Args.words = ["leds", "--once", "--file-name", "BATTERY.LED"]
    try await CLI.batteryCommand(read: { battery }, discover: { [device] })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: device.root.appendingPathComponent("BATTERY.LED").path)
    )
    Args.words = ["leds", "--interval", "0.01", "--dry-run"]
    let task = Task { try await CLI.batteryCommand(read: { battery }, discover: { [device] }) }
    try await Task.sleep(for: .milliseconds(25))
    task.cancel()
    do { try await task.value } catch is CancellationError {}
  }
}

extension CommandTests {
  func testRememberedDevicesPreservePreferencesAndAvoidRepeatedWrites() throws {
    let device = try volume()
    let initial = try Settings.remember([device], settings: [:])
    XCTAssertEqual(Settings.device(device.id, in: initial)["name"] as? String, device.name)
    try Settings.update {
      Settings.editDevice(device.id, in: &$0, values: ["brightness": 73, "led_display": "battery"])
    }
    let configured = try Settings.read()
    let before = try Data(contentsOf: Settings.url)
    let remembered = try Settings.remember([device], settings: configured)
    XCTAssertEqual(Settings.device(device.id, in: remembered)["brightness"] as? Int, 73)
    XCTAssertEqual(before, try Data(contentsOf: Settings.url))
    XCTAssertEqual(
      (try Settings.remember([], settings: configured)["devices"] as? [JSONObject])?.count, 1)
  }
}
