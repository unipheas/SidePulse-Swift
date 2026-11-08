import XCTest

@testable import PulseCore

final class ClaudeBackgroundTaskTests: IsolatedTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let running: [JSONObject] = [["id": "job", "type": "shell", "status": "running"]]

  private func session(
    _ event: String = "Stop", provider: String = "claude", extras: JSONObject = [:]
  ) throws -> Session {
    var raw: JSONObject = ["hook_event_name": event, "session_id": "fixture"]
    raw.merge(extras) { _, new in new }
    return try XCTUnwrap(Events.parse(provider: provider, row: [
      "logged_at": Events.timestamp(now), "event": raw,
    ]))
  }

  func testRunningTasksKeepClaudeStopActiveForEachTaskKind() throws {
    for kind in ["shell", "monitor", "subagent", "future-kind"] {
      let item = try session(extras: ["background_tasks": [
        ["type": "shell", "status": "completed"], ["type": kind, "status": "running"],
      ]])
      XCTAssertEqual(item.mode, .progress, kind)
      XCTAssertTrue(Monitor.hasActive([item], settings: [:], now: now))
    }
  }

  func testMissingMalformedAndFinishedTasksKeepExistingCompletion() throws {
    XCTAssertEqual(try session().mode, .done)
    let values: [Any] = [
      NSNull(), true, "running", ["status": "running"], [],
      [NSNull(), 2, "running", [:], ["status": true], ["status": "Running"],
       ["status": "completed"], ["status": "failed"], ["status": "pending"]],
    ]
    for value in values {
      XCTAssertEqual(try session(extras: ["background_tasks": value]).mode, .done, "\(value)")
    }
    XCTAssertEqual(try session(extras: ["background_tasks": [NSNull(), running[0]]]).mode, .progress)
  }

  func testSubagentStopAndOtherProvidersDoNotAcquireBackgroundHold() throws {
    for provider in providers {
      XCTAssertEqual(try session("SubagentStop", provider: provider,
                                 extras: ["background_tasks": running]).mode, .done)
      if provider != "claude" {
        XCTAssertEqual(try session(provider: provider, extras: ["background_tasks": running]).mode, .done)
      }
    }
    XCTAssertEqual(try session("SessionEnd", extras: ["background_tasks": running]).mode, .done)
  }

  func testQuestionAndExplicitStatesRetainPriorityOverBackgroundWork() throws {
    XCTAssertEqual(try session(extras: ["background_tasks": running,
                                       "last_assistant_message": "Should I proceed?"]).mode, .waiting)
    for mode in Mode.allCases {
      XCTAssertEqual(try session(extras: ["background_tasks": running,
                                         "sidepulse_status": mode.rawValue]).mode, mode)
    }
    XCTAssertEqual(try session(extras: ["background_tasks": running,
      "last_assistant_message": "<!-- sidepulse status: blocked_error -->"]).mode, .blocked)
  }

  private func record(_ event: String, seconds: Double, extras: JSONObject = [:]) throws {
    var raw: JSONObject = ["hook_event_name": event, "session_id": "fixture"]
    raw.merge(extras) { _, new in new }
    let row: JSONObject = ["logged_at": Events.timestamp(now.addingTimeInterval(seconds)), "event": raw]
    let url = Paths.support.appendingPathComponent("events/claude.jsonl")
    try Paths.directory(url.deletingLastPathComponent())
    let data = try JSONSerialization.data(withJSONObject: row) + Data([10])
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  func testIdleRemindersPreserveBackgroundStateAndOriginalStaleDeadline() throws {
    let monitor = Monitor()
    try record("Stop", seconds: 0, extras: ["background_tasks": running])
    let first = try XCTUnwrap(monitor.sessions().first)
    XCTAssertEqual(first.mode, .progress)
    try record("Notification", seconds: 60, extras: ["notification_type": "idle_prompt",
                                                     "message": "Claude is waiting for your input"])
    // The optional message may be absent; the event type still identifies the reminder.
    try record("Notification", seconds: 90, extras: ["notification_type": "idle_prompt"])
    try record("Notification", seconds: 120, extras: ["notification_type": "idle_prompt",
                                                      "message": "Claude is waiting for your input"])
    XCTAssertEqual(monitor.sessions(), [first])
    XCTAssertEqual(Monitor().sessions(), [first], "Fresh log replay must match incremental reads")
    XCTAssertEqual(Monitor.aggregate([first], settings: [:], now: now.addingTimeInterval(3599)), .progress)
    XCTAssertEqual(Monitor.aggregate([first], settings: [:], now: now.addingTimeInterval(3600)), .idle)
    XCTAssertFalse(Monitor.hasActive([first], settings: [:], now: now.addingTimeInterval(3600)))
    var awake = AgentAwakeRequest()
    XCTAssertTrue(awake.update(mode: first.mode, now: now))
    XCTAssertTrue(awake.update(mode: first.mode, now: now.addingTimeInterval(1201)))
  }

  func testRealPermissionAndFailureEventsStillNeedAttention() throws {
    let monitor = Monitor()
    for (event, extras, expected): (String, JSONObject, Mode) in [
      ("PermissionRequest", [:], .waiting),
      ("Notification", ["notification_type": "permission_prompt", "message": "Please approve"], .waiting),
      ("PostToolUseFailure", [:], .blocked),
      ("Stop", ["background_tasks": running, "last_assistant_message": "Should I proceed?"], .waiting),
    ] {
      try record("Stop", seconds: 0, extras: ["background_tasks": running])
      XCTAssertEqual(monitor.sessions().first?.mode, .progress)
      try record(event, seconds: 0, extras: extras)
      XCTAssertEqual(monitor.sessions().first?.mode, expected)
    }
  }

  func testExplicitIdleNotificationOverridesBackgroundHold() throws {
    for extras: JSONObject in [
      ["sidepulse_status": "blocked_error", "message": "waiting for your input"],
      ["last_assistant_message": "<!-- sidepulse status: blocked_error -->"],
    ] {
      try record("Stop", seconds: 0, extras: ["background_tasks": running])
      var notification = extras
      notification["notification_type"] = "idle_prompt"
      try record("Notification", seconds: 0, extras: notification)
      XCTAssertEqual(Monitor().sessions().first?.mode, .blocked)
    }
  }

  func testCompletionAndResumeReleaseBackgroundHold() throws {
    for (event, extras, expected): (String, JSONObject, Mode) in [
      ("Stop", ["background_tasks": [["status": "completed"]]], .done),
      ("SessionEnd", [:], .done), ("Interrupt", [:], .idle),
      ("Notification", ["notification_type": "task_complete", "message": "Task complete"], .done),
      ("UserPromptSubmit", [:], .working), ("PreToolUse", [:], .tool),
    ] {
      try record("Stop", seconds: 0, extras: ["background_tasks": running])
      try record(event, seconds: 0, extras: extras)
      XCTAssertEqual(Monitor().sessions().first?.mode, expected)
    }
  }

  func testIdleReminderDoesNotChangeOtherProgressSourcesOrCompletedBehavior() throws {
    let monitor = Monitor()
    try record("UserPromptSubmit", seconds: 0, extras: ["sidepulse_status": "progress"])
    try record("Notification", seconds: 1, extras: ["notification_type": "idle_prompt",
                                                    "message": "waiting for your input"])
    XCTAssertEqual(monitor.sessions().first?.mode, .waiting)
    try record("Stop", seconds: 2)
    try record("Notification", seconds: 3, extras: ["notification_type": "idle_prompt",
                                                    "message": "waiting for your input"])
    XCTAssertEqual(monitor.sessions().first?.mode, .done)
  }
}
