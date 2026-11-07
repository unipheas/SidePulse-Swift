import XCTest

@testable import PulseCLI
@testable import PulseCore

final class RemainingBoundaryTests: IsolatedTests {
  func testProfileImportWithoutCustomLibraryAndUnnamedLibraryItems() throws {
    XCTAssertThrowsError(try Profiles.delete("profile:absent"))
    XCTAssertThrowsError(
      try Settings.setAnimation(.idle, program: "off", libraryID: "custom:absent"))
    let file = root.appendingPathComponent("profile.json")
    var mapping = try Programs.profile("cyan")
    var doc: JSONObject = [
      "format": "sidepulse-animation-profile", "version": 1, "name": "Basic", "animations": mapping,
    ]
    try saveObject(doc, to: file)
    try Profiles.load(from: file)
    mapping[Mode.idle.rawValue] = "custom:unnamed"
    doc["animations"] = mapping
    doc["custom_animations"] = ["custom:unnamed": ["program": "off"]]
    try saveObject(doc, to: file)
    try Profiles.load(from: file)
    let library = try XCTUnwrap(Settings.read()["custom_agent_animations"] as? [String: JSONObject])
    XCTAssertEqual(library["custom:unnamed"]?["name"] as? String, "custom:unnamed")
  }

  func testDefaultTransportAdaptersRejectNonDeviceFixtures() throws {
    let device = try volume()
    try Data().write(to: device.root.appendingPathComponent("STATUS.TXT"))
    XCTAssertThrowsError(try Device.inspect(device.root))
    try Data("release_version 1.1.0\n".utf8).write(
      to: device.root.appendingPathComponent("STATUS.TXT"))
    XCTAssertEqual(try Device.inspect(device.root).serial, "")
    let transport = Device.Transport()
    XCTAssertThrowsError(try transport.pro([1], root.appendingPathComponent("missing")))
    XCTAssertThrowsError(try transport.dot([1], root.appendingPathComponent("missing")))
    var failing = transport
    failing.openFile = { _, _ in
      errno = 9999
      return -1
    }
    XCTAssertThrowsError(try Device.inspect(device.root).write("off", transport: failing)) {
      error in
      XCTAssertEqual((error as? POSIXError)?.code, .EIO)
    }
  }

  func testDefaultDotWaitAllowsAnAcknowledgementOnNextPoll() throws {
    var transaction: UInt16 = 0
    var polls = 0
    try DotChannel.upload(
      [1],
      readStatus: {
        polls += 1
        var status = Array("SPC2".utf8) + [UInt8](repeating: 0, count: 12)
        if polls >= 3 {
          status[4] = UInt8(truncatingIfNeeded: transaction)
          status[5] = UInt8(transaction >> 8)
          status[6] = 3
          status[8] = 1
          status[10] = 1
          status[12] = 1
        }
        return status
      },
      submit: {
        transaction = $0
        XCTAssertEqual($1, [1])
      })
    XCTAssertEqual(polls, 3)
  }

  func testDefaultAppOpenRejectsMissingBundleWithoutOpeningOtherApps() throws {
    let executable = root.appendingPathComponent("Missing.app/Contents/MacOS/sidepulsectl")
    XCTAssertThrowsError(try AppInstallation.open(executable: executable))
    Args.words = ["start", "--foreground"]
    XCTAssertThrowsError(try CLI.appCommand(executable: executable))
  }

  func testDefaultContinuousReportAndFollowWaitCanBeCancelled() async throws {
    let battery = Battery(percent: 50, charging: false, plugged: false, watts: 0)
    Args.words = ["leds"]
    try await Task {
      try await CLI.batteryCommand(
        read: { battery }, discover: { [] },
        wait: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
        })
    }.value
    Args.words = ["--device", root.appendingPathComponent("missing").path]
    try await Task {
      try await CLI.monitor(
        "leds", legacyRunning: { false },
        wait: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
        })
    }.value
    Args.words = ["logs", "--follow"]
    let follow = Task { try await CLI.serviceCommand("service") }
    try await Task.sleep(for: .milliseconds(20))
    follow.cancel()
    do {
      try await follow.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
  }
}

extension RemainingBoundaryTests {
  func testDefaultScoreboardWaitIsCancellable() async throws {
    let task = Task {
      try await Scoreboard.run(
        device: nil, score: nil, dryRun: true,
        fetch: { url in
          let json: JSONObject = [
            "events": [
              [
                "competitions": [
                  [
                    "competitors": [
                      ["team": ["displayName": "Spain"], "score": "1"],
                      ["team": ["displayName": "Argentina"], "score": "2"],
                    ]
                  ]
                ]
              ]
            ]
          ]
          return (
            try JSONSerialization.data(withJSONObject: json),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        }, output: { _ in })
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
  }

  func testDefaultAwakePolicyAndSnapshotChargerFallback() throws {
    let output = Output()
    let battery = Battery(percent: 50, charging: false, plugged: false, watts: 42)
    output.updateAwake(
      mode: .idle, settings: ["sleep_prevention_policy": "never"], battery: battery)
    XCTAssertFalse(output.isKeepingAwake)
    try History.record(.idle, battery: 50, snapshot: battery)
    XCTAssertEqual(History.recent().last?.chargerWatts, 42)
    _ = Jobs.running("fixture-absent", scope: .auto)
    XCTAssertEqual(Jobs.logDirectory(scope: .auto), Paths.support)
    XCTAssertThrowsError(
      try Jobs.configure("unknown", executable: root, start: false, scope: .auto))
    try Jobs.giveBack()
  }
}

extension RemainingBoundaryTests {
  func testCompatibilityArgumentsAndApplicationLinks() async throws {
    XCTAssertEqual(Args.initial([]), [])
    XCTAssertEqual(Args.initial(["/usr/local/bin/sidepulse", "devices"]), ["devices"])
    XCTAssertEqual(
      Args.initial(["/usr/local/bin/agent-monitor", "status"]), ["agent-monitor", "status"])
    let executable = root.appendingPathComponent("SidePulse.app/Contents/MacOS/sidepulsectl")
    var commands = [[String]]()
    for command in ["settings", "update"] {
      Args.words = [command]
      try await CLI.run(
        executable: executable,
        launch: { tool, arguments in
          XCTAssertEqual(tool, "/usr/bin/open")
          commands.append(arguments)
          return Data()
        })
    }
    XCTAssertEqual(
      commands,
      [
        ["-a", root.appendingPathComponent("SidePulse.app").path, "sidepulse-native://settings"],
        ["sidepulse-native://updates"],
      ])
    let gui = executable.deletingLastPathComponent().appendingPathComponent("SidePulse")
    try Paths.directory(gui.deletingLastPathComponent())
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: gui)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gui.path)
    Args.words = ["start", "--no-start"]
    try CLI.appCommand(executable: executable)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: Paths.home.appendingPathComponent(
          "Library/LaunchAgents/" + Jobs.prefix + "app.plist"
        ).path))
  }

  func testCommandDefaultsAndMalformedPollingNumbers() async throws {
    Args.words = []
    try await CLI.run()
    Args.words = ["agent-monitor"]
    try await CLI.run()
    Args.words = []
    try await CLI.batteryCommand(read: {
      Battery(percent: 70, charging: false, plugged: false, watts: 0)
    })
    Args.words = ["leds", "--interval", "invalid"]
    do {
      try await CLI.batteryCommand()
      XCTFail("Expected invalid polling interval")
    } catch { XCTAssertTrue(error.localizedDescription.contains("positive polling")) }
    for name in ["--interval", "--max-lines", "--recent-seconds"] {
      Args.words = [name, "invalid"]
      do {
        try await CLI.monitor("status")
        XCTFail("Expected invalid option")
      } catch { XCTAssertTrue(error is PulseError) }
    }
    Args.words = ["leds", "--once", "--dry-run"]
    do {
      try await CLI.batteryCommand(read: {
        Battery(percent: 70, charging: false, plugged: false, watts: 0)
      })
    } catch { XCTAssertTrue(error is PulseError) }
    Args.words = ["--once", "--dry-run"]
    try await CLI.monitor("leds")
  }
}

extension RemainingBoundaryTests {
  func testSetupCreatesAnIsolatedReceiverAndRejectsMissingExecutablesBeforeLaunchd() throws {
    Args.words = ["--no-status-bar"]
    XCTAssertThrowsError(
      try CLI.setup(
        executable: root.appendingPathComponent("missing"), hooks: { _ in Args.words = [] })
    ) {
      XCTAssertTrue($0.localizedDescription.contains("executable is missing"))
    }
    XCTAssertFalse(try RelayConfiguration.read().receiverChannel.isEmpty)
  }
}

extension RemainingBoundaryTests {
  func testBoundedFileReadsHandleTruncationAndEndOfFile() throws {
    let file = root.appendingPathComponent("events.jsonl")
    try Data("first\nsecond\n".utf8).write(to: file)
    XCTAssertEqual(try FileSlice.read(file, offset: 6, count: 6), Data("second".utf8))
    XCTAssertEqual(try FileSlice.read(file, offset: 100, count: 6), Data())
    try Data().write(to: file)
    XCTAssertEqual(try FileSlice.read(file, offset: 0, count: 6), Data())
    XCTAssertThrowsError(
      try FileSlice.read(root.appendingPathComponent("missing"), offset: 0, count: 6))
  }
  func testActiveSessionPolicyTreatsTimeoutsAndMissingBatteryConsistently() throws {
    let now = Date()
    let tool = Session(
      provider: "codex", session: "tool", name: "Tool", event: "PreToolUse", date: now, mode: .tool)
    let settings: JSONObject = [
      "agent_list": ["tool_running_timeout_seconds": 10, "idle_timeout_seconds": 20]
    ]
    XCTAssertTrue(Monitor.hasActive([tool], settings: settings, now: now))
    XCTAssertFalse(Monitor.hasActive([tool], settings: settings, now: now.addingTimeInterval(11)))
    let working = Session(
      provider: "codex", session: "work", name: "Work", event: "UserPromptSubmit", date: now,
      mode: .working)
    XCTAssertFalse(
      Monitor.hasActive([working], settings: settings, now: now.addingTimeInterval(21)))
    let output = Output()
    output.updateAwake(mode: .working, settings: ["sleep_prevention_policy": "never"], battery: nil)
    XCTAssertFalse(output.isKeepingAwake)
  }
}

extension RemainingBoundaryTests {
  func testACompletedToolWithoutAnotherHookEventuallyStopsWorking() {
    let now = Date()
    let item = Session(
      provider: "codex", session: "tool", name: "Tool", event: "PostToolUse", date: now,
      mode: .working)
    XCTAssertEqual(
      Monitor.aggregate([item], settings: [:], now: now.addingTimeInterval(119)), .working)
    XCTAssertEqual(
      Monitor.aggregate([item], settings: [:], now: now.addingTimeInterval(121)), .done)
    XCTAssertFalse(Monitor.hasActive([item], settings: [:], now: now.addingTimeInterval(121)))
    XCTAssertEqual(
      Monitor.aggregate([item], settings: [:], now: now.addingTimeInterval(1201)), .idle)
  }
}
