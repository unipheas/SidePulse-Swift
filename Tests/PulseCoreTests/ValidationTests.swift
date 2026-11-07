import XCTest

@testable import PulseCore

final class ValidationTests: IsolatedTests {
  func testDestinationSelectionRejectsAmbiguityAndRoutesNotifications() throws {
    let pro = try volume()
    let phone = try Phone(
      token: String(repeating: "a", count: 64), name: "Desk phone", server: Bridge.standard)
    func select(
      _ query: String? = nil, all: Bool = false, notification: Bool = false, prefer: Bool = false
    ) throws -> [Destination] {
      try Destination.select(
        devices: [pro], phones: [phone], requested: query, all: all, hasProgram: true,
        notification: notification, preferPhone: prefer)
    }
    XCTAssertEqual(try select().map(\.name), ["Pro"])
    XCTAssertEqual(try select(notification: true).map(\.name), ["Desk phone"])
    XCTAssertEqual(try select(prefer: true).map(\.name), ["Desk phone"])
    XCTAssertEqual(try select("aaaa").map(\.name), ["Desk phone"])
    XCTAssertEqual(try select(all: true).count, 2)
    XCTAssertThrowsError(try select("missing"))
    XCTAssertThrowsError(try select("local", all: true))
    XCTAssertThrowsError(try select("local", notification: true))
    XCTAssertThrowsError(
      try Destination.select(
        devices: [], phones: [], requested: nil, all: true, hasProgram: true, notification: false,
        preferPhone: false))
    XCTAssertThrowsError(
      try Destination.select(
        devices: [pro], phones: [], requested: nil, all: true, hasProgram: true, notification: true,
        preferPhone: false))
  }

  func testStorageRejectsMalformedObjectsAndCommandFailures() throws {
    let file = root.appendingPathComponent("object.json")
    try Data("[]".utf8).write(to: file)
    XCTAssertThrowsError(try object(file))
    try saveObject(["preserve": "value"], to: Settings.url)
    XCTAssertThrowsError(try Settings.update { _ in throw PulseError("cancelled") })
    XCTAssertEqual(try object(Settings.url)["preserve"] as? String, "value")
    for value in [-1.0, Double.infinity, Double.nan] {
      XCTAssertEqual(Settings.seconds(["agent_list": ["x": value]], "x", default: 42), 42)
    }
    XCTAssertEqual(
      String(decoding: try SystemCommand.run("/usr/bin/printf", ["hello"]), as: UTF8.self), "hello")
    XCTAssertThrowsError(try SystemCommand.run("/usr/bin/false", []))
    XCTAssertThrowsError(try SystemCommand.run("/usr/bin/printf", ["too large"], limit: 2))
  }

  func testProgramInputBoundariesAndProfiles() throws {
    for source in ["", "\0", String(repeating: "é", count: 257)] {
      XCTAssertThrowsError(try Programs.normalize(source))
    }
    XCTAssertEqual(try Programs.normalize(" off\r\n"), "off")
    XCTAssertThrowsError(try Programs.preset("../invalid", count: 8))
    XCTAssertThrowsError(try Programs.profile("not-found"))
    XCTAssertEqual(Programs.dim("#FF0000", brightness: -1), "#000000")
    XCTAssertEqual(Programs.dim("#FF0000", brightness: 500), "#FF0000")
    XCTAssertEqual(Programs.brightness("#FF0000", level: 128), "brightness 128\n#FF0000")
    for profile in ["cyan", "ember", "purple"] { try Profiles.select(profile) }
    let dot = try volume("Dot")
    XCTAssertEqual(dot.count, 2)
    try dot.write("off")
    let target = dot.root.appendingPathComponent("LEDS.LED")
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(
      at: target, withDestinationURL: root.appendingPathComponent("victim"))
    XCTAssertThrowsError(try dot.write("off"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("victim").path))
  }

  func testSessionTargetsForAllSupportedProviders() throws {
    for provider in providers {
      let session = try XCTUnwrap(
        Events.parse(
          provider: provider,
          row: [
            "timestamp": "2026-01-01T00:00:00Z", "hook_event_name": "Stop", "session_id": "safe",
          ]))
      XCTAssertEqual(session.target(for: .terminal) != nil, provider != "cursor")
      XCTAssertEqual(session.target(for: .vscode) != nil, provider == "claude")
    }
    let unsafe = try XCTUnwrap(
      Events.parse(
        provider: "codex",
        row: [
          "timestamp": "2026-01-01T00:00:00Z", "hook_event_name": "Stop", "session_id": "--unsafe",
        ]))
    XCTAssertNil(unsafe.target(for: .terminal))
  }
}
