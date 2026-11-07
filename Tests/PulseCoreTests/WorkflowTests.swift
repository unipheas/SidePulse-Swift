import XCTest

@testable import PulseCore

final class WorkflowTests: IsolatedTests {
  func testFileBackedPresetsSurviveMigrationAndRoundTrip() throws {
    let folder = Paths.legacyConfig.appendingPathComponent("animations")
    try Paths.directory(folder)
    try Data("#123456 200ms".utf8).write(to: folder.appendingPathComponent("sample.LED"))
    try saveObject(
      [
        "custom_agent_animations": ["custom:sample": ["file": "sample.LED"]],
        "agent_animations": ["working": ["style": "custom:sample"]],
        "agent_list": ["completed_visible_seconds": 15],
      ],
      to: Paths.legacyConfig.appendingPathComponent("settings.json"))
    try Settings.migrate()
    try FileManager.default.removeItem(at: Paths.legacyConfig)
    try Settings.migrate()
    let json = root.appendingPathComponent("profile.json")
    try Profiles.export(to: json)
    try Profiles.select("ember")
    try Profiles.load(from: json)
    let settings = try Settings.read()
    XCTAssertEqual(try Programs.program(.working, count: 8, settings: settings), "#123456 200ms")
    XCTAssertEqual(Settings.seconds(settings, "completed_visible_seconds", default: 0), 15)
    try Profiles.select(try XCTUnwrap(settings["swift_profile"] as? String))
    XCTAssertThrowsError(try Profiles.select("missing"))
    try saveObject(["format": "invalid"], to: json)
    XCTAssertThrowsError(try Profiles.load(from: json))
  }

  func testUnsafeMigrationLeavesOriginalIntact() throws {
    try saveObject(
      ["custom_agent_animations": ["custom:bad": ["file": "../outside.LED"]]],
      to: Paths.legacyConfig.appendingPathComponent("settings.json"))
    XCTAssertThrowsError(try Settings.migrate())
    XCTAssertFalse(FileManager.default.fileExists(atPath: Settings.url.path))
    XCTAssertThrowsError(try Settings.setDone(.infinity))
    XCTAssertThrowsError(try Settings.setDone(-1))
  }

  func testAllHookInstallersAreIdempotentAndPreserveUserSettings() throws {
    let cli = root.appendingPathComponent("owner's tools/sidepulsectl")
    for provider in providers {
      let url = Paths.home.appendingPathComponent(try XCTUnwrap(Hooks.configs[provider]))
      if provider == "codex" {
        try Paths.directory(url.deletingLastPathComponent())
        try Data("[features]\nhooks = false\n[unrelated]\nx = 42\n".utf8).write(to: url)
      } else {
        try saveObject(["untouched": 42], to: url)
      }
      try Hooks.configure(provider, executable: cli, install: true)
      let once = try Data(contentsOf: url)
      try Hooks.configure(provider, executable: cli, install: true)
      XCTAssertEqual(try Data(contentsOf: url), once, provider)
      try Hooks.configure(provider, executable: cli, install: false)
      let text = try String(contentsOf: url, encoding: .utf8)
      XCTAssertFalse(text.contains("sidepulsectl"), provider)
      XCTAssertTrue(text.contains("42"), provider)
    }
  }

  func testPartialLogLinesRotationAndPermissionTransitions() throws {
    let dir = Paths.support.appendingPathComponent("events")
    try Paths.directory(dir)
    let log = dir.appendingPathComponent("claude.jsonl")
    let monitor = Monitor()
    let fields: JSONObject = [
      "session_id": "sample", "tool_name": "shell", "tool_input": ["command": "pwd"],
    ]
    func event(_ name: String) throws {
      try Events.record(provider: "claude", raw: fields, named: name)
    }
    try event("PermissionRequest")
    try event("PreToolUse")
    XCTAssertEqual(monitor.sessions().first?.mode, .waiting)
    try event("PostToolUse")
    XCTAssertEqual(monitor.sessions().first?.mode, .working)
    let first = try XCTUnwrap(monitor.sessions().first)
    let incomplete = Data(
      #"{"timestamp":"2099-01-01T00:00:00Z","hook_event_name":"Stop","session_id":"sample"}"#.utf8)
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: incomplete)
    XCTAssertEqual(monitor.sessions().first, first)
    try handle.write(contentsOf: Data([10]))
    try handle.close()
    XCTAssertEqual(monitor.sessions().first?.mode, .done)
    try Data("bad\n".utf8).write(to: log, options: .atomic)
    XCTAssertTrue(monitor.sessions().isEmpty)
  }

  func testHistorySuppressesDuplicatesAndExportsInOrder() throws {
    XCTAssertTrue(History.recent().isEmpty)
    try History.record(.working, battery: 50)
    try History.record(.working, battery: 50)
    try History.record(.working, battery: 49)
    try History.record(.done, battery: nil)
    XCTAssertEqual(History.recent().map(\.mode), [.working, .working, .done])
    for ext in ["html", "csv"] {
      let url = root.appendingPathComponent("history." + ext)
      try History.export(to: url)
      let value = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(value.contains(ext == "html" ? "<td>Done</td>" : ",completed,"))
      XCTAssertTrue(value.contains("50"))
    }
  }

  func testOutputRetriesAfterFailureAndHandlesPowerAndManualOverrides() throws {
    let device = try volume()
    let file = device.root.appendingPathComponent("LEDS.LED")
    var now = Date()
    var closed = false
    let output = Output(now: { now }, lidClosed: { closed })
    try Paths.directory(file)
    XCTAssertThrowsError(
      try output.sync(devices: [device], mode: .working, settings: [:], battery: nil))
    try FileManager.default.removeItem(at: file)
    try output.sync(devices: [device], mode: .working, settings: [:], battery: nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    now.addTimeInterval(11)
    let battery = Battery(percent: 20, charging: false, plugged: false, watts: 0)
    try output.sync(devices: [device], mode: .working, settings: [:], battery: battery)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8),
      try Programs.program(.working, count: 8, settings: [:]))
    let power = Battery(percent: 30, charging: true, plugged: true, watts: 60)
    try output.sync(devices: [device], mode: .working, settings: [:], battery: power)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), power.program(count: 8))
    closed = true
    try output.sync(devices: [device], mode: .working, settings: [:], battery: power)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8), try Programs.preset("lid-closed", count: 8))
    try Data("off".utf8).write(to: file)
    try output.sync(
      devices: [device], mode: .working, settings: ["led_display": "custom"], battery: nil)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "off")
    output.reset()
    try output.sync(devices: [], mode: .idle, settings: [:], battery: nil)
    XCTAssertEqual(
      Programs.brightness("brightness 100\n#010203", level: 128), "brightness 50\n#010203")
  }

  func testSessionTargetsUseThreadIdentityAndQuoteWorkingDirectory() throws {
    let session = try XCTUnwrap(
      Events.parse(
        provider: "codex",
        row: [
          "timestamp": "2026-01-01T00:00:00Z", "hook_event_name": "Stop",
          "session_id": "t/42", "agent_id": "worker", "cwd": "/tmp/user's project",
          "agentOrigin": "Codex CLI",
        ]))
    XCTAssertEqual(session.actions(preferences: [:]), [.terminal, .app])
    XCTAssertEqual(
      session.target(for: .app), .link(try XCTUnwrap(URL(string: "codex://threads/t%2F42"))))
    XCTAssertEqual(
      session.target(for: .terminal),
      .terminal("cd -- '/tmp/user'\\''s project' && codex resume 't/42'"))
    XCTAssertEqual(session.actions(preferences: ["codex": "app"]).first, .app)
    XCTAssertNil(session.target(for: .vscode))
  }
}

extension WorkflowTests {
  func testSavedProfileSnapshotsInlineAnimationAndDeletesCleanly() throws {
    try Settings.update {
      $0["agent_animations"] = ["working": ["style": "custom", "custom_program": "#FF0000"]]
    }
    let id = try Profiles.save(name: "Work")
    try Profiles.select("cyan")
    try Profiles.select(id)
    XCTAssertEqual(try Programs.program(.working, count: 8, settings: Settings.read()), "#FF0000")
    try Profiles.delete(id)
    XCTAssertEqual(try Settings.read()["swift_profile"] as? String, "current")
    XCTAssertThrowsError(try Profiles.delete(id))
    XCTAssertThrowsError(try Profiles.delete("cyan"))
    XCTAssertThrowsError(try Profiles.save(name: "   "))
  }
}

extension WorkflowTests {
  func testMigrationCarriesPhoneAndRelaySettings() throws {
    let token = String(repeating: "a", count: 64)
    try saveObject(
      ["version": 1, "ios": [["token": token, "name": "Original", "server": Bridge.standard]]],
      to: Paths.legacyConfig.appendingPathComponent("links.json"))
    let relay = RelayConfiguration(
      server: Bridge.standard, receiverChannel: "abcdefghijk", outboundChannel: "",
      machineName: "Fixture")
    try Paths.directory(Paths.legacyConfig)
    try JSONEncoder().encode(relay).write(
      to: Paths.legacyConfig.appendingPathComponent("relay.json"))
    try Settings.migrate()
    try FileManager.default.removeItem(at: Paths.legacyConfig)
    XCTAssertEqual(try Bridge.phones().first?.name, "Original")
    XCTAssertEqual(try RelayConfiguration.read(), relay)
    XCTAssertEqual(try RelayConfiguration.receiver(), relay)
    try RelayConfiguration.link("receiver2345")
    XCTAssertEqual(try RelayConfiguration.read().outboundChannel, "receiver2345")
    XCTAssertThrowsError(try RelayConfiguration.link("../bad"))
    XCTAssertEqual(try RelayConfiguration.read().outboundChannel, "receiver2345")
  }
}

extension WorkflowTests {
  func testMonitorKeepsSessionMetadataWhenLaterHooksOmitIt() throws {
    let monitor = Monitor()
    try Events.record(
      provider: "codex",
      raw: [
        "session_id": "id", "cwd": "/tmp/project", "session_title": "Build application",
        "agent_origin": "Codex CLI",
      ], named: "UserPromptSubmit")
    _ = monitor.sessions()
    try Events.record(provider: "codex", raw: ["session_id": "id"], named: "Stop")
    let session = try XCTUnwrap(monitor.sessions().first)
    XCTAssertEqual(session.name, "Build application")
    XCTAssertEqual(session.cwd, "/tmp/project")
    XCTAssertEqual(session.origin, "Codex CLI")
  }
  func testTranscriptDiscoveryUsesPrivateHomeAndClearsDisabledSources() throws {
    let folder = Paths.home.appendingPathComponent(".claude/projects/project")
    try Paths.directory(folder)
    let file = folder.appendingPathComponent("11111111-1111-4111-a111-111111111111.jsonl")
    let payload: JSONObject = [
      "timestamp": Events.timestamp(Date()), "type": "assistant",
      "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Done."]]],
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: file)
    let reader = TranscriptReader()
    XCTAssertEqual(
      reader.read(settings: ["transcript_monitoring": ["claude": true]]).first?.mode, .done)
    XCTAssertEqual(
      reader.read(settings: ["transcript_monitoring": ["claude": true]]).first?.threadID,
      "11111111-1111-4111-a111-111111111111")
    XCTAssertTrue(TranscriptReader().read(settings: [:]).isEmpty)
  }
}

extension WorkflowTests {
  func testRelayDefaultsAndInvalidConfiguration() throws {
    let empty = try RelayConfiguration.read()
    XCTAssertTrue(empty.receiverChannel.isEmpty)
    let receiver = try RelayConfiguration.receiver()
    XCTAssertEqual(receiver.receiverChannel.count, 32)
    var invalid = receiver
    invalid.version = 2
    XCTAssertThrowsError(try invalid.save())
    invalid = receiver
    invalid.server = "https://user@example.com/path"
    XCTAssertThrowsError(try invalid.save())
    try saveObject(["version": 1], to: RelayConfiguration.file)
    XCTAssertEqual(try RelayConfiguration.read().server, Bridge.server)
  }
}

extension WorkflowTests {
  func testLidAnimationValidationAndOutputPreserveSavedProgram() throws {
    let device = try volume()
    var closed = false
    var now = Date()
    let output = Output(now: { now }, lidClosed: { closed })
    try Settings.setLidAnimation("lid_closed", program: "#123456 1s", duration: 3)
    try output.sync(devices: [device], mode: .working, settings: Settings.read(), battery: nil)
    closed = true
    try output.sync(devices: [device], mode: .working, settings: Settings.read(), battery: nil)
    let file = device.root.appendingPathComponent("LEDS.LED")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "#123456 1s")
    XCTAssertThrowsError(
      try Settings.setLidAnimation("lid_closed", program: "invalid", duration: 3))
    now.addTimeInterval(4)
    try output.sync(devices: [device], mode: .working, settings: Settings.read(), battery: nil)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8),
      try Programs.program(.working, count: 8, settings: [:]))
  }
}

extension WorkflowTests {
  func testDisabledRelayReturnsWithoutNetworkResolution() async throws {
    XCTAssertFalse(Machine.name.isEmpty)
    let relay = Relay()
    let start = ProcessInfo.processInfo.systemUptime
    try await relay.sync([])
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    await relay.stop()
  }
}

extension WorkflowTests {
  func testBatteryPreferencesValidateBeforeSavingAndPreserveOtherSettings() throws {
    try Settings.setDone(15)
    try Settings.configureBattery(
      display: "battery", fullWatts: "96", showOnPowerChange: false, previewSeconds: "4.5")
    let saved = try Settings.read()
    XCTAssertEqual(saved["led_display"] as? String, "battery")
    XCTAssertEqual(
      (saved["battery_monitoring"] as? JSONObject)?["full_charge_watts"] as? Double, 96)
    XCTAssertEqual(
      (saved["battery_monitoring"] as? JSONObject)?["power_change_preview_seconds"] as? Double, 4.5)
    XCTAssertEqual(Settings.seconds(saved, "completed_visible_seconds", default: 0), 15)
    for watts in ["0", "-1", "nan", "inf", "invalid"] {
      XCTAssertThrowsError(try Settings.configureBattery(fullWatts: watts))
    }
    for seconds in ["-1", "nan", "inf", "invalid"] {
      XCTAssertThrowsError(try Settings.configureBattery(previewSeconds: seconds))
    }
    XCTAssertThrowsError(try Settings.configureBattery(display: "invalid"))
    XCTAssertEqual(try Settings.read() as NSDictionary, saved as NSDictionary)
    try Settings.configureBattery(fullWatts: "auto", previewSeconds: "0")
    XCTAssertNil((try Settings.read()["battery_monitoring"] as? JSONObject)?["full_charge_watts"])
  }
}

extension WorkflowTests {
  func testHistoryRecordsPowerChangesWithoutDuplicatingUnchangedSamples() throws {
    let battery = Battery(
      percent: 60, charging: true, plugged: true, watts: 96,
      adapterPower: 96, batteryPower: 42)
    var power = PowerSnapshot(
      lidClosed: false, sleepDisabled: false,
      preventsSystemSleep: true, preventsIdleSleep: true, preventsDisplaySleep: false,
      userActive: true)
    for _ in 0..<2 {
      try History.record(.working, battery: 60, snapshot: battery, keepingAwake: true, power: power)
    }
    power.lidClosed = true
    try History.record(.working, battery: 60, snapshot: battery, keepingAwake: true, power: power)
    let rows = History.recent()
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.last?.batteryWatts, 42)
    XCTAssertEqual(rows.last?.chargerWatts, 96)
    XCTAssertEqual(rows.last?.power?.lidClosed, true)
    let export = root.appendingPathComponent("power.csv")
    try History.export(to: export)
    let csv = try String(contentsOf: export)
    XCTAssertTrue(csv.contains("prevents_display_sleep"))
    XCTAssertTrue(csv.contains("96.0,42.0,true,true,false,true,true,false,true"))
    let old = Data("{\"date\":0,\"mode\":\"completed\",\"battery\":50}".utf8)
    XCTAssertNil(try JSONDecoder().decode(Change.self, from: old).power)
  }
}

extension WorkflowTests {
  func testAnimationEditsValidateAndPreserveOtherStates() throws {
    try Settings.setAnimation(.working, program: "#FF0000")
    try Settings.setAnimation(.done, program: "#00FF00")
    let settings = try Settings.read()
    XCTAssertEqual(try Programs.program(.working, count: 8, settings: settings), "#FF0000")
    XCTAssertEqual(try Programs.program(.done, count: 8, settings: settings), "#00FF00")
    XCTAssertThrowsError(try Settings.setAnimation(.working, program: "invalid"))
    XCTAssertEqual(try Settings.read() as NSDictionary, settings as NSDictionary)
  }
  func testMirroringSwitchAndManualPreviewAreHonoredByTheWriter() throws {
    let device = try volume()
    let file = device.root.appendingPathComponent("LEDS.LED")
    let output = Output(lidClosed: { nil })
    try output.sync(
      devices: [device], mode: .working, settings: ["swift_mirror": false], battery: nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    let settings: JSONObject = [
      "devices": [["id": device.id, "led_display": "custom", "manual_program": "#FF0000"]]
    ]
    try output.sync(devices: [device], mode: .working, settings: settings, battery: nil)
    XCTAssertEqual(try String(contentsOf: file), "#FF0000")
    try output.sync(devices: [device], mode: .done, settings: settings, battery: nil)
    XCTAssertEqual(try String(contentsOf: file), "#FF0000")
  }
  func testLidClosePreviewBeginsLitAndFadesToBlack() throws {
    let preview = try LEDPreview(program: "#000000 1s linear", count: 8, initialProgram: "#35CFB8")
    XCTAssertEqual(Array(preview.frame(milliseconds: 0).prefix(3)), [0x35, 0xCF, 0xB8])
    XCTAssertEqual(preview.frame(milliseconds: 1001), Array(repeating: 0, count: 24))
  }
}
