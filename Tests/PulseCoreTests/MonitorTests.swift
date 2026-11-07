import XCTest

@testable import PulseCore

final class MonitorTests: IsolatedTests {
  let now = Date(timeIntervalSince1970: 1_750_000_000)
  func session(_ event: String, _ provider: String = "codex", _ extras: JSONObject = [:]) throws
    -> Session
  {
    var raw: JSONObject = ["hook_event_name": event, "session_id": "fixture"]
    raw.merge(extras) { _, new in new }
    return try XCTUnwrap(
      Events.parse(provider: provider, row: ["event": raw, "logged_at": now.ISO8601Format()]))
  }
  func testHookTimestampRoundTripsWithTimezoneAndMilliseconds() throws {
    let expected = now.addingTimeInterval(0.125)
    let timestamp = Events.timestamp(expected)
    XCTAssertTrue(timestamp.hasSuffix("Z"))
    XCTAssertEqual(
      try XCTUnwrap(Events.date(timestamp)).timeIntervalSince(expected), 0, accuracy: 0.001)
  }
  func testDoneExpiresAtConfiguredTime() throws {
    let done = try session("Stop")
    let settings: JSONObject = ["agent_list": ["completed_visible_seconds": 15]]
    XCTAssertEqual(
      Monitor.aggregate([done], settings: settings, now: now.addingTimeInterval(14)), .done)
    XCTAssertEqual(
      Monitor.aggregate([done], settings: settings, now: now.addingTimeInterval(15)), .idle)
    XCTAssertEqual(
      Monitor.aggregate([done], settings: [:], now: now.addingTimeInterval(1199)), .done)
  }
  func testActionableStatesTakePriority() throws {
    let sessions = try [
      session("Stop"), session("PermissionRequest", "claude"), session("PreToolUse"),
    ]
    XCTAssertEqual(Monitor.aggregate(sessions, settings: [:], now: now), .waiting)
    XCTAssertEqual(try session("Interrupt").mode, .idle)
    XCTAssertEqual(
      try session("Stop", "codex", ["last_assistant_message": "Shall I proceed?"]).mode, .waiting)
  }
  func testSimulatorRendersBothDevices() throws {
    for count in [2, 8] {
      let sim = try LEDPreview(program: "#FF0000 1s", count: count)
      let pixels = sim.frame(milliseconds: 100)
      XCTAssertEqual(pixels.count, count * 3)
      XCTAssertGreaterThan(pixels[0], 0)
      XCTAssertEqual(Array(pixels[1...2]), [0, 0])
      for mode in Mode.allCases {
        _ = try LEDPreview(
          program: Programs.program(mode, count: count, settings: [:]), count: count)
      }
    }
    XCTAssertThrowsError(try LEDPreview(program: "not a color", count: 8))
    XCTAssertFalse(Programs.animationNames.isEmpty)
  }
  func testLimitsAndBrightness() throws {
    XCTAssertThrowsError(try Programs.normalize(String(repeating: "x", count: 513)))
    XCTAssertThrowsError(
      try Programs.normalize(Array(repeating: "off", count: 21).joined(separator: "\n")))
    XCTAssertEqual(Programs.dim("#FF0000 1s", brightness: 128), "#800000 1s")
  }
  func testMountedDeviceWriteAndReidentification() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Paths.directory(url)
    defer { try? FileManager.default.removeItem(at: url) }
    let status = url.appendingPathComponent("STATUS.TXT")
    try Data("release_version 1.1.0\nserial fixture\n".utf8).write(to: status)
    let device = try Device.inspect(url)
    try device.write("off")
    XCTAssertEqual(
      try String(contentsOf: url.appendingPathComponent("LEDS.LED"), encoding: .utf8), "off")
    try Data("app_version 1.1.0\nserial other\n".utf8).write(to: status)
    XCTAssertThrowsError(try device.write("off"))
  }
  func testJunieObserverAndCustomHooksSurviveRoundTrip() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = home.appendingPathComponent(".junie/config.json")
    try saveObject(["keep": true, "hooks": ["Stop": [["other": 42]]]], to: file)
    let executable = home.appendingPathComponent("sidepulsectl")
    for _ in 0..<2 {
      try Hooks.configure("junie", executable: executable, install: true, home: home)
    }
    let hooks = try XCTUnwrap(try object(file)["hooks"] as? JSONObject)
    XCTAssertNil(hooks["PermissionRequest"])
    XCTAssertEqual((hooks["Stop"] as? [JSONObject])?.count, 2)
    try Hooks.configure("junie", executable: executable, install: false, home: home)
    XCTAssertEqual(
      ((try object(file)["hooks"] as? JSONObject)?["Stop"] as? [[String: Int]])?.first?["other"], 42
    )
  }
}

extension MonitorTests {
  func testLargeUnreadGapDropsStalePermissionsAndSessions() throws {
    let log = root.appendingPathComponent("gap.jsonl")
    try Events.record(
      provider: "codex", raw: ["session_id": "old"], named: "PermissionRequest", log: log)
    let monitor = Monitor(logs: ["codex": log])
    XCTAssertEqual(monitor.sessions().first?.mode, .waiting)
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 32, count: 2_097_153))
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()
    try Events.record(provider: "codex", raw: ["session_id": "new"], named: "Stop", log: log)
    let sessions = monitor.sessions()
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.mode, .done)
    XCTAssertTrue(sessions.first?.id.contains("new") == true)
    XCTAssertEqual(monitor.sessions().map(\.id), sessions.map(\.id))
  }

  func testInternalCodexTasksDoNotChangeTheDeviceState() throws {
    for prompt in [
      "Generate 0 to 3 hyperpersonalized suggestions",
      "You are an expert at upholding safety and compliance standards",
    ] {
      let row: JSONObject = [
        "logged_at": now.ISO8601Format(),
        "event": ["hook_event_name": "UserPromptSubmit", "prompt": prompt],
      ]
      XCTAssertNil(Events.parse(provider: "codex", row: row))
      XCTAssertEqual(Events.parse(provider: "claude", row: row)?.mode, .working)
    }
  }
}

extension MonitorTests {
  func testMergedHookSourcesAndTranscriptsChooseNewestSession() throws {
    let id = "12345678-1234-1234-1234-123456789abc"
    let now = Date()
    func hook(at url: URL, date: Date, event: String) throws {
      try Paths.directory(url.deletingLastPathComponent())
      var bytes = try JSONSerialization.data(withJSONObject: [
        "logged_at": Events.timestamp(date), "event": ["session_id": id, "hook_event_name": event],
      ])
      bytes.append(10)
      try bytes.write(to: url)
    }
    try hook(
      at: Paths.legacyState.appendingPathComponent("codex.jsonl"),
      date: now.addingTimeInterval(-10), event: "Stop")
    try hook(
      at: Paths.support.appendingPathComponent("events/codex.jsonl"), date: now,
      event: "UserPromptSubmit")
    XCTAssertEqual(Monitor().sessions().first?.mode, .working)
    try hook(
      at: Paths.legacyState.appendingPathComponent("codex.jsonl"), date: now.addingTimeInterval(1),
      event: "Stop")
    XCTAssertEqual(Monitor().sessions().first?.mode, .done)
    let directory = Paths.home.appendingPathComponent(".codex/sessions")
    try Paths.directory(directory)
    try Settings.update { $0["transcript_monitoring"] = ["codex": true] }
    for offset in [-20.0, 20.0] {
      for (index, event) in ["task_started", "task_complete"].enumerated() {
        let name = index == 0 ? id : "12345678-1234-1234-1234-123456789abd"
        let row: JSONObject = [
          "timestamp": Events.timestamp(now.addingTimeInterval(offset)), "payload": ["type": event],
        ]
        var bytes = try JSONSerialization.data(withJSONObject: row)
        bytes.append(10)
        try bytes.write(to: directory.appendingPathComponent(name + ".jsonl"))
      }
      let rows = Monitor().sessions()
      XCTAssertEqual(rows.count, 2)
      XCTAssertEqual(rows.first { $0.session == id }?.mode, offset > 0 ? .working : .done)
    }
    let custom = Monitor(logs: [
      "claude": root.appendingPathComponent("a"), "codex": root.appendingPathComponent("b"),
    ])
    XCTAssertEqual(custom.sessions().count, 2)
  }
}

extension MonitorTests {
  func testEventsWithoutToolNamesPreserveKnownThreadAndPermissionIdentity() throws {
    let monitor = Monitor()
    let log = Paths.support.appendingPathComponent("events/codex.jsonl")
    try Events.record(
      provider: "codex",
      raw: [
        "agent_id": "shared", "session_id": "thread", "hook_event_name": "PermissionRequest",
        "tool_input": ["command": "test"],
      ])
    XCTAssertEqual(monitor.sessions().first?.threadID, "thread")
    try Events.record(
      provider: "codex",
      raw: [
        "agent_id": "shared", "hook_event_name": "PostToolUse", "tool_input": ["command": "test"],
      ])
    let item = try XCTUnwrap(monitor.sessions().first)
    XCTAssertEqual(item.threadID, "thread")
    XCTAssertEqual(item.mode, .working)
    try Data("invalid".utf8).write(to: Settings.url)
    XCTAssertEqual(monitor.sessions().first?.threadID, "thread")
    XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
  }
}
