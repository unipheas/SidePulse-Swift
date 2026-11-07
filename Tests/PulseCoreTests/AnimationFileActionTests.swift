import AppKit
import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class AnimationFileActionTests: IsolatedTests {
  @MainActor func testImportFailureIsReportedWithoutChangingSettings() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let before = try Settings.read()
    let file = root.appendingPathComponent("invalid.json")
    try Data("not JSON".utf8).write(to: file)
    let view = Animations(selectImportURL: { panel in
      XCTAssertEqual(panel.allowedContentTypes, [.json])
      return file
    }).environmentObject(model)
    try view.inspect().find(button: "Import…").tap()
    XCTAssertFalse(try XCTUnwrap(model.problem).isEmpty)
    XCTAssertEqual(try Settings.read() as NSDictionary, before as NSDictionary)
  }

  @MainActor func testExportFailureIsReportedAndCancellationDoesNothing() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let view = Animations(selectExportURL: { panel in
      XCTAssertEqual(panel.nameFieldStringValue, "SidePulse Profile.json")
      return self.root
    }).environmentObject(model)
    try view.inspect().find(button: "Export…").tap()
    XCTAssertFalse(try XCTUnwrap(model.problem).isEmpty)
    model.problem = nil
    let cancelled = Animations(selectImportURL: { _ in nil }, selectExportURL: { _ in nil })
      .environmentObject(model)
    try cancelled.inspect().find(button: "Import…").tap()
    try cancelled.inspect().find(button: "Export…").tap()
    XCTAssertNil(model.problem)
  }

  @MainActor func testInvalidDoneDurationReportsValidationAndPreservesSettings() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let before = try Settings.read()
    let view = Preferences(seconds: "-1").environmentObject(model)
    try view.inspect().find(button: "Apply").tap()
    XCTAssertEqual(model.problem, "Enter a finite duration of zero seconds or more.")
    XCTAssertEqual(try Settings.read() as NSDictionary, before as NSDictionary)
  }
}
