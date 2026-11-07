import AppKit
import SwiftUI
import XCTest

@testable import PulseCore
@testable import SidePulse

/// Render empty and incomplete records in a native window using isolated preferences.
final class HostedActionTests: IsolatedTests {
  @MainActor func host<V: View>(_ view: V, model: Dashboard) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 900),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSHostingView(rootView: view.environmentObject(model))
    window.contentView = content
    window.orderFront(nil)
    content.layoutSubtreeIfNeeded()
    return window
  }
  @MainActor func settle() async {
    for _ in 0..<8 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(80))
  }

}

extension HostedActionTests {
  @MainActor func testEmptyAndIncompleteDataRenderAcrossNativeScreens() async throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    model.needsSetup = false
    try FileManager.default.removeItem(at: History.file)
    model.settings = [
      "agent_animation_profiles": ["profile:missing-label": [:]],
      "devices": [["id": "/Volumes/Disconnected"]],
      "swift_paused_jobs": ["io.sidepulse.agentstatus"],
    ]
    for view in [
      AnyView(DashboardView(selection: nil)), AnyView(Overview()), AnyView(HistoryView()),
      AnyView(DeviceManagement()),
      AnyView(Animations()), AnyView(Preferences()),
      AnyView(SettingField(label: "Field", text: .constant("15"))),
      AnyView(
        SessionOpenMenu(
          session: Session(
            provider: "unknown", session: "s", name: "Session", event: "Unknown", date: Date(),
            mode: .unknown)
        ) { Text("No action") }),
    ] {
      let window = host(view, model: model)
      await settle()
      let content = try XCTUnwrap(window.contentView)
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      XCTAssertGreaterThan(bitmap.pixelsWide, 0)
      window.close()
    }
  }
}

extension HostedActionTests {
  @MainActor func testSetupShowsProgressUntilOptionalHelperCompletes() async throws {
    var continuation: CheckedContinuation<String, Error>?
    var actions = MacActions()
    actions.executableExists = { _ in true }
    actions.configureJob = { _, _, _ in }
    actions.jobRunning = { _ in true }
    actions.helper = { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false, actions: actions)
    let setup = Setup()
    setup.installHooks = false
    setup.sleepHelper = true
    let task = Task { await setup.finish(using: model) }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(setup.busy)
    let window = host(SetupView(setup: setup), model: model)
    await settle()
    XCTAssertNotNil(window.contentView)
    continuation?.resume(returning: "installed")
    await task.value
    XCTAssertFalse(setup.busy)
    XCTAssertFalse(model.needsSetup)
    window.close()
  }
}
