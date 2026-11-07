import XCTest

@testable import PulseCore

final class BoundaryTests: IsolatedTests {
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
