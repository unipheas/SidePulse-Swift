import XCTest
@testable import PulseCore

final class AppTerminationRaceTests: XCTestCase {
  func testAlreadyTerminatedAppDoesNotReceiveAnotherRequest() {
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: { true }, terminate: {
      XCTFail("An exited application needs no termination request")
      return false
    }, wait: { _ in XCTFail("No wait needed") }))
  }
  func testAcceptedTerminationDoesNotWait() {
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: { false }, terminate: { true },
      wait: { _ in XCTFail("Accepted request preserves existing asynchronous behavior") }))
  }
  func testRejectedRequestSucceedsOnlyWhenApplicationExits() {
    var waits = 0
    var requests = 0
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: { waits >= 3 }, terminate: {
      requests += 1
      return false
    }, wait: { delay in
      XCTAssertEqual(delay, 0.05)
      waits += 1
    }))
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(waits, 3)
  }
  func testPersistentRefusalStillReportsFailureAfterBoundedWait() {
    var waits = 0
    XCTAssertThrowsError(try AppInstallation.stop(terminate: { _ in
      AppInstallation.finishTermination(isTerminated: { false }, terminate: { false },
        wait: { _ in waits += 1 })
    })) {
      XCTAssertEqual($0.localizedDescription, "SidePulse could not quit. Close its windows and try again.")
    }
    XCTAssertEqual(waits, 20)
  }
}
