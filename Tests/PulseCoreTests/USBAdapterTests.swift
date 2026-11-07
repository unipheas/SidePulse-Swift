import USBControl
import USBTestSupport
import XCTest

@testable import PulseCore

final class USBAdapterTests: XCTestCase {
  func testDotAdapterReleasesUSBOnSuccessReadFailureAndReconciledWriteFailure() throws {
    let root = URL(fileURLWithPath: "/tmp")
    for failure: Int32 in [0, 1, 2] {
      let operation = {
        try DotChannel.upload(
          Array("#123456".utf8), root: root, connect: { _ in test_dot_connection(failure) })
      }
      if failure == 1 {
        XCTAssertThrowsError(try operation())
      } else {
        XCTAssertNoThrow(try operation())
      }
      XCTAssertEqual(test_usb_release_count(), 1)
    }
    XCTAssertThrowsError(try DotChannel.upload([1], root: root, connect: { _ in nil }))
  }
  func testRawSizingRejectsCharacterDeviceWithoutDiskGeometry() {
    let fd = open("/dev/null", O_RDONLY)
    defer { close(fd) }
    XCTAssertGreaterThanOrEqual(fd, 0)
    XCTAssertEqual(pulse_raw_size(fd), -1)
  }
  func testUSBDiscoveryAllocationTransferAndReleaseFailures() {
    XCTAssertEqual(test_usb_adapter(), 0)
  }
  func testRawDeviceSizingRejectsUnsafeDevicesAndIOFailures() {
    XCTAssertEqual(test_raw_size_adapter(), 0)
  }
}
