import AppKit
import PulseCore

/// A click-through LED band at the camera housing, or screen edge on notchless Macs.
@MainActor final class NotchDisplay {
  static let deviceID = "virtual:status-bar"
  private(set) var window: NSPanel?
  private var timer: Timer?
  private var source: String?
  private var powerPreview = PowerChangePreview()
  private let lights = NotchLights(frame: .zero)

  static func frame(screen: NSRect, depth: CGFloat, gap: CGFloat) -> NSRect {
    let width = gap >= 120 ? min(320, max(180, gap)) : 220
    let height = max(0, depth) + 5
    return NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
  }
  static func program(
    settings: JSONObject, mode: Mode, battery: Battery?, previewingBattery: Bool = false
  ) throws -> String? {
    guard settings["virtual_status_device_enabled"] as? Bool == true else { return nil }
    let config =
      (settings["devices"] as? [JSONObject])?.first { $0["id"] as? String == deviceID } ?? [:]
    let display = config["led_display"] as? String ?? settings["led_display"] as? String ?? "agent"
    guard display != "custom" else { return nil }
    let program: String
    if display == "battery" || previewingBattery, let battery {
      program = battery.program(count: 8, settings: settings)
    } else {
      program = try Programs.program(mode, count: 8, settings: settings)
    }
    return Programs.brightness(program, level: config["brightness"] as? Int ?? 255)
  }
  func sync(settings: JSONObject, mode: Mode, battery: Battery?, now: Date = Date()) throws {
    let preview = powerPreview.update(battery: battery, settings: settings, now: now)
    try update(
      Self.program(settings: settings, mode: mode, battery: battery, previewingBattery: preview))
  }
  static func gap(left: NSRect?, right: NSRect?) -> CGFloat {
    (right?.minX ?? 0) - (left?.maxX ?? 0)
  }
  func update(_ program: String?, screen: NSScreen? = .main) throws {
    guard let program, let screen else {
      hide()
      return
    }
    if window == nil {
      let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
      panel.title = "SidePulse Notch"
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.level = .statusBar
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.contentView = lights
      window = panel
    }
    if source != program {
      try lights.load(program)
      source = program
    }
    let gap = Self.gap(left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
    lights.hasNotch = screen.safeAreaInsets.top > 0
    window?.setFrame(
      Self.frame(screen: screen.frame, depth: screen.safeAreaInsets.top, gap: gap), display: true)
    window?.orderFrontRegardless()
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak lights] _ in
        MainActor.assumeIsolated { lights?.needsDisplay = true }
      }
    }
  }
  func hide() {
    timer?.invalidate()
    timer = nil
    window?.orderOut(nil)
  }
  deinit { timer?.invalidate() }
}

@MainActor final class NotchLights: NSView {
  var hasNotch = false
  private var simulator: LEDPreview?
  private var start = Date()
  func load(_ source: String) throws {
    simulator = try LEDPreview(program: source, count: 8)
    start = Date()
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let simulator else { return }
    let rgb = simulator.frame(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
    let colors: [NSColor] = stride(from: 0, to: rgb.count, by: 3).map { index in
      let red = CGFloat(rgb[index]) / 255
      let green = CGFloat(rgb[index + 1]) / 255
      let blue = CGFloat(rgb[index + 2]) / 255
      return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    if hasNotch {
      let body = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
      NSColor.black.setFill()
      body.fill()
      body.addClip()
    }
    NSGradient(colors: colors)?.draw(
      in: NSRect(x: 0, y: 0, width: bounds.width, height: 5), angle: 0)
  }
}
