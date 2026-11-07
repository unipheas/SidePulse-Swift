import SwiftUI
import XCTest

@testable import PulseCore
@testable import SidePulse

final class InterfaceTests: IsolatedTests {
  @MainActor func testDashboardReflectsSettingsAndHookTransitionsInHostedScreens() throws {
    _ = NSApplication.shared
    let device = try volume()
    let dashboard = Dashboard(discover: { [device] }, outputInUse: { true }, poll: false)
    XCTAssertEqual(dashboard.mode, .idle)
    try Events.record(provider: "codex", raw: ["session_id": "ui"], named: "UserPromptSubmit")
    dashboard.refresh()
    XCTAssertEqual(dashboard.mode, .working)
    XCTAssertEqual(dashboard.devices, [device])
    XCTAssertTrue(dashboard.legacy)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: device.root.appendingPathComponent("LEDS.LED").path))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled],
      backing: .buffered, defer: false)
    for screen in [
      AnyView(DashboardView()), AnyView(Overview()), AnyView(SessionList()), AnyView(Animations()),
      AnyView(Preferences()), AnyView(DeviceManagement()), AnyView(MenuPanel()),
      AnyView(HistoryView()), AnyView(DiagnosticsView()),
    ] {
      let host = NSHostingView(rootView: screen.environmentObject(dashboard))
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      XCTAssertGreaterThan(bitmap.pixelsWide, 500)
    }
    dashboard.setProfile("ember")
    XCTAssertEqual(dashboard.settings["swift_profile"] as? String, "ember")
    try Events.record(provider: "codex", raw: ["session_id": "ui"], named: "Stop")
    dashboard.refresh()
    XCTAssertEqual(dashboard.mode, .done)
    dashboard.change { $0["agent_list"] = ["completed_visible_seconds": 0] }
    XCTAssertEqual(dashboard.mode, .idle)
    XCTAssertNil(dashboard.problem)
    let transitions = History.recent().map(\.mode).reduce(into: [Mode]()) { result, mode in
      if result.last != mode { result.append(mode) }
    }
    XCTAssertEqual(transitions, [.idle, .working, .done, .idle])
  }
}
