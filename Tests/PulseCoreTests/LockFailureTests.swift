import Darwin
import XCTest
@testable import PulseCore

final class LockFailureTests: IsolatedTests {
  func testOpeningDirectoryAsLockFailsWithoutRunningAction() throws {
    let directory = root.appendingPathComponent("lock-directory")
    try Paths.directory(directory)
    var called = false
    XCTAssertThrowsError(try withLock(directory) { called = true }) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
    }
    XCTAssertFalse(called)
  }

  func testFailedAdvisoryLockDoesNotRunActionAndClosesDescriptor() throws {
    var descriptor: Int32 = -1
    var called = false
    XCTAssertThrowsError(try withLock(root.appendingPathComponent("failure.lock"), lock: { fd, operation in
      descriptor = fd
      XCTAssertEqual(operation, LOCK_EX)
      return -1
    }) { called = true }) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EIO)
    }
    XCTAssertFalse(called)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
    XCTAssertEqual(errno, EBADF)
  }
}
