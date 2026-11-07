import XCTest

@testable import PulseCore

final class TranscriptTests: IsolatedTests {
  let sessionID = "12345678-1234-1234-1234-123456789abc"
  func transcript(_ rows: [JSONObject], at url: URL) throws {
    try Paths.directory(url.deletingLastPathComponent())
    var bytes = Data("malformed row\n{}\n".utf8)
    for var row in rows {
      row["timestamp"] = Date().ISO8601Format()
      bytes.append(try JSONSerialization.data(withJSONObject: row))
      bytes.append(10)
    }
    try bytes.write(to: url)
  }
  func testCodexAndClaudeTranscriptEventsRecoverExpectedStates() throws {
    let url = root.appendingPathComponent(sessionID + ".jsonl")
    let cases: [(JSONObject, Mode)] = [
      (["payload": ["type": "task_started", "cwd": "/tmp"]], .working),
      (
        [
          "payload": ["type": "user_message", "content": [["type": "text", "text": "Build this"]]]
        ], .working
      ),
      (
        ["type": "user", "message": ["content": [["type": "tool_result", "is_error": true]]]],
        .blocked
      ),
      (["payload": ["type": "task_complete", "last_agent_message": "Finished."]], .done),
      (
        ["payload": ["type": "task_completed", "last_agent_message": "Shall I proceed?"]], .waiting
      ),
      (["payload": ["type": "turn_aborted"]], .idle),
      (["payload": ["type": "function_call"]], .tool),
      (["payload": ["type": "custom_tool_call"]], .tool),
      (["payload": ["type": "function_call_output", "output": "ok"]], .working),
      (["payload": ["type": "custom_tool_call_output", "output": "ok"]], .working),
      (["type": "assistant", "message": ["content": [["type": "tool_use"]]]], .tool),
      (["payload": ["type": "message", "role": "user"]], .working),
      (
        [
          "payload": [
            "type": "message", "phase": "final_answer",
            "content": [["type": "text", "text": "Complete."]],
          ]
        ], .done
      ),
      (
        [
          "type": "assistant",
          "message": [
            "stop_reason": "end_turn", "content": [["type": "text", "text": "Complete."]],
          ],
        ], .done
      ),
    ]
    for (row, expected) in cases {
      try transcript([row, ["payload": ["type": "unhandled"]]], at: url)
      let session = try XCTUnwrap(
        TranscriptReader.last(url, provider: "codex", size: Data(contentsOf: url).count))
      XCTAssertEqual(session.mode, expected, String(describing: row))
      XCTAssertTrue(session.id.contains(sessionID))
    }
    XCTAssertNil(
      TranscriptReader.last(
        root.appendingPathComponent("missing.jsonl"), provider: "claude", size: 0))
    let unnamed = root.appendingPathComponent("without-session-id.jsonl")
    try transcript([], at: unnamed)
    XCTAssertNil(TranscriptReader.last(unnamed, provider: "claude", size: 0))
  }
  func testTranscriptCacheRefreshesChangedFilesAndExpiresOldFiles() throws {
    let now = Date()
    let codex = Paths.home.appendingPathComponent(".codex/sessions/" + sessionID + ".jsonl")
    let claude = Paths.home.appendingPathComponent(".claude/projects/" + sessionID + ".jsonl")
    for file in [codex, claude] {
      try transcript(
        [
          [
            "type": "user", "cwd": "/tmp",
            "message": ["content": [["type": "text", "text": "Work"]]],
          ]
        ], at: file)
    }
    let reader = TranscriptReader()
    let enabled: JSONObject = ["transcript_monitoring": ["codex": true, "claude": true]]
    XCTAssertEqual(reader.read(settings: enabled, now: now).count, 2)
    XCTAssertEqual(reader.read(settings: enabled, now: now.addingTimeInterval(6)).count, 2)
    try transcript([["type": "assistant", "message": ["stop_reason": "end_turn"]]], at: claude)
    let refreshed = reader.read(settings: enabled, now: now.addingTimeInterval(12))
    XCTAssertTrue(refreshed.contains { $0.mode == .done })
    XCTAssertEqual(reader.read(settings: enabled, now: now.addingTimeInterval(200000)).count, 0)
    XCTAssertEqual(TranscriptReader().read(settings: [:]).count, 0)
  }
}
