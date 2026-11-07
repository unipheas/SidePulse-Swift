import XCTest

@testable import PulseCore

final class LaunchTests: IsolatedTests {
  func testLaunchAgentInstallsRestartsAndRemovesItsJob() throws {
    var running = false
    var calls = [[String]]()
    let cli = root.appendingPathComponent("SidePulse.app/Contents/MacOS/sidepulsectl")
    func run(_ tool: String, _ args: [String]) throws -> Data {
      XCTAssertEqual(tool, "/bin/launchctl")
      calls.append(args)
      if args[0] == "print", !running { throw PulseError("not running") }
      if args[0] == "bootstrap" { running = true }
      if args[0] == "bootout" { running = false }
      return Data()
    }
    try Jobs.configure("service", executable: cli, start: true, run: run)
    XCTAssertTrue(running)
    let file = Jobs.plist(Jobs.prefix + "service")
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
        as? JSONObject)
    XCTAssertEqual(plist["ProgramArguments"] as? [String], [cli.path, "service", "run"])
    try Jobs.configure("service", executable: cli, start: true, run: run)
    XCTAssertEqual(calls.filter { $0[0] == "bootout" }.count, 1)
    try Jobs.configure("service", executable: cli, start: false, run: run)
    XCTAssertFalse(running)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertThrowsError(try Jobs.configure("unrecognized", executable: cli, start: true, run: run))
  }

  func testFailedHandoffRestoresAlreadyStoppedJobs() throws {
    let labels = ["io.sidepulse.agentstatus", "io.sidepulse.service"]
    var active = Set(labels)
    var fail = true
    for label in labels { try saveObject([:], to: Jobs.plist(label)) }
    func run(_ tool: String, _ args: [String]) throws -> Data {
      let label = args[1].components(separatedBy: "/").last!
      if args[0] == "print", !active.contains(label) { throw PulseError("not running") }
      if args[0] == "bootout" {
        if label == labels[1] && fail { throw PulseError("bootout failed") }
        active.remove(label)
      }
      if args[0] == "bootstrap" {
        active.insert(URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent)
      }
      return Data()
    }
    XCTAssertThrowsError(try Jobs.takeControl(run: run))
    XCTAssertEqual(active, Set(labels))
    fail = false
    try Jobs.takeControl(run: run)
    XCTAssertTrue(active.isEmpty)
    XCTAssertEqual(try Settings.read()["swift_paused_jobs"] as? [String], labels)
    try Jobs.giveBack(run: run)
    XCTAssertEqual(active, Set(labels))
    XCTAssertNil(try Settings.read()["swift_paused_jobs"])
  }
}

extension LaunchTests {
  func testTerminalLaunchesKeepCommandsInArgumentsAndFallBackSafely() throws {
    let command = "cd '/tmp/a b' && codex resume 'id'"
    for terminal in Terminal.choices {
      var calls = [(String, [String])]()
      try Terminal.open(
        command,
        settings: [
          "session_terminal": ["app": terminal, "custom_path": "/Applications/Custom.app"]
        ],
        run: {
          calls.append(($0, $1))
          return Data()
        })
      XCTAssertEqual(calls.count, 1)
      if terminal == "warp" {
        let file = URL(fileURLWithPath: try XCTUnwrap(calls.first?.1.last))
        XCTAssertEqual(
          try String(contentsOf: file, encoding: .utf8), "#!/bin/zsh\n" + command + "\n")
      } else {
        XCTAssertEqual(calls.first?.1.last, command)
      }
    }
    var attempts = 0
    try Terminal.open(
      command, settings: ["session_terminal": ["app": "ghostty"]],
      run: { tool, args in
        attempts += 1
        if tool == "/usr/bin/open" { throw PulseError("Missing application.") }
        XCTAssertEqual(tool, "/usr/bin/osascript")
        XCTAssertEqual(args.last, command)
        return Data()
      })
    XCTAssertEqual(attempts, 2)
  }
}

extension LaunchTests {
  func testLogTailHandlesEmptyMissingAndOversizedFiles() throws {
    let file = root.appendingPathComponent("service.log")
    XCTAssertEqual(try Jobs.logTail(file, lines: 5), "")
    try Data("first\n\nsecond\nthird\n".utf8).write(to: file)
    XCTAssertEqual(try Jobs.logTail(file, lines: 2), "second\nthird\n")
    XCTAssertEqual(try Jobs.logTail(file, lines: 0), "")
    XCTAssertThrowsError(try Jobs.logTail(file, lines: -1))
    try Data().write(to: file)
    XCTAssertEqual(try Jobs.logTail(file, lines: 10), "")
    try Data((String(repeating: "x", count: 1_048_580) + "\nlast").utf8).write(to: file)
    XCTAssertEqual(try Jobs.logTail(file, lines: 10), "last\n")
  }
}

extension LaunchTests {
  func testResumeFocusesAnExistingTerminalAndMarksNewTabs() throws {
    let session = Session(
      provider: "codex", session: "agent", name: "Task\u{1b} name", event: "Stop",
      date: Date(), threadID: "fixture-id", mode: .done)
    XCTAssertFalse(Terminal.title(for: session).contains("\u{1b}"))
    for app in ["terminal", "iterm", "ghostty"] {
      var calls = [[String]]()
      try Terminal.open(
        "codex resume fixture-id", settings: ["session_terminal": ["app": app]], session: session,
        run: { _, arguments in
          calls.append(arguments)
          return Data("1\n".utf8)
        })
      XCTAssertEqual(calls.count, 1)
      XCTAssertEqual(calls[0].suffix(2).first, "fixture-id")
      XCTAssertTrue(calls[0][1].contains("repeat with marker in argv"))
    }
    var calls = [[String]]()
    try Terminal.open(
      "codex resume fixture-id", settings: [:], session: session,
      run: { _, arguments in
        calls.append(arguments)
        if calls.count == 1 { throw PulseError("Automation unavailable") }
        return Data()
      })
    XCTAssertEqual(calls.count, 2)
    XCTAssertTrue(calls.last!.last!.hasPrefix("printf '\\033]0;%s\\007' 'SidePulse"))
    XCTAssertTrue(calls.last!.last!.hasSuffix("; codex resume fixture-id"))
    XCTAssertFalse(
      Terminal.focus(
        session, app: "unknown",
        run: { _, _ in
          XCTFail()
          return Data()
        }))
    var noID = session
    noID.threadID = nil
    XCTAssertFalse(
      Terminal.focus(
        noID, app: "Terminal",
        run: { _, _ in
          XCTFail()
          return Data()
        }))
    XCTAssertFalse(Terminal.focus(session, app: "Terminal", run: { _, _ in Data("0".utf8) }))
  }
}
