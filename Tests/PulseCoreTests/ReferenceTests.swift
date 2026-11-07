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

extension ReferenceTests {
  func testPowerDiagnosticsMatchPythonSnapshots() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "reference-power", withExtension: "json", subdirectory: "Fixtures"))
    let cases = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [JSONObject])
    for example in cases {
      let properties = try XCTUnwrap(example["properties"] as? JSONObject)
      let expected = try XCTUnwrap(example["expected"] as? JSONObject)
      let actual = BatteryDiagnostics(properties: properties, fullWatts: 96)
      XCTAssertEqual(actual.values as NSDictionary, expected as NSDictionary, "\(properties)")
    }
  }
  func testChargeBaselineAndFullyChargedAnimation() throws {
    for (model, chip, watts) in [
      ("MacBook Pro (16-inch)", "Apple M4 Max", 140.0),
      ("MacBook Pro (14-inch)", "Apple M4 Pro", 96.0),
      ("MacBook Pro (14-inch)", "Apple M4", 70.0),
      ("MacBook Air", "Apple M4", 100.0), ("MacBook Pro", "Intel", 100.0),
    ] {
      XCTAssertEqual(
        PowerRegistry.baseline([
          "product-name": Data(model.utf8), "product-soc-name": chip,
        ]), watts)
    }
    XCTAssertEqual(PowerRegistry.baseline([:]), 100)
    let charged = Battery(percent: 80, charging: true, plugged: true, watts: 70, charged: true)
    XCTAssertEqual(charged.program(count: 2), "0:#00FF66 360ms ease;1:#00FF66 360ms ease")
    let negotiated = Battery(percent: 50, charging: true, plugged: true, watts: 0, adapterPower: 96)
    let rated = Battery(percent: 50, charging: true, plugged: true, watts: 96)
    XCTAssertEqual(negotiated.program(count: 8), rated.program(count: 8))
    XCTAssertEqual(
      BatteryDiagnostics(properties: [:], fullWatts: .nan).values["full_charge_watts"] as? Double,
      100)
  }
}
