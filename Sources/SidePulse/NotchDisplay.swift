import AppKit
import PulseCore
import QuartzCore

/// A click-through LED band at the camera housing, or screen edge on notchless Macs.
@MainActor final class NotchDisplay {
  static let deviceID = "virtual:status-bar"
  private(set) var window: NSPanel?
  private var animationLink: CADisplayLink?
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
    guard settings["virtual_status_device_enabled"] as? Bool == true,
      OutputProfiles.notchVisible(mode: mode, settings: settings)
    else { return nil }
    let config =
      (settings["devices"] as? [JSONObject])?.first { $0["id"] as? String == deviceID } ?? [:]
    let display = config["led_display"] as? String ?? settings["led_display"] as? String ?? "agent"
    guard display != "custom" else { return nil }
    let program: String
    if display == "battery" || previewingBattery, let battery {
      program = battery.program(count: 8, settings: settings)
    } else {
      program = try OutputProfiles.program(mode, target: .notch, settings: settings)
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
    let frame = Self.frame(screen: screen.frame, depth: screen.safeAreaInsets.top, gap: gap)
    if window?.frame != frame { window?.setFrame(frame, display: true) }
    if window?.isVisible != true { window?.orderFrontRegardless() }
    if animationLink == nil {
      let link = lights.displayLink(
        target: lights, selector: #selector(NotchLights.displayFrame(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      link.add(to: .main, forMode: .common)
      animationLink = link
    }
  }
  func hide() {
    animationLink?.invalidate()
    animationLink = nil
    window?.orderOut(nil)
  }
  deinit { animationLink?.invalidate() }
}

@MainActor final class NotchLights: NSView {
  var hasNotch = false {
    didSet { if hasNotch != oldValue { layoutLights() } }
  }
  private var simulator: LEDPreview?
  private var start: CFTimeInterval = 0
  private let gradient = CAGradientLayer()
  private var previousRGB = [UInt8]()

  func load(_ source: String) throws {
    let next = try LEDPreview(program: source, count: 8)
    if layer == nil {
      wantsLayer = true
      layer?.masksToBounds = true
      gradient.startPoint = CGPoint(x: 0, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
      layer?.addSublayer(gradient)
    }
    simulator = next
    start = CACurrentMediaTime()
    previousRGB = []
    layoutLights()
    render(at: start)
  }
  override func layout() {
    super.layout()
    layoutLights()
  }
  private func layoutLights() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.backgroundColor = hasNotch ? NSColor.black.cgColor : NSColor.clear.cgColor
    layer?.cornerRadius = hasNotch ? 8 : 0
    gradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 5)
    CATransaction.commit()
  }
  @objc func displayFrame(_ link: CADisplayLink) {
    render(at: link.targetTimestamp)
  }
  func render(at timestamp: CFTimeInterval) {
    guard let simulator else { return }
    let rgb = simulator.frame(milliseconds: max(0, Int((timestamp - start) * 1000)))
    guard rgb.count == 24, rgb != previousRGB else { return }
    previousRGB = rgb
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let colors: [CGColor] = stride(from: 0, to: rgb.count, by: 3).map { index in
      let red = CGFloat(rgb[index]) / 255
      let green = CGFloat(rgb[index + 1]) / 255
      let blue = CGFloat(rgb[index + 2]) / 255
      return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
    gradient.colors = colors
    CATransaction.commit()
  }
}
