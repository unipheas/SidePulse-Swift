import DiskArbitration
import XCTest

@testable import PulseCore

final class CoreCoverageCompletionTests: IsolatedTests {
  func testClassificationConvenienceAPIUsesTheSameParser() async throws {
    let label = try await ReplyClassifier.classify("Approve?") { text in
      XCTAssertEqual(text, "Approve?")
      return " 1. Yes "
    }
    XCTAssertEqual(label, "REPLY_REQUIRED")
    do {
      _ = try await ReplyClassifier.result(" \n")
      XCTFail("Empty input must fail before model generation")
    } catch { XCTAssertEqual(error.localizedDescription, "Enter a message to classify.") }
  }

  func testDefaultClassifyReportsUnavailableModel() async throws {
    guard ReplyClassifier.availableModel() == nil else {
      throw XCTSkip("This check targets a host without the native model")
    }
    do {
      _ = try await ReplyClassifier.classify("Synthetic approval request?")
      XCTFail("An unavailable model must not invent a classification")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Apple Intelligence"))
    }
  }

  func testDefaultResultReportsUnavailableModel() async throws {
    guard ReplyClassifier.availableModel() == nil else {
      throw XCTSkip("This check targets a host without the native model")
    }
    do {
      _ = try await ReplyClassifier.result("Synthetic approval request?")
      XCTFail("An unavailable model must not invent a result")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Apple Intelligence"))
    }
  }

  func testClassifyPropagatesInjectedGeneratorFailure() async throws {
    do {
      _ = try await ReplyClassifier.classify("Synthetic") { _ in throw PulseError("Synthetic failure") }
      XCTFail("Generator failure must propagate")
    } catch { XCTAssertEqual(error.localizedDescription, "Synthetic failure") }
  }

  func testRememberMergesWithAlreadySavedDevicesWithoutOverwritingThem() throws {
    let device = try volume()
    try Settings.update {
      $0["devices"] = [["id": device.id, "name": "Saved name"], ["name": "Missing ID"]]
    }
    let result = try Settings.remember([device], settings: [:])
    let devices = try XCTUnwrap(result["devices"] as? [JSONObject])
    XCTAssertEqual(devices.count, 2)
    XCTAssertEqual(Settings.device(device.id, in: result)["name"] as? String, "Saved name")
    XCTAssertFalse(Machine.name.isEmpty)
  }

  func testBuiltInSDApprovalWorksBeforeDiscovery() throws {
    let session = try XCTUnwrap(DASessionCreate(nil))
    let disk = try XCTUnwrap(DADiskCreateFromBSDName(nil, session, "/dev/disk99999999"))
    let context = GuardContext(session: session)
    let description = [kDADiskDescriptionDeviceProtocolKey as String: "Secure Digital"] as NSDictionary
    let refusal = "disk99999999".withCString { name in
      context.approve(disk, bsdName: { _ in name }, describe: { _ in description as CFDictionary })
    }
    let dissenter = try XCTUnwrap(refusal?.takeRetainedValue())
    XCTAssertEqual(DADissenterGetStatus(dissenter), DAReturn(kDAReturnNotPermitted))
    context.forget("disk99999999")
  }

  func testCommandWrapperReturnsCommandOutputWithoutLaunchdChanges() throws {
    XCTAssertEqual(try Jobs.command("/usr/bin/printf", ["fixture"]), Data("fixture".utf8))
  }
}
