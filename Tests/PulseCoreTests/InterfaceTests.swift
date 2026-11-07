import SwiftUI
import XCTest

@testable import PulseCore
@testable import SidePulse

final class InterfaceTests: IsolatedTests {
  @MainActor func testDashboardOwnsOutputHandlesFailuresAndYieldsToService() async throws {
    _ = NSApplication.shared
    try Settings.update { $0["sleep_prevention_policy"] = "never" }
    let device = try volume()
    var service = false
    let dashboard = Dashboard(discover: { [device] }, outputInUse: { service }, poll: false)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: device.root.appendingPathComponent("LEDS.LED").path))
    dashboard.history = Array(repeating: (Date(), .unknown), count: 500)
    dashboard.refresh()
    XCTAssertEqual(dashboard.history.count, 500)
    dashboard.change { $0["swift_phone_mirror"] = true }
    for _ in 0..<5 { await Task.yield() }
    XCTAssertNil(dashboard.problem)
    dashboard.change { $0["swift_phone_mirror"] = false }
    dashboard.change { _ in throw PulseError("Settings are read-only") }
    XCTAssertEqual(dashboard.problem, "Settings are read-only")
    dashboard.problem = nil
    dashboard.setProfile("missing-profile")
    XCTAssertNotNil(dashboard.problem)
    dashboard.problem = nil
    service = true
    for _ in 0..<5 { dashboard.refresh() }
    XCTAssertTrue(dashboard.legacy)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    try Data("invalid JSON".utf8).write(to: Settings.url)
    dashboard.refresh()
    XCTAssertNotNil(dashboard.problem)
    let broken = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    XCTAssertNotNil(broken.problem)
  }
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

extension InterfaceTests {
  @MainActor func testSessionOpeningUsesTheSelectedSurfaceAndReportsFailures() throws {
    let session = Session(
      provider: "codex", session: "fixture", name: "Task", event: "Stop", date: Date(),
      threadID: "id", mode: .done)
    var links = [URL]()
    var commands = [String]()
    let settings: JSONObject = ["session_terminal": ["app": "ghostty"]]
    for target in [session.target(for: .app), session.target(for: .terminal), nil] {
      try SessionOpening.open(
        target, session: session, settings: settings,
        link: {
          links.append($0)
          return true
        },
        terminal: { command, received, item in
          commands.append(command)
          XCTAssertEqual(
            (received["session_terminal"] as? JSONObject)?["app"] as? String, "ghostty")
          XCTAssertEqual(item.session, "fixture")
        })
    }
    XCTAssertEqual(links.map(\.absoluteString), ["codex://threads/id"])
    XCTAssertEqual(commands.count, 1)
    XCTAssertThrowsError(
      try SessionOpening.open(
        session.target(for: .app), session: session, settings: [:], link: { _ in false }))
    XCTAssertThrowsError(
      try SessionOpening.open(
        session.target(for: .terminal), session: session, settings: [:],
        terminal: { _, _, _ in throw PulseError("terminal failed") }))
  }
}
