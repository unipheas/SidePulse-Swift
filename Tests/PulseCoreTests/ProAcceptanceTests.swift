import XCTest

@testable import PulseCore

/// Explicit opt-in only. Stop other SidePulse writers before running this test.
final class ProAcceptanceTests: XCTestCase {
  func testLiveProReadChannelAcknowledgesProgramAndRestoresLights() throws {
    guard ProcessInfo.processInfo.environment["SIDEPULSE_PRO_ACCEPTANCE"] == "1" else {
      throw XCTSkip("Live Pro acceptance is opt-in")
    }
    let device = try Device.inspect(URL(fileURLWithPath: "/Volumes/SidePulse"))
    XCTAssertEqual(device.model, "Pro")
    let file = device.root.appendingPathComponent("LEDS.LED")
    let original = try String(contentsOf: file, encoding: .utf8)
    defer { XCTAssertNoThrow(try device.write(original)) }
    var transport = Device.Transport()
    transport.openFile = { _, _ in
      errno = EROFS
      return -1
    }
    // The real READ2ME adapter verifies the device's transaction, CRC and byte count.
    try device.write("#0248FF", transport: transport)
    try device.write(original)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      original.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
