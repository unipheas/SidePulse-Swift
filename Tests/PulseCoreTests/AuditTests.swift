import XCTest

@testable import PulseCore

final class AuditTests: IsolatedTests {
  func testMonitorAuditsEachEventOnceWithTheResultingSessionState() throws {
    try Events.record(
      provider: "claude", raw: ["session_id": "session", "cwd": "/tmp/project"],
      named: "UserPromptSubmit")
    let monitor = Monitor()
    XCTAssertEqual(monitor.sessions().first?.mode, .working)
    _ = Monitor().sessions()
    XCTAssertEqual(Audit.recent().count, 1)
    try Events.record(
      provider: "claude", raw: ["session_id": "session", "last_assistant_message": "Done"],
      named: "Stop")
    _ = monitor.sessions()
    let rows = Audit.recent()
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.last?["status"], "completed")
    XCTAssertEqual(rows.last?["cwd"], "/tmp/project")
    XCTAssertEqual(rows.last?["message"], "Done")
    XCTAssertEqual(rows.last?["session_id"], "session")
    XCTAssertEqual(rows.last?["agent_id"], "claude:session")
    XCTAssertEqual(Audit.recent(limit: 1).count, 1)
    XCTAssertEqual(Audit.recent(limit: 0).count, 0)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: Audit.file.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }
  func testExportsEscapeUntrustedPayloadsAndKeepCSVColumnsIntact() throws {
    XCTAssertTrue(Audit.recent().isEmpty)
    let raw: JSONObject = [
      "timestamp": "2026-01-01T00:00:00Z", "hook_event_name": "Stop",
      "message": "<script>\"hello\", '&'\nworld</script>",
    ]
    try Audit.record(provider: "codex", row: raw, status: nil)
    let csv = root.appendingPathComponent("nested/events.csv")
    let html = root.appendingPathComponent("events.html")
    try Audit.export(to: csv)
    try Audit.export(to: html)
    let markup = try String(contentsOf: html)
    XCTAssertFalse(markup.contains("<script>"))
    XCTAssertTrue(markup.contains("&lt;script&gt;&quot;hello&quot;"))
    XCTAssertTrue(markup.contains("&#39;&amp;&#39;"))
    XCTAssertTrue(try String(contentsOf: csv).contains("\"\"hello\"\","))
    XCTAssertEqual(Audit.recent().first?["status"], "")
    XCTAssertEqual(Audit.preview("  one\n two  ", limit: 20), "one two")
    XCTAssertEqual(Audit.preview(String(repeating: "x", count: 250), limit: 240).count, 240)
    XCTAssertEqual(Audit.preview("abcdef", limit: 2), "...")
  }
  func testMalformedAndRotatedAuditRowsDoNotPreventLogging() throws {
    try Paths.directory(Paths.support)
    var data = Data("broken\n[]\n".utf8)
    data.append(Data(repeating: 32, count: 1_048_576))
    data.append(10)
    try data.write(to: Audit.file)
    try Audit.record(provider: "codex", row: ["timestamp": "test"], status: nil)
    XCTAssertEqual(Audit.recent().count, 1)
    XCTAssertLessThan(try Data(contentsOf: Audit.file).count, 1_048_576)
  }
}
