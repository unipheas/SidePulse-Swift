import XCTest

@testable import PulseCore

final class ReferenceTests: XCTestCase {
  func testPythonHookOutcomes() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "reference-events", withExtension: "json", subdirectory: "Fixtures"))
    let cases = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [JSONObject])
    XCTAssertGreaterThan(cases.count, 100)
    for sample in cases {
      let row = try XCTUnwrap(sample["event"] as? JSONObject)
      let provider = try XCTUnwrap(sample["provider"] as? String)
      XCTAssertEqual(
        Events.parse(provider: provider, row: row)?.mode.rawValue, sample["mode"] as? String,
        "\(provider) \(row)")
    }
  }
}

extension ReferenceTests {
  func testBatteryLEDsMatchPythonPrograms() throws {
    struct Example: Decodable {
      let count: Int, percent: Int, watts: Int, charging: Bool, plugged: Bool, program: String
    }
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "reference-battery", withExtension: "json", subdirectory: "Fixtures"))
    for example in try JSONDecoder().decode([Example].self, from: Data(contentsOf: url)) {
      let battery = Battery(
        percent: example.percent, charging: example.charging, plugged: example.plugged,
        watts: example.watts)
      XCTAssertEqual(battery.program(count: example.count, fullWatts: 96), example.program)
    }
  }
}
