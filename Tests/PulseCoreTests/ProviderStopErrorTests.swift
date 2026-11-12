import XCTest

@testable import PulseCore

final class ProviderStopErrorTests: IsolatedTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func session(_ provider: String, _ event: String, extras: JSONObject = [:]) throws
    -> Session
  {
    var raw: JSONObject = ["hook_event_name": event, "session_id": "fixture"]
    raw.merge(extras) { _, value in value }
    return try XCTUnwrap(
      Events.parse(
        provider: provider,
        row: [
          "logged_at": Events.timestamp(now), "event": raw,
        ]))
  }

  func testClaudeInstallerAddsFailureHookAndPreservesUnrelatedEntries() throws {
    let file = Paths.home.appendingPathComponent(".claude/settings.json")
    let unrelated: JSONObject = [
      "matcher": "*", "hooks": [["type": "command", "command": "echo keep"]],
    ]
    try saveObject(["untouched": 42, "hooks": ["StopFailure": [unrelated]]], to: file)
    let cli = root.appendingPathComponent("tools/sidepulsectl")
    try Hooks.configure("claude", executable: cli, install: true)
    let once = try Data(contentsOf: file)
    let hooks = try XCTUnwrap(try object(file)["hooks"] as? JSONObject)
    let entries = try XCTUnwrap(hooks["StopFailure"] as? [JSONObject])
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(
      (entries.first?["hooks"] as? [JSONObject])?.first?["command"] as? String, "echo keep")
    let command = try XCTUnwrap(
      (entries.last?["hooks"] as? [JSONObject])?.first?["command"] as? String)
    XCTAssertTrue(command.contains(" hook-log --provider claude"))
    XCTAssertTrue(command.hasSuffix(" --event StopFailure # sidepulse-swift"))
    try Hooks.configure("claude", executable: cli, install: true)
    XCTAssertEqual(try Data(contentsOf: file), once)
    try Hooks.configure("claude", executable: cli, install: false)
    let removed = try object(file)
    XCTAssertEqual(removed["untouched"] as? Int, 42)
    let remaining = try XCTUnwrap(
      (removed["hooks"] as? JSONObject)?["StopFailure"] as? [JSONObject])
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(
      (remaining.first?["hooks"] as? [JSONObject])?.first?["command"] as? String, "echo keep")
  }

  func testClaudeFailureErrorsRemainBlockedInsteadOfDoneOrBackgroundWork() throws {
    for error in [
      "rate_limit", "overloaded", "authentication_failed", "billing_error", "server_error",
      "future_error",
    ] {
      let result = try session(
        "claude", "StopFailure",
        extras: [
          "error": error, "last_assistant_message": "You've hit your session limit",
          "background_tasks": [["status": "running"]],
        ])
      XCTAssertEqual(result.event, "StopFailure")
      XCTAssertEqual(result.mode, .blocked, error)
      XCTAssertEqual(Monitor.aggregate([result], settings: [:], now: now), .blocked)
      XCTAssertEqual(
        Monitor.aggregate([result], settings: [:], now: now.addingTimeInterval(1201)), .blocked)
      XCTAssertTrue(Monitor.hasActive([result], settings: [:], now: now))
    }
  }

  func testCursorErrorStopNormalizesIdentityAndFailure() throws {
    let result = try session(
      "cursor", "stop",
      extras: [
        "status": "error", "conversation_id": "cursor-conversation",
        "workspace_roots": ["/fixture/project"],
      ])
    XCTAssertEqual(result.event, "StopFailure")
    XCTAssertEqual(result.mode, .blocked)
    XCTAssertEqual(result.session, "cursor-conversation")
    XCTAssertEqual(result.cwd, "/fixture/project")
    XCTAssertEqual(result.origin, "Cursor")
  }

  func testCursorNonErrorStopsKeepExistingCompletionBehavior() throws {
    for value: Any in [
      "completed", "aborted", "", "unknown", "ERROR", NSNull(), 1, true, ["error"],
    ] {
      let result = try session("cursor", "stop", extras: ["status": value])
      XCTAssertEqual(result.event, "Stop")
      XCTAssertEqual(result.mode, .done, "\(value)")
    }
    XCTAssertEqual(try session("cursor", "stop").mode, .done)
    XCTAssertEqual(
      try session(
        "cursor", "stop",
        extras: ["status": "completed", "last_assistant_message": "Should I proceed?"]
      ).mode, .waiting)
  }

  func testErrorStatusOnlyChangesCursorStopAndPreservesExplicitOverrides() throws {
    for provider in providers where provider != "cursor" {
      XCTAssertEqual(
        try session(provider, "Stop", extras: ["status": "error"]).mode, .done, provider)
    }
    for (event, expected): (String, Mode) in [
      ("beforeSubmitPrompt", .working), ("preToolUse", .tool), ("postToolUse", .working),
      ("postToolUseFailure", .blocked), ("sessionEnd", .done),
    ] {
      XCTAssertEqual(
        try session("cursor", event, extras: ["status": "error"]).mode, expected, event)
    }
    for provider in ["claude", "cursor"] {
      for mode in Mode.allCases {
        XCTAssertEqual(
          try session(
            provider, provider == "cursor" ? "stop" : "StopFailure",
            extras: [
              "status": "error", "sidepulse_status": mode.rawValue,
            ]
          ).mode, mode)
      }
    }
  }

  func testFailureClearsPendingPermissionAndCanResumeInLiveAndReplayedLogs() throws {
    let events = Paths.support.appendingPathComponent("events")
    try Paths.directory(events)
    let monitor = Monitor()
    for provider in ["claude", "cursor"] {
      for (event, extras, expected): (String, JSONObject, Mode) in [
        (
          "PermissionRequest", ["tool_name": "shell", "tool_input": ["command": "fixture"]],
          .waiting
        ),
        (provider == "cursor" ? "stop" : "StopFailure", ["status": "error"], .blocked),
        ("PreToolUse", ["tool_name": "shell", "tool_input": ["command": "fixture"]], .tool),
        ("UserPromptSubmit", [:], .working), ("Stop", ["status": "completed"], .done),
      ] {
        try Events.record(
          provider: provider, raw: extras.merging(["session_id": provider]) { _, new in new },
          named: event)
        let sessions = monitor.sessions()
        XCTAssertEqual(sessions.first { $0.provider == provider }?.mode, expected)
        XCTAssertEqual(
          Monitor().sessions().sorted { $0.id < $1.id }, sessions.sorted { $0.id < $1.id })
      }
    }
  }
}
