import XCTest

@testable import PulseCore
@testable import SidePulse

final class DashboardOwnershipTests: IsolatedTests {
  @MainActor func testOwnershipUpdatesBothFlagsFromBackgroundResult() async {
    for (previous, service) in [(false, false), (true, false), (false, true)] {
      let model = Dashboard(discover: { [] }, poll: false, backgroundOwnership: {
        XCTAssertFalse(Thread.isMainThread)
        return (previous, service)
      })
      model.serviceRunning = !service
      model.legacy = !(previous || service)
      await model.ownershipTask?.value
      XCTAssertEqual(model.serviceRunning, service)
      XCTAssertEqual(model.legacy, previous || service)
      XCTAssertNil(model.ownershipTask)
    }
  }

  @MainActor func testBlockedOwnershipDoesNotBlockInitializationOrQueueAnotherCheck() async {
    let gate = DispatchSemaphore(value: 0)
    let started = expectation(description: "ownership query started")
    let model = Dashboard(discover: { [] }, poll: false, backgroundOwnership: {
      started.fulfill()
      _ = gate.wait(timeout: .now() + 5)
      return (false, true)
    })
    XCTAssertNotNil(model.ownershipTask)
    for _ in 0..<10 { model.refresh() }
    await fulfillment(of: [started], timeout: 2)
    gate.signal()
    await model.ownershipTask?.value
    XCTAssertTrue(model.serviceRunning)
    XCTAssertTrue(model.legacy)
    XCTAssertNil(model.ownershipTask)
  }

  @MainActor func testInvalidManualOutputReportsDeviceFailure() throws {
    let device = try volume()
    try Settings.update {
      $0["devices"] = [["id": device.id, "led_display": "custom", "manual_program": String(repeating: "x", count: 513)]]
      $0["swift_keep_awake"] = false
    }
    let model = Dashboard(discover: { [device] }, outputInUse: { false }, poll: false)
    XCTAssertTrue(try XCTUnwrap(model.problem).contains(device.name))
    XCTAssertFalse(FileManager.default.fileExists(atPath: device.root.appendingPathComponent("LEDS.LED").path))
  }
}
