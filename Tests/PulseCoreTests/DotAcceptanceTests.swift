import XCTest
@testable import PulseCore

/// Live hardware only: stop all other writers and supply the mounted Dot explicitly.
final class DotAcceptanceTests: XCTestCase {
  func testLiveDotMountedAndSPC2WritesRestoreOriginalProgram() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["SIDEPULSE_DOT_ACCEPTANCE"] == "1",
      let path = environment["SIDEPULSE_DOT_MOUNT"], path.hasPrefix("/Volumes/")
    else { throw XCTSkip("Live Dot acceptance requires explicit opt-in and mount path") }
    let device = try Device.inspect(URL(fileURLWithPath: path))
    guard device.model == "Dot", device.count == 2,
      device.firmware.compare("1.1.0", options: .numeric) != .orderedAscending
    else { throw XCTSkip("Requires a two-LED Dot with SPC2-capable firmware") }
    let file = device.root.appendingPathComponent("LEDS.LED")
    let original = try String(contentsOf: file, encoding: .utf8)
    defer { XCTAssertNoThrow(try device.write(original)) }
    try device.write("#0248FF")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "#0248FF")
    var transport = Device.Transport()
    transport.openFile = { _, _ in errno = EROFS; return -1 }
    // Only the read-only trigger is injected: discovery and SPC2 acknowledgements are real.
    try device.write("#00FF20", transport: transport)
    for profile in ["cyan", "ember", "purple"] {
      for mode in Mode.allCases {
        let program = try Programs.program(mode, count: device.count, settings: [:],
          defaultProfile: { try Programs.profile(profile) })
        try device.write(program, transport: transport)
      }
    }
    for level in [0, 32, 128, 255] {
      try device.write(Programs.brightness("0:#FF0000 1:#0000FF", level: level), transport: transport)
    }
    try device.write(original, transport: transport)
    try device.write(original)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), try Programs.normalize(original))
  }
}
