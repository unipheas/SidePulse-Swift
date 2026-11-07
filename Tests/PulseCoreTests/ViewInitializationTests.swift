import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class ViewInitializationTests: IsolatedTests {
  // Read only the initial backing value, before SwiftUI installs persistent state.
  // This verifies constructor defaults without exposing mutable state in the app API.
  private func initial<T>(_ name: String, in view: Any, as type: T.Type = T.self) throws -> T {
    let value = try XCTUnwrap(Mirror(reflecting: view).children.first { $0.label == name }?.value)
    return try XCTUnwrap(value as? State<T>).wrappedValue
  }

  func testLightBarStartsItsClockAtConstructionAndPreservesPreviewArguments() throws {
    let before = Date()
    let view = LightBar(source: "#123456", count: 2, compact: true, initialProgram: "off")
    let after = Date()
    let start: Date = try initial("_start", in: view)
    XCTAssertGreaterThanOrEqual(start, before)
    XCTAssertLessThanOrEqual(start, after)
    XCTAssertEqual(view.source, "#123456")
    XCTAssertEqual(view.count, 2)
    XCTAssertTrue(view.compact)
    XCTAssertEqual(view.initialProgram, "off")
    let defaults = LightBar(source: "off", count: 8)
    XCTAssertFalse(defaults.compact)
    XCTAssertNil(defaults.initialProgram)
  }

  func testProgramEditorPreservesItsBindingAndCreatesIndependentReplayIdentity() throws {
    var source = "off"
    let binding = Binding(get: { source }, set: { source = $0 })
    let first = ProgramEditor(source: binding, count: 2, initialProgram: "#123456")
    let second = ProgramEditor(source: binding, count: 8)
    let firstID: UUID = try initial("_replay", in: first)
    let secondID: UUID = try initial("_replay", in: second)
    XCTAssertNotEqual(firstID, secondID)
    try first.inspect().find(ViewType.TextEditor.self).setInput("#ABCDEF")
    XCTAssertEqual(source, "#ABCDEF")
    XCTAssertEqual(second.source, "#ABCDEF")
    XCTAssertEqual(first.count, 2)
    XCTAssertEqual(first.initialProgram, "#123456")
    XCTAssertNil(second.initialProgram)
  }

  @MainActor func testLidEditorBeginsExpandedWithUnloadedDraftBeforeAppearance() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    for state in ["lid_open", "lid_closed"] {
      let view = LidAnimationEditor(state: state)
      XCTAssertEqual(view.state, state)
      let rendered = view.environmentObject(model)
      XCTAssertTrue(try rendered.inspect().find(ViewType.DisclosureGroup.self).isExpanded())
      XCTAssertEqual(try rendered.inspect().find(ViewType.TextEditor.self).input(), "")
      XCTAssertEqual(try initial("_duration", in: view, as: Double.self), 1.3)
    }
  }

  @MainActor func testServiceAndTimingDefaultsDoNotInventLoadedState() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let service = BackgroundServicePreference(job: "service", title: "Device output")
    XCTAssertEqual(service.job, "service")
    XCTAssertEqual(service.title, "Device output")
    let serviceView = service.environmentObject(model)
    XCTAssertNoThrow(try serviceView.inspect().find(text: "Stopped"))
    XCTAssertNoThrow(try serviceView.inspect().find(button: "Start"))
    let timing = SessionTimingPreference(key: "idle_timeout_seconds", label: "Idle timeout")
    XCTAssertEqual(timing.key, "idle_timeout_seconds")
    XCTAssertEqual(timing.label, "Idle timeout")
    let timingView = timing.environmentObject(model)
    XCTAssertEqual(try timingView.inspect().find(ViewType.TextField.self).input(), "")
    let settings = try Settings.read()
    try timingView.inspect().find(button: "Apply").tap()
    XCTAssertNotNil(model.problem)
    XCTAssertEqual(try Settings.read() as NSDictionary, settings as NSDictionary)
  }

  @MainActor func testAnimationCardsStartAsPreviewsWithAnEditActionForEveryState() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let view = Animations().environmentObject(model)
    let buttons = try view.inspect().findAll(ViewType.Button.self)
    let edits = buttons.filter { (try? $0.labelView().text().string()) == "Edit" }
    XCTAssertEqual(edits.count, 8)
  }
}
