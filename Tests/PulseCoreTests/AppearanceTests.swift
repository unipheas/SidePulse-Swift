import Combine
import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class AppearanceTests: IsolatedTests {
  @MainActor func testAppearanceMenuPersistsAndAppliesAllModes() throws {
    let original = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = original }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    XCTAssertEqual(model.appearance, .auto)
    let view = AppearanceMenu().environmentObject(model)
    let picker = try view.inspect().find(ViewType.Picker.self)
    for (choice, name, symbol) in [
      (AppAppearance.light, NSAppearance.Name.aqua, "sun.max"),
      (.dark, .darkAqua, "moon"),
    ] {
      try picker.select(value: choice)
      XCTAssertEqual(model.appearance, choice)
      XCTAssertEqual(try Settings.read()["appearance"] as? String, choice.rawValue)
      XCTAssertEqual(NSApplication.shared.appearance?.name, name)
      XCTAssertEqual(choice.symbol, symbol)
      XCTAssertEqual(choice.id, choice)
      XCTAssertEqual(choice.label, choice.rawValue.capitalized)
      let restored = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
      XCTAssertEqual(restored.appearance, choice)
    }
    try picker.select(value: AppAppearance.auto)
    XCTAssertNil(NSApplication.shared.appearance)
    XCTAssertEqual(AppAppearance.auto.symbol, "circle.lefthalf.filled")
    model.change { $0["appearance"] = "unsupported" }
    XCTAssertEqual(model.appearance, .auto)
    XCTAssertNil(NSApplication.shared.appearance)
  }

  @MainActor func testUnchangedRefreshDoesNotPublishViewState() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    var publications = 0
    let subscription = model.objectWillChange.sink { publications += 1 }
    for _ in 0..<10 { model.refresh() }
    XCTAssertEqual(publications, 0)
    model.change { $0["appearance"] = "auto" }
    XCTAssertEqual(publications, 1)
    withExtendedLifetime(subscription) {}
  }

  @MainActor func testServiceOwnershipCheckYieldsTheMainThread() async throws {
    let model = Dashboard(discover: { [] }, poll: false)
    XCTAssertTrue(model.legacy, "Output stays protected until ownership is known")
    let pending = try XCTUnwrap(model.ownershipTask)
    // A refresh during a pending check must reuse it, not launch another process.
    for _ in 0..<5 { model.refresh() }
    await pending.value
    XCTAssertNil(model.ownershipTask)
  }
}
