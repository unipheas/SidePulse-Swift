import AppKit
import QuartzCore
import XCTest

@testable import PulseCore
@testable import SidePulse

final class NotchTests: IsolatedTests {
  @MainActor func testNotchReusesItsLayerAndRendersExactSimulatorColors() throws {
    let view = NotchLights(frame: NSRect(x: 0, y: 0, width: 220, height: 37))
    view.render(at: 0)
    try view.load("#123456")
    let gradient = try XCTUnwrap(view.layer?.sublayers?.first as? CAGradientLayer)
    let colors = try XCTUnwrap(gradient.colors as? [CGColor])
    XCTAssertEqual(colors.count, 8)
    XCTAssertEqual(colors[0].components, [18.0 / 255, 52.0 / 255, 86.0 / 255, 1])
    view.render(at: CACurrentMediaTime() + 1)
    XCTAssertEqual(gradient.colors as? [CGColor], colors)
    view.hasNotch = true
    view.hasNotch = true
    view.layout()
    XCTAssertEqual(view.layer?.cornerRadius, 8)
    XCTAssertEqual(gradient.frame, NSRect(x: 0, y: 0, width: 220, height: 5))
    try view.load("#ABCDEF")
    XCTAssertTrue(view.layer?.sublayers?.first === gradient)
    XCTAssertNotEqual(gradient.colors as? [CGColor], colors)
    view.hasNotch = false
    XCTAssertEqual(view.layer?.cornerRadius, 0)
    XCTAssertThrowsError(try view.load("not an animation"))
    XCTAssertEqual((gradient.colors as? [CGColor])?.count, 8)
  }
  @MainActor func testNotchGeometrySupportsCameraHousingAndExternalScreens() {
    let screen = NSRect(x: 100, y: 200, width: 1600, height: 1000)
    XCTAssertEqual(
      NotchDisplay.frame(screen: screen, depth: 32, gap: 200),
      NSRect(x: 800, y: 1163, width: 200, height: 37))
    XCTAssertEqual(
      NotchDisplay.frame(screen: screen, depth: 0, gap: 0),
      NSRect(x: 790, y: 1195, width: 220, height: 5))
    XCTAssertEqual(NotchDisplay.frame(screen: screen, depth: -1, gap: 500).width, 320)
  }
  @MainActor func testNotchUsesProfilesBatteryBrightnessAndManualVisibility() throws {
    var settings: JSONObject = [:]
    XCTAssertNil(try NotchDisplay.program(settings: settings, mode: .working, battery: nil))
    settings["virtual_status_device_enabled"] = true
    settings["agent_animations"] = ["working": ["style": "custom", "custom_program": "#FF0000"]]
    Settings.editDevice(NotchDisplay.deviceID, in: &settings, values: ["brightness": 128])
    XCTAssertEqual(
      try NotchDisplay.program(settings: settings, mode: .working, battery: nil),
      "brightness 128\n#FF0000")
    Settings.editDevice(NotchDisplay.deviceID, in: &settings, values: ["led_display": "battery"])
    let battery = Battery(percent: 50, charging: false, plugged: false, watts: 0)
    let source = try XCTUnwrap(
      NotchDisplay.program(settings: settings, mode: .working, battery: battery))
    XCTAssertNoThrow(try LEDPreview(program: source, count: 8))
    XCTAssertNotEqual(source, "brightness 128\n#FF0000")
    XCTAssertEqual(
      try NotchDisplay.program(settings: settings, mode: .working, battery: nil),
      "brightness 128\n#FF0000")
    Settings.editDevice(
      NotchDisplay.deviceID, in: &settings, values: ["led_display": "custom", "id": "wrong"])
    XCTAssertEqual(
      Settings.device(NotchDisplay.deviceID, in: settings)["id"] as? String, NotchDisplay.deviceID)
    XCTAssertNil(try NotchDisplay.program(settings: settings, mode: .working, battery: battery))
    XCTAssertEqual((settings["devices"] as? [JSONObject])?.count, 1)
  }
  @MainActor func testNotchWindowIsClickThroughAndHidesWithoutLeavingATimer() throws {
    _ = NSApplication.shared
    let display = NotchDisplay()
    try display.update(nil)
    let screen = try XCTUnwrap(NSScreen.main)
    try display.update("#FF0000", screen: screen)
    let panel = try XCTUnwrap(display.window)
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertEqual(panel.level, .statusBar)
    XCTAssertTrue(panel.isVisible)
    try display.update("#FF0000", screen: screen)
    try display.update("#00FF00", screen: screen)
    XCTAssertTrue(display.window === panel)
    try display.update(nil)
    XCTAssertFalse(panel.isVisible)
    try display.update("#FF0000", screen: nil)
    XCTAssertFalse(panel.isVisible)
    let view = NotchLights(frame: NSRect(x: 0, y: 0, width: 220, height: 37))
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    for notched in [true, false] {
      view.hasNotch = notched
      try view.load("#123456")
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }
  }
}
