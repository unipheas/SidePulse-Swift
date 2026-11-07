import JavaScriptCore
import XCTest

@testable import PulseCore

final class PreviewPerformanceTests: XCTestCase {
  func testRepeatedFrameRenderingHasStableOutputAndReportsCost() throws {
    let preview = try LEDPreview(program: Programs.preset("night-rider", count: 8), count: 8)
    var checksum = 0
    let start = ContinuousClock.now
    for frame in 0..<10_000 {
      let rgb = preview.frame(milliseconds: frame * 16)
      checksum += rgb.reduce(0) { $0 + Int($1) }
    }
    let duration = start.duration(to: .now)
    XCTAssertEqual(checksum, 3_783_819)
    print("LED_FRAME_BENCHMARK: 10000 frames in \(duration); checksum \(checksum)")
  }

  func testDirectFrameCopyMatchesReferenceForBothDevicesAndInitialColors() throws {
    _ = try LEDPreview(program: "off", count: 8)
    let wasm = try XCTUnwrap(
      Bundle.allBundles.first {
        $0.bundleURL.lastPathComponent == "SidePulseSwift_PulseCore.bundle"
      }?.url(forResource: "sdled", withExtension: "wasm"))
    for count in [2, 8] {
      for program in ["#123456", "off", try Programs.preset("night-rider", count: count)] {
        let context = try XCTUnwrap(JSContext())
        let reference = try LEDPreview(
          program: program, count: count,
          initialProgram: "#4488CC", context: context, module: wasm)
        let preview = try LEDPreview(program: program, count: count, initialProgram: "#4488CC")
        for time in [-20, 0, 16, 100, 300, 700, 1200, 2400, 5000] {
          context.setObject(max(0, time), forKeyedSubscript: "now" as NSString)
          let result = context.evaluateScript(
            "engine.sdled_step(ledCount,now); Array.from(new Uint8Array(engine.memory.buffer,engine.sdled_output_ptr(),ledCount*3))"
          )
          let expected = try XCTUnwrap(result?.toArray() as? [NSNumber]).map(\.uint8Value)
          XCTAssertEqual(preview.frame(milliseconds: time), expected, "\(count) LEDs at \(time) ms")
        }
        withExtendedLifetime(reference) {}
      }
    }
  }
}
