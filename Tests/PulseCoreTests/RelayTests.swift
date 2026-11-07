import XCTest

@testable import PulseCore

private actor RelayRecorder {
  var sends = 0, receives = 0, cancellations = 0
  var failSend = false
  func send(_ channel: String, _ provider: String, _ row: JSONObject, _ origin: String) throws {
    XCTAssertEqual(channel, "outbound_fixture")
    XCTAssertEqual(provider, "codex")
    XCTAssertEqual(origin, "https://fixture.invalid")
    XCTAssertNotNil(row["logged_at"])
    if failSend { throw PulseError("offline") }
    sends += 1
  }
  func receive(_ channel: String, _ origin: String) async throws {
    XCTAssertEqual(channel, "receiver_fixture")
    receives += 1
    do { while true { try await Task.sleep(for: .milliseconds(5)) } } catch {
      cancellations += 1
      throw error
    }
  }
  func failure(_ value: Bool) { failSend = value }
  func counts() -> [Int] { [sends, receives, cancellations] }
}
final class RelayTests: IsolatedTests {
  func testRelayDeduplicatesAvoidsLoopsAndRestartsReceiverAfterStop() async throws {
    let recorder = RelayRecorder()
    let relay = Relay(
      send: { try await recorder.send($0, $1, $2, $3) },
      receive: { try await recorder.receive($0, $1) })
    var config = RelayConfiguration(
      server: "https://fixture.invalid", receiverChannel: "receiver_fixture",
      outboundChannel: "outbound_fixture", machineName: "Fixture")
    try config.save()
    func session(_ id: String, date: Date = Date()) throws -> Session {
      try XCTUnwrap(
        Events.parse(
          provider: "codex",
          row: [
            "logged_at": Events.timestamp(date),
            "event": ["session_id": id, "hook_event_name": "UserPromptSubmit"],
          ]))
    }
    let working = try session("one")
    let ignored = try [
      session("relay:remote"), session("old", date: Date().addingTimeInterval(-4000)),
    ]
    try await relay.sync([working] + ignored)
    try await relay.sync([working] + ignored)
    var counts = await recorder.counts()
    XCTAssertEqual(counts[0], 1)
    await relay.stop()
    try await relay.sync([working])
    for _ in 0..<100 {
      counts = await recorder.counts()
      if counts[1] == 2 && counts[2] >= 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(counts[1], 2)
    XCTAssertEqual(counts[2], 1)
    XCTAssertEqual(counts[0], 2)
    await recorder.failure(true)
    let next = try session("two")
    do {
      try await relay.sync([next])
      XCTFail("Expected send error")
    } catch {}
    await recorder.failure(false)
    try await relay.sync([next])
    counts = await recorder.counts()
    XCTAssertEqual(counts[0], 3, "A failed send must remain retryable")
    config.receiverChannel = ""
    config.outboundChannel = ""
    try config.save()
    try await relay.sync([working])
    await relay.stop()
  }
}
