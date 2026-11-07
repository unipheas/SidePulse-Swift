import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class LidResetActionTests: IsolatedTests {
  @MainActor func testResetRestoresEachLidStatesPresetAndDuration() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    for (state, duration) in [("lid_open", 1.0), ("lid_closed", 1.3)] {
      try Settings.setLidAnimation(state, program: "#123456", duration: 9)
      model.refresh()
      let view = LidAnimationEditor(state: state).environmentObject(model)
      try view.inspect().find(button: "Reset to default").tap()
      let saved = try XCTUnwrap(try Settings.read()[state + "_animation"] as? JSONObject)
      XCTAssertEqual(saved["duration_seconds"] as? Double, duration)
      XCTAssertEqual(saved["program"] as? String,
        try Programs.preset(state.replacingOccurrences(of: "_", with: "-"), count: 8))
      XCTAssertNil(model.problem)
    }
  }

  @MainActor func testUnknownLidResetReportsFailureWithoutChangingSettings() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let before = try Settings.read()
    let view = LidAnimationEditor(state: "missing-fixture").environmentObject(model)
    try view.inspect().find(button: "Reset to default").tap()
    XCTAssertNotNil(model.problem)
    XCTAssertFalse(try XCTUnwrap(model.problem).isEmpty)
    XCTAssertEqual(try Settings.read() as NSDictionary, before as NSDictionary)
  }
}
