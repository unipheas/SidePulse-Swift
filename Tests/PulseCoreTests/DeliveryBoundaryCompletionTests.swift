import XCTest
@testable import PulseCore
@testable import PulseCLI

final class DeliveryBoundaryCompletionTests: IsolatedTests {
  func testBatteryReadHandlesPresentAndMissingRegistryEntry() throws {
    var names = [String]()
    let battery = try XCTUnwrap(BatteryDiagnostics.read(fullWatts: 96, properties: {
      names.append($0)
      return ["FullyCharged": true]
    }))
    XCTAssertEqual(names, ["AppleSmartBattery"])
    XCTAssertTrue(battery.charged)
    XCTAssertEqual(battery.values["full_charge_watts"] as? Double, 96)
    XCTAssertNil(BatteryDiagnostics.read(fullWatts: 96, properties: { _ in nil }))
  }

  func testDiscoveredDeviceUsesRequestedFileAndReportsWriteFailure() async throws {
    let device = try volume()
    Args.words = ["--file-name", "CUSTOM.LED", "#123456"]
    try await CLI.deliver(preferPhone: false, discover: { [device] })
    let target = device.root.appendingPathComponent("CUSTOM.LED")
    XCTAssertEqual(try String(contentsOf: target), "#123456")
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    Args.words = ["--file-name", "CUSTOM.LED", "#123456"]
    do {
      try await CLI.deliver(preferPhone: false, discover: { [device] })
      XCTFail("Writing to a directory must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.hasPrefix(device.name + ": "))
    }
  }

  func testPhoneDeliveryPassesNotificationAndAggregatesFailure() async throws {
    let token = String(repeating: "a", count: 64)
    try Paths.directory(Paths.support)
    try saveObject(["ios": [["token": token, "name": "Fixture phone"]]], to: Bridge.file)
    var calls = 0
    for fail in [false, true] {
      Args.words = ["--title", "Build", "--message", "Finished"]
      do {
        try await CLI.deliver(preferPhone: true, discover: { [] }, push: { id, program, title, message in
          calls += 1
          XCTAssertEqual(id, String(token.prefix(12)))
          XCTAssertNil(program)
          XCTAssertEqual(title, "Build")
          XCTAssertEqual(message, "Finished")
          if fail { throw PulseError("Fixture unavailable") }
        })
        XCTAssertFalse(fail)
      } catch {
        XCTAssertTrue(fail)
        XCTAssertEqual(error.localizedDescription, "Fixture phone: Fixture unavailable")
      }
    }
    XCTAssertEqual(calls, 2)
  }
}
