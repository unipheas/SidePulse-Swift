import XCTest
@testable import PulseCore
@testable import SidePulse

final class DiscoveryResponsivenessTests: IsolatedTests {
  @MainActor func testBlockedDiscoveryDoesNotBlockInitializationOrQueueAnotherScan() async throws {
    let gate = DispatchSemaphore(value: 0)
    let started = expectation(description: "background discovery started")
    let device = try volume()
    let model = Dashboard(backgroundDiscover: {
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill()
      _ = gate.wait(timeout: .now() + 5)
      return [device]
    }, outputInUse: { true }, poll: false)
    XCTAssertTrue(model.devices.isEmpty)
    XCTAssertNotNil(model.discoveryTask)
    for _ in 0..<10 { model.refresh() }
    await fulfillment(of: [started], timeout: 2)
    gate.signal()
    await model.discoveryTask?.value
    XCTAssertEqual(model.devices, [device])
    XCTAssertNil(model.discoveryTask)
    XCTAssertEqual((try Settings.read()["devices"] as? [JSONObject])?.count, 1)
  }

  @MainActor func testBackgroundDiscoveryReportsPersistenceFailure() async throws {
    let device = try volume()
    let model = Dashboard(backgroundDiscover: { [device] }, outputInUse: { true }, poll: false)
    try FileManager.default.removeItem(at: Paths.support)
    try Data("not a directory".utf8).write(to: Paths.support)
    await model.discoveryTask?.value
    XCTAssertEqual(model.devices, [device])
    XCTAssertNotNil(model.problem)
    XCTAssertNil(model.discoveryTask)
  }

  @MainActor func testPendingDiscoveryDoesNotRetainDashboard() async throws {
    let gate = DispatchSemaphore(value: 0)
    let started = expectation(description: "scan started")
    var model: Dashboard? = Dashboard(backgroundDiscover: {
      started.fulfill()
      _ = gate.wait(timeout: .now() + 5)
      return []
    }, outputInUse: { true }, poll: false)
    let task = model?.discoveryTask
    weak var reference = model
    await fulfillment(of: [started], timeout: 2)
    model = nil
    XCTAssertNil(reference)
    gate.signal()
    await task?.value
  }

}
