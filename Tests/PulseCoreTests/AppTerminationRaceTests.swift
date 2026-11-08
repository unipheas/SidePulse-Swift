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
  func testDefaultWaitBacksOffBeforeRecheckingRejectedRequest() {
    var checks = 0
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: {
      checks += 1
      return checks >= 3
    }, terminate: { false }))
    XCTAssertEqual(checks, 3)
    XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.04)
  }

  func testLaunchingAppIsReadyBeforeReceivingOneTerminationRequest() {
    var waits = 0
    var requests = 0
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: { false }, terminate: {
      requests += 1
      XCTAssertEqual(waits, 3)
      return true
    }, isReady: { waits >= 3 }, wait: { _ in waits += 1 }))
    XCTAssertEqual(requests, 1)
  }
  func testAppExitingDuringLaunchNeedsNoTerminationRequest() {
    var waits = 0
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: { waits >= 2 }, terminate: {
      XCTFail("Exited app must not receive a request")
      return false
    }, isReady: { false }, wait: { _ in waits += 1 }))
  }
  func testStuckLaunchStillFailsWithoutForcingQuit() {
    var waits = 0
    XCTAssertFalse(AppInstallation.finishTermination(isTerminated: { false }, terminate: {
      XCTFail("Unready app must not receive an ineffective request")
      return false
    }, isReady: { false }, wait: { _ in waits += 1 }))
    XCTAssertEqual(waits, 100)
  }

  @MainActor func testDefaultWaitServicesMainRunLoopStateChanges() {
    var exited = false
    let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in exited = true }
    defer { timer.invalidate() }
    XCTAssertTrue(AppInstallation.finishTermination(isTerminated: { exited }, terminate: { false }))
    XCTAssertTrue(exited)
  }
  @MainActor func testBackgroundCallerCanAdvanceApplicationStateWithoutBlockingMainActor() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        XCTAssertFalse(Thread.isMainThread)
        AppInstallation.waitForApplicationState(0.01)
        continuation.resume()
      }
    }
  }

}
