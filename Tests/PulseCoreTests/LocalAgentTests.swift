import Darwin
import XCTest

@testable import PulseCLI
@testable import PulseCore

final class LocalAgentTests: IsolatedTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @discardableResult
  func event(
    _ state: Mode = .working, source: String = "ollama", run: String = "run-one",
    sequence: UInt64 = 1, at: Date? = nil, lease: Double = 60
  ) throws -> Bool {
    try LocalAgentEvents.record(
      source: source, run: run, state: state, sequence: sequence,
      startedAt: min(now, at ?? now), leaseSeconds: lease, now: at ?? now)
  }
  func mode(at: Date? = nil) -> Mode {
    let date = at ?? now
    return Monitor.aggregate(LocalAgentEvents.sessions(now: date), settings: [:], now: date)
  }

  func testOnlyMinimalMetadataIsSavedWithPrivatePermissions() throws {
    XCTAssertTrue(try event())
    let file = LocalAgentEvents.file(source: "ollama", run: "run-one")
    let object = try object(file)
    XCTAssertEqual(Set(object.keys), [
      "version", "source", "run", "sequence", "state", "startedAt", "updatedAt", "leaseSeconds",
    ])
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let session = try XCTUnwrap(LocalAgentEvents.sessions(now: now).first)
    XCTAssertEqual(session.provider, "local")
    XCTAssertEqual(session.id, "local:ollama:run-one")
    XCTAssertNil(session.cwd)
    XCTAssertNil(session.threadID)
    XCTAssertEqual(session.name, "ollama")
  }

  func testOverlapAndSourceNamespacingPreserveOtherWork() throws {
    try event()
    try event(source: "nova", run: "run-one")
    try event(run: "run-two")
    XCTAssertEqual(LocalAgentEvents.sessions(now: now).count, 3)
    try event(.done, sequence: 2)
    XCTAssertEqual(mode(), .working)
    try event(.waiting, source: "nova", sequence: 2)
    XCTAssertEqual(mode(), .waiting)
    try event(.blocked, run: "run-two", sequence: 2)
    XCTAssertEqual(mode(), .blocked)
    try event(.idle, run: "run-two", sequence: 3)
    XCTAssertEqual(mode(), .waiting)
    try event(.working, source: "nova", sequence: 3)
    XCTAssertEqual(mode(), .working)
    try event(.done, source: "nova", sequence: 4)
    XCTAssertEqual(mode(), .done)
  }

  func testSequencesRejectDuplicatesLateEventsAndTerminalResurrection() throws {
    try event(sequence: 10)
    XCTAssertFalse(try event(.waiting, sequence: 9, at: now.addingTimeInterval(1)))
    XCTAssertFalse(try event(.blocked, sequence: 10, at: now.addingTimeInterval(2)))
    XCTAssertThrowsError(try event(.blocked, sequence: 11, at: now.addingTimeInterval(-1)))
    XCTAssertEqual(mode(), .working)
    XCTAssertTrue(try event(.done, sequence: 12))
    XCTAssertFalse(try event(.working, sequence: 13))
    XCTAssertEqual(mode(), .done)
    XCTAssertTrue(try event(run: "fresh-run"))
    XCTAssertEqual(mode(), .working)
  }

  func testExpiredHeartbeatBecomesUnknownNotSuccessAndCanRecover() throws {
    try event(lease: 5)
    let expired = now.addingTimeInterval(5)
    XCTAssertEqual(mode(at: now.addingTimeInterval(4)), .working)
    XCTAssertEqual(mode(at: expired), .unknown)
    let snapshot = try XCTUnwrap(LocalAgentEvents.sessions(now: now).first)
    XCTAssertEqual(Monitor.aggregate([snapshot], settings: [:], now: expired), .unknown)
    try event(sequence: 2, at: expired, lease: 5)
    XCTAssertEqual(mode(at: expired), .working)
    XCTAssertEqual(mode(at: expired.addingTimeInterval(5)), .unknown)
    try event(.done, sequence: 3, at: expired.addingTimeInterval(6))
    XCTAssertEqual(mode(at: expired.addingTimeInterval(6)), .done)
  }

  func testAttentionLatchesUntilExplicitResumeOrAcknowledgement() throws {
    try event(.waiting, lease: 5)
    XCTAssertEqual(mode(at: now.addingTimeInterval(4000)), .waiting)
    try event(.blocked, sequence: 2, lease: 5)
    XCTAssertEqual(mode(at: now.addingTimeInterval(4000)), .blocked)
    try event(.working, sequence: 3)
    XCTAssertEqual(mode(), .working)
    try event(.idle, sequence: 4)
    XCTAssertEqual(mode(), .idle)
    XCTAssertFalse(try event(.waiting, sequence: 5))
  }

  func testDoneHoldAndRetentionDoNotEraseOrderingTombstone() throws {
    try event(.done)
    let sessions = LocalAgentEvents.sessions(now: now)
    let settings: JSONObject = ["agent_list": ["completed_visible_seconds": 15]]
    XCTAssertEqual(Monitor.aggregate(sessions, settings: settings, now: now.addingTimeInterval(14)), .done)
    XCTAssertEqual(Monitor.aggregate(sessions, settings: settings, now: now.addingTimeInterval(15)), .idle)
    XCTAssertEqual(Monitor.aggregate(sessions, settings: settings, now: now.addingTimeInterval(86400)), .idle)
    XCTAssertTrue(LocalAgentEvents.sessions(now: now.addingTimeInterval(86400)).isEmpty)
    XCTAssertFalse(try event(sequence: 2, at: now.addingTimeInterval(86401)))
    try event(.unknown, run: "uncertain")
    XCTAssertEqual(mode(at: now.addingTimeInterval(86399)), .unknown)
    XCTAssertEqual(mode(at: now.addingTimeInterval(86400)), .idle)
  }

  func testUnknownOutranksIdleAndDoneButNotKnownActiveOrAttention() throws {
    try event(.unknown)
    try event(.idle, run: "idle")
    try event(.done, run: "done")
    XCTAssertEqual(mode(), .unknown)
    try event(run: "active")
    XCTAssertEqual(mode(), .working)
    try event(.waiting, run: "attention")
    XCTAssertEqual(mode(), .waiting)
  }

  func testInvalidArgumentsCannotCreateSnapshots() throws {
    for source in ["", "has space", "../escape", "non-ascii-é", String(repeating: "a", count: 49)] {
      XCTAssertThrowsError(try event(source: source))
    }
    for run in ["", "../run", String(repeating: "a", count: 129)] {
      XCTAssertThrowsError(try event(run: run))
    }
    for lease in [4, 3601, Double.nan, Double.infinity] {
      XCTAssertThrowsError(try event(lease: lease))
    }
    XCTAssertThrowsError(try event(sequence: 0))
    XCTAssertThrowsError(try event(at: Date(timeIntervalSince1970: .nan)))
    XCTAssertTrue(LocalAgentEvents.sessions(now: now).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: LocalAgentEvents.directory.path))
  }

  func testReaderRejectsCorruptFutureSymlinkAndNonregularSnapshots() throws {
    XCTAssertTrue(LocalAgentEvents.sessions(now: now).isEmpty)
    try event()
    let file = LocalAgentEvents.file(source: "ollama", run: "run-one")
    let original = try Data(contentsOf: file)
    try Data("bad".utf8).write(to: file)
    XCTAssertThrowsError(try event(sequence: 2))
    XCTAssertTrue(LocalAgentEvents.sessions(now: now).isEmpty)
    try original.write(to: file)
    XCTAssertTrue(LocalAgentEvents.sessions(now: now.addingTimeInterval(-10)).isEmpty)
    let wrong = LocalAgentEvents.directory.appendingPathComponent("wrong.json")
    try original.write(to: wrong)
    XCTAssertEqual(LocalAgentEvents.sessions(now: now).count, 1)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: wrong)
    XCTAssertThrowsError(try event(sequence: 2))
    XCTAssertTrue(LocalAgentEvents.sessions(now: now).isEmpty)
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(mkfifo(file.path, 0o600), 0)
    XCTAssertTrue(LocalAgentEvents.sessions(now: now).isEmpty)
    try FileManager.default.removeItem(at: file)
    try Data(repeating: 65, count: 8193).write(to: file)
    XCTAssertTrue(LocalAgentEvents.sessions(now: now).isEmpty)
  }

  func testConcurrentWritersKeepHighestSequenceAndDistinctRuns() throws {
    let errors = NSLock()
    var failures = [Error]()
    DispatchQueue.concurrentPerform(iterations: 32) { index in
      do {
        try event(sequence: UInt64(index + 1))
        try event(source: "other", run: "run-\(index)")
      } catch {
        errors.lock(); failures.append(error); errors.unlock()
      }
    }
    XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(LocalAgentEvents.sessions(now: now).count, 33)
    let record = try object(LocalAgentEvents.file(source: "ollama", run: "run-one"))
    XCTAssertEqual(record["sequence"] as? Int, 32)
  }

  func testCapacityPruningAndImmutableStartPreventExpiredReplay() throws {
    func record(_ run: String, at: Date, start: Date, sequence: UInt64 = 1, state: Mode = .working) throws -> Bool {
      try LocalAgentEvents.record(.init(version: 1, source: "nova", run: run,
        sequence: sequence, state: state, startedAt: start, updatedAt: at, leaseSeconds: 60), capacity: 2)
    }
    XCTAssertTrue(try record("old", at: now, start: now, state: .done))
    XCTAssertTrue(try record("ongoing", at: now, start: now))
    XCTAssertThrowsError(try record("overflow", at: now, start: now))
    let later = now.addingTimeInterval(86401)
    XCTAssertTrue(try record("ongoing", at: later, start: now, sequence: 2))
    XCTAssertTrue(try record("fresh", at: later, start: later))
    XCTAssertFalse(FileManager.default.fileExists(atPath: LocalAgentEvents.file(source: "nova", run: "old").path))
    XCTAssertThrowsError(try record("old", at: later, start: now, sequence: 2))
    XCTAssertThrowsError(try record("ongoing", at: later, start: later, sequence: 3))
    XCTAssertEqual(LocalAgentEvents.sessions(now: later).count, 2)
  }

  func testCachedReaderRefreshesUpdatesRemovalAndLeaseWithoutFileChanges() throws {
    let reader = LocalAgentEvents.Reader()
    XCTAssertTrue(reader.sessions(now: now).isEmpty)
    try event(lease: 5)
    XCTAssertEqual(reader.sessions(now: now).first?.mode, .working)
    XCTAssertEqual(reader.sessions(now: now.addingTimeInterval(5)).first?.mode, .unknown)
    try event(.waiting, sequence: 2)
    XCTAssertEqual(reader.sessions(now: now).first?.mode, .waiting)
    let file = LocalAgentEvents.file(source: "ollama", run: "run-one")
    try Data("corrupt".utf8).write(to: file)
    XCTAssertTrue(reader.sessions(now: now).isEmpty)
    try FileManager.default.removeItem(at: file)
    try event(.blocked, run: "second")
    XCTAssertEqual(reader.sessions(now: now).count, 1)
    try FileManager.default.removeItem(at: LocalAgentEvents.directory)
    XCTAssertTrue(reader.sessions(now: now).isEmpty)
  }

  func testMixedProviderUnknownDoesNotHideUsefulActivity() throws {
    try event(.unknown)
    let local = LocalAgentEvents.sessions(now: now)
    func codex(_ mode: Mode) -> Session {
      Session(provider: "codex", session: "code", name: "Code", event: "fixture", date: now, mode: mode)
    }
    XCTAssertEqual(Monitor.aggregate(local + [codex(.idle)], settings: [:], now: now), .unknown)
    XCTAssertEqual(Monitor.aggregate(local + [codex(.done)], settings: [:], now: now), .unknown)
    XCTAssertEqual(Monitor.aggregate(local + [codex(.working)], settings: [:], now: now), .working)
    XCTAssertEqual(Monitor.aggregate(local + [codex(.waiting)], settings: [:], now: now), .waiting)
  }

  func testReadHandlesUnexpectedErrnoAndConcurrentTruncation() throws {
    try event()
    let file = LocalAgentEvents.file(source: "ollama", run: "run-one")
    let savedErrno = errno
    defer { errno = savedErrno }
    XCTAssertThrowsError(try LocalAgentEvents.read(file, openFile: { _, _ in errno = 123456; return -1 }))
    XCTAssertThrowsError(try LocalAgentEvents.read(file, readBytes: { _, _ in nil }))
    XCTAssertEqual(try LocalAgentEvents.read(file).state, .working)
  }

  func testWriteFailuresPreservePreviousSnapshotAndRemoveTemporaryFiles() throws {
    try event()
    let file = LocalAgentEvents.file(source: "ollama", run: "run-one")
    let original = try Data(contentsOf: file)
    let changed = LocalAgentEvents.Record(version: 1, source: "ollama", run: "run-one",
      sequence: 2, state: .done, startedAt: now, updatedAt: now, leaseSeconds: 60)
    XCTAssertThrowsError(try LocalAgentEvents.write(changed, to: file, create: { _, _, _ in -1 }))
    XCTAssertThrowsError(try LocalAgentEvents.write(changed, to: file, replace: { _, _ in -1 }))
    XCTAssertEqual(try Data(contentsOf: file), original)
    let contents = try FileManager.default.contentsOfDirectory(atPath: LocalAgentEvents.directory.path)
    XCTAssertFalse(contents.contains { $0.hasSuffix(".tmp") })
    XCTAssertEqual(mode(), .working)
  }

  func testMonitorIncludesLocalRunsWithoutProviderHooks() throws {
    try event(at: Date())
    let sessions = Monitor().sessions()
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.provider, "local")
    XCTAssertFalse(providers.contains("local"))
    XCTAssertNil(sessions.first?.target(for: .app))
    XCTAssertFalse(FileManager.default.fileExists(atPath: Audit.file.path))
  }

  func testLocalEventsAreNeverForwardedByExistingRelay() async throws {
    try RelayConfiguration(
      server: "https://fixture.invalid", receiverChannel: "",
      outboundChannel: "outbound_fixture", machineName: "Fixture"
    ).save()
    var sent = [String]()
    let relay = Relay(send: { _, provider, _, _ in sent.append(provider) }, receive: { _, _ in XCTFail() })
    try event(at: Date())
    let codex = Session(provider: "codex", session: "coding", name: "Coding", event: "Stop", date: Date(), mode: .done)
    try await relay.sync(LocalAgentEvents.sessions() + [codex])
    XCTAssertEqual(sent, ["codex"])
    await relay.stop()
  }

  func testCLIRequiresExplicitSafeFieldsAndRecognizesCommand() async throws {
    let saved = Args.words
    defer { Args.words = saved }
    for words in [
      ["agent-event"],
      ["agent-event", "--source", "x", "--run", "r", "--state", "working", "--sequence", "0"],
      ["agent-event", "--source", "x", "--run", "r", "--state", "bad", "--sequence", "1"],
      ["agent-event", "--source", "x", "--run", "r", "--state", "working", "--sequence", "1", "--prompt", "private"],
    ] {
      Args.words = words
      do { try await CLI.run(); XCTFail("Expected argument rejection") } catch {}
    }
    let started = String(Date().timeIntervalSince1970)
    Args.words = ["agent-event", "--source", "nova", "--run", "cli-run", "--started-at", started, "--state", "working", "--sequence", "1"]
    try await CLI.run()
    XCTAssertEqual(Monitor().sessions().first?.mode, .working)
    Args.words = ["agent-monitor", "agent-event", "--source", "nova", "--run", "cli-run", "--started-at", started, "--state", "completed", "--sequence", "2"]
    try await CLI.run()
    XCTAssertEqual(Monitor().sessions().first?.mode, .done)
  }
}
