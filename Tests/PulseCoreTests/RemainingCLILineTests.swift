import DiskArbitration
import XCTest
@testable import PulseCLI
@testable import PulseCore

final class RemainingCLILineTests: IsolatedTests {
  func testMissingRequiredArgumentHasUsefulError() {
    Args.words = []
    XCTAssertThrowsError(try Args.require("volume")) {
      XCTAssertEqual($0.localizedDescription, "Expected volume.")
    }
  }

  func testRemovingHooksDryRunLeavesSettingsUntouched() throws {
    Args.words = ["all", "--dry-run"]
    try CLI.configure(install: false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.support.path))
  }

  func testBatteryStatusUsesDefaultDiagnosticsWithoutDeviceWrites() async throws {
    Args.words = ["status", "--json", "--full-watts", "60"]
    try await CLI.batteryCommand(read: {
      Battery(percent: 70, charging: false, plugged: false, watts: 0)
    })
  }

  func testRefreshIgnoresVolumeWithoutDiskIdentity() throws {
    let device = try volume()
    let session = try XCTUnwrap(DASessionCreate(nil))
    let context = GuardContext(session: session)
    context.refresh(discover: { [device] })
    let unknown = try XCTUnwrap(DADiskCreateFromBSDName(nil, session, "/dev/disk99999999"))
    XCTAssertNil(context.approve(unknown))
  }
}
