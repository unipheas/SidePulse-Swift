import DiskArbitration
import XCTest

@testable import PulseCore

final class BoundaryTests: IsolatedTests {
  func testProfileImportPreservesCollidingCustomAnimationsAndRejectsMissingPayloads() throws {
    try Profiles.select("ember")
    let saved = try Profiles.save(name: "Ember copy")
    XCTAssertEqual(
      ((try Settings.read()["agent_animation_profiles"] as? [String: JSONObject])?[saved]?[
        "animations"] as? [String: String])?.filter {
          !["lid_open", "lid_closed"].contains($0.key)
        },
      try Programs.profile("ember").filter { !["lid_open", "lid_closed"].contains($0.key) })
    let file = root.appendingPathComponent("collision.json")
    try Profiles.export(to: file)
    var profile = try object(file)
    var mapping = try XCTUnwrap(profile["animations"] as? [String: String])
    mapping[Mode.working.rawValue] = "custom:collision"
    profile["animations"] = mapping
    try saveObject(profile, to: file)
    let before = try Data(contentsOf: Settings.url)
    XCTAssertThrowsError(try Profiles.load(from: file)) {
      XCTAssertTrue($0.localizedDescription.contains("Missing custom"))
    }
    XCTAssertEqual(try Data(contentsOf: Settings.url), before)
    try Settings.update {
      $0["custom_agent_animations"] = [
        "custom:collision": ["name": "Original", "program": "#FF0000"]
      ]
    }
    var custom = profile["custom_animations"] as? [String: JSONObject] ?? [:]
    custom["custom:collision"] = ["name": "Imported", "program": "#00FF00"]
    profile["custom_animations"] = custom
    try saveObject(profile, to: file)
    try Profiles.load(from: file)
    let settings = try Settings.read()
    let registry = try XCTUnwrap(settings["custom_agent_animations"] as? [String: JSONObject])
    XCTAssertEqual(registry["custom:collision"]?["program"] as? String, "#FF0000")
    let style = try XCTUnwrap(
      (settings["agent_animations"] as? [String: JSONObject])?[Mode.working.rawValue]?["style"]
        as? String)
    XCTAssertNotEqual(style, "custom:collision")
    XCTAssertEqual(registry[style]?["program"] as? String, "#00FF00")
  }

  func testDefaultPathsRemainWithinTheSelectedUserHome() throws {
    for key in keys { unsetenv(key) }
    XCTAssertEqual(Paths.home, FileManager.default.homeDirectoryForCurrentUser)
    XCTAssertEqual(
      Paths.support, Paths.home.appendingPathComponent("Library/Application Support/SidePulse"))
    XCTAssertEqual(
      Paths.legacyConfig, Paths.home.appendingPathComponent(".config/sidepulse/agent-monitor"))
    XCTAssertEqual(
      Paths.legacyState, Paths.home.appendingPathComponent(".local/state/sidepulse/agent-monitor"))
    setenv("SIDEPULSE_USER_HOME", root.path, 1)
    setenv("XDG_CONFIG_HOME", "", 1)
    XCTAssertEqual(
      Paths.legacyConfig, root.appendingPathComponent(".config/sidepulse/agent-monitor"))
    // This test only resolves URLs; it never reads or writes the real user's settings.
  }

  func testMalformedHookFilesAreRejectedWithoutOverwritingThem() throws {
    let executable = root.appendingPathComponent("sidepulsectl")
    XCTAssertThrowsError(try Hooks.configure("unknown", executable: executable, install: true))
    let codex = Paths.home.appendingPathComponent(".codex/config.toml")
    try Paths.directory(codex.deletingLastPathComponent())
    for bytes in [Data([0xff, 0xfe]), Data("# BEGIN SidePulse Swift hooks\n".utf8)] {
      try bytes.write(to: codex)
      XCTAssertThrowsError(try Hooks.configure("codex", executable: executable, install: true))
      XCTAssertEqual(try Data(contentsOf: codex), bytes)
    }
    try Data("[features]\nexisting = true\n".utf8).write(to: codex)
    try Hooks.configure("codex", executable: executable, install: true)
    let text = try String(contentsOf: codex)
    XCTAssertTrue(text.contains("existing = true"))
    XCTAssertEqual(text.components(separatedBy: "hooks = true").count, 2)
    let claude = Paths.home.appendingPathComponent(".claude/settings.json")
    try Paths.directory(claude.deletingLastPathComponent())
    for config: JSONObject in [["hooks": []], ["hooks": ["SessionStart": "invalid"]]] {
      try saveObject(config, to: claude)
      let before = try Data(contentsOf: claude)
      XCTAssertThrowsError(try Hooks.configure("claude", executable: executable, install: true))
      XCTAssertEqual(try Data(contentsOf: claude), before)
    }
  }
  func testCursorShellExitCodeIsPreservedForFailureClassification() throws {
    let payload = try XCTUnwrap(
      HookPayload.normalized(
        [
          "hook_event_name": "afterShellExecution", "exit_code": 17, "conversation_id": "fixture",
        ], provider: "cursor"))
    XCTAssertEqual((payload["tool_response"] as? JSONObject)?["exit_code"] as? Int, 17)
    XCTAssertTrue(HookPayload.failed(payload["tool_response"]))
    XCTAssertThrowsError(try Programs.preset("not-an-animation", count: 8))
  }
  func testHistoryRotationDropsPartialRowsAndKeepsTheLatestState() throws {
    try Paths.directory(Paths.support)
    let change = Change(date: Date(timeIntervalSince1970: 123), mode: .working, battery: 80)
    var line = try JSONEncoder().encode(change)
    line.append(10)
    var data = Data()
    while data.count < 270000 { data.append(line) }
    try data.write(to: History.file)
    try History.record(.done, battery: 79)
    XCTAssertLessThan(try Data(contentsOf: History.file).count, 140000)
    XCTAssertEqual(History.recent().last?.mode, .done)
    XCTAssertEqual(History.recent().first?.mode, .working)
  }
  func testLaunchHandoffRefusesMissingOrUnknownLegacyJobs() throws {
    XCTAssertThrowsError(try Jobs.takeControl(run: { _, _ in Data() })) { error in
      XCTAssertTrue(error.localizedDescription.contains("Cannot locate"))
    }
    try Settings.update { $0["swift_paused_jobs"] = ["unrelated.job"] }
    XCTAssertThrowsError(
      try Jobs.giveBack(run: { _, _ in
        XCTFail()
        return Data()
      }))
    XCTAssertFalse(Jobs.running("fixture-does-not-exist", scope: .user))
    XCTAssertFalse(Jobs.running("fixture-does-not-exist", scope: .system))
    XCTAssertThrowsError(
      try Jobs.configure("service", executable: root, start: false, scope: .system))
    // No matching legacy jobs exist in the test environment; these public entrypoints
    // only update the isolated settings file and do not bootstrap any agent.
    guard !Output.legacyRunning() else { throw XCTSkip("A legacy writer is active") }
    try Jobs.takeControl()
    try Jobs.giveBack()
  }
}

extension BoundaryTests {
  func testBridgeRejectsInvalidChannelsAndAmbiguousPhonesBeforeNetworking() async {
    do {
      try await Bridge.push(to: nil, program: "off", title: nil, message: nil)
      XCTFail("No phone selected")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Select one paired phone")) }
    do {
      try await Bridge.events("invalid") { _ in
        XCTFail()
        return false
      }
      XCTFail("Invalid channel accepted")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid bridge channel")) }
    do {
      try await Bridge.send(channel: "bad", provider: "codex", row: [:])
      XCTFail("Invalid channel accepted")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid relay channel")) }
    do {
      try await Bridge.receive(channel: "bad")
      XCTFail("Invalid channel accepted")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid relay channel")) }
  }
}

extension BoundaryTests {
  func testEjectGuardRejectsMissingSessionAndRecognizesBuiltInSDMetadata() {
    XCTAssertThrowsError(try EjectGuard.run(createSession: { nil }))
    XCTAssertFalse(GuardContext.builtInSD([:]))
    XCTAssertFalse(
      GuardContext.builtInSD(["DADeviceProtocol": "USB", "DADeviceModel": "Disk image"]))
    XCTAssertTrue(GuardContext.builtInSD(["DADeviceProtocol": "Secure Digital"]))
    XCTAssertTrue(GuardContext.builtInSD(["DADeviceModel": "Apple SDXC Reader"]))
  }
}

extension BoundaryTests {
  func testMalformedAndMinimalPersistedDataUseSafeDefaults() throws {
    try saveObject(["version": 2], to: RelayConfiguration.file)
    XCTAssertThrowsError(try RelayConfiguration.read())
    try saveObject(["version": 1], to: RelayConfiguration.file)
    let relay = try RelayConfiguration.read()
    XCTAssertEqual(relay.receiverChannel, "")
    XCTAssertEqual(relay.outboundChannel, "")
    XCTAssertFalse(relay.machineName.isEmpty)
    try saveObject(["ios": [["token": String(repeating: "a", count: 64)]]], to: Bridge.file)
    XCTAssertEqual(try Bridge.phones().first?.name, "Phone")
    try saveObject(["ios": [[:]]], to: Bridge.file)
    XCTAssertThrowsError(try Bridge.phones())
    XCTAssertNil(Events.date("not-a-timestamp"))
    XCTAssertNotNil(Events.date("2026-11-06T12:34:56Z"))
    XCTAssertFalse(HookPayload.failed(["success": true]))
    XCTAssertEqual(Programs.scaleColor("invalid", by: 0.5), "#000000")
    let session = Session(
      provider: "codex", session: "local-session", name: "Local", event: "Stop", date: Date(),
      mode: .done)
    XCTAssertTrue(Terminal.title(for: session).contains("local-se"))
    let device = Device(root: root, model: "Pro", firmware: "1.1.0", serial: "fixture")
    XCTAssertEqual(device.programFile, "LEDS.LED")
    try Audit.record(provider: "codex", row: ["hook_event_name": "Stop"], status: nil)
    let csv = root.appendingPathComponent("event.csv")
    // Partial historical audit entries still export a complete CSV row.
    var data = try Data(contentsOf: Audit.file)
    data.append(Data("{\"provider\":\"codex\"}\n".utf8))
    try data.write(to: Audit.file)
    try Audit.export(to: csv)
    XCTAssertTrue(try String(contentsOf: csv).contains("codex"))
  }
  func testDisplayProbeHandlesARealDisplayAndSyntheticExternalDisplay() {
    _ = Power.externalDisplay()
    let external = Power.externalDisplay(
      list: { capacity, displays, count in
        count?.pointee = 1
        if capacity > 0 { displays?.pointee = UInt32.max }
        return .success
      }, isBuiltIn: { _ in false })
    XCTAssertEqual(external, true)
  }
}

extension BoundaryTests {
  func testMissingDiskIdentityIsAllowedWithoutCreatingAnEjectRequest() throws {
    let session = try XCTUnwrap(DASessionCreate(nil))
    let disk = try XCTUnwrap(DADiskCreateFromBSDName(nil, session, "/dev/disk99999999"))
    let context = GuardContext(session: session)
    XCTAssertNil(context.approve(disk))
  }
}

extension BoundaryTests {
  func testBuiltInProCanBeProtectedBeforeVolumeDiscoveryCompletes() throws {
    let session = try XCTUnwrap(DASessionCreate(nil))
    guard let device = Device.discover().first(where: { $0.model == "Pro" }),
      let disk = DADiskCreateFromVolumePath(nil, session, device.root as CFURL),
      let whole = DADiskCopyWholeDisk(disk),
      let description = DADiskCopyDescription(whole) as NSDictionary?,
      GuardContext.builtInSD(description)
    else { throw XCTSkip("Requires a Pro in the built-in card reader") }
    // Evaluates approval only; no eject, mount or device write is requested.
    let context = GuardContext(session: session)
    XCTAssertNotNil(context.approve(disk)?.takeRetainedValue())
  }
}
