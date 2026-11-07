import JavaScriptCore
import XCTest

@testable import PulseCore
@testable import SidePulse

private final class FailingJavaScript: JSContext {
  override func evaluateScript(_ script: String!) -> JSValue! { nil }
}

final class ResourceBoundaryTests: IsolatedTests {
  func testDiscoveryAndAnimationListingHandleMissingDirectories() throws {
    XCTAssertEqual(Device.discover(in: root.appendingPathComponent("absent")), [])
    let pro = try volume()
    let dot = try volume("Dot")
    XCTAssertEqual(Device.discover(in: root), [dot, pro])
    XCTAssertEqual(Programs.animationNames(in: root.appendingPathComponent("absent")), [])
    XCTAssertEqual(
      try Programs.program(.working, count: 8, settings: [:], defaultProfile: { [:] }),
      try Programs.preset("idle-pulse", count: 8))
    XCTAssertEqual(PowerRegistry.baseline(nil), 100)
  }
  func testSimulatorRejectsMissingEngineAndHandlesFailedFrameEvaluation() throws {
    let module = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    XCTAssertThrowsError(try LEDPreview(program: "off", count: 8, context: nil, module: module))
    XCTAssertThrowsError(
      try LEDPreview(program: "off", count: 8, context: JSContext(), module: nil))
    let invalid = root.appendingPathComponent("invalid.wasm")
    try Data([0]).write(to: invalid)
    XCTAssertThrowsError(
      try LEDPreview(program: "off", count: 8, context: FailingJavaScript(), module: invalid))
    let wasm = try XCTUnwrap(
      Bundle.allBundles.first {
        $0.bundleURL.lastPathComponent == "SidePulseSwift_PulseCore.bundle"
      }?.url(forResource: "sdled", withExtension: "wasm"))
    let context = try XCTUnwrap(JSContext())
    let preview = try LEDPreview(program: "off", count: 8, context: context, module: wasm)
    XCTAssertEqual(preview.frame(milliseconds: 0).count, 24)
    context.evaluateScript("engine = null")
    XCTAssertEqual(preview.frame(milliseconds: 1), [])
  }
  func testUnavailableClassifierAndInjectedModelFailure() async throws {
    XCTAssertNil(ReplyClassifier.availableModel(enabled: false))
    do {
      _ = try await ReplyClassifier.generate("Hello", model: nil)
      XCTFail("Unavailable model must be reported")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Apple Intelligence")) }
    do {
      _ = try await ReplyClassifier.generate(
        "Hello", model: { _ in throw PulseError("Model stopped") })
      XCTFail("Generation failure must propagate")
    } catch { XCTAssertEqual(error.localizedDescription, "Model stopped") }
  }
  @MainActor func testNotchGapHandlesDisplaysWithoutCameraAreas() {
    XCTAssertEqual(NotchDisplay.gap(left: nil, right: nil), 0)
    XCTAssertEqual(
      NotchDisplay.gap(
        left: NSRect(x: 0, y: 0, width: 100, height: 20),
        right: NSRect(x: 200, y: 0, width: 100, height: 20)), 100)
  }
}
