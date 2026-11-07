import Foundation
import IOKit.pwr_mgt

/// One owner writes changed LED programs, including reconnects.
public final class Output {
  private let programs: ProgramOutput
  private let now: () -> Date
  private let lidClosed: () -> Bool?
  private var previousLid: Bool?
  private var powerPreview = PowerChangePreview()
  private var lidUntil = Date.distantPast
  private var lidState = "lid_open"
  private var awakeRequest = AgentAwakeRequest()
  private var holdClosed = false
  private var assertion: IOPMAssertionID = 0
  public init(
    now: @escaping () -> Date = Date.init, lidClosed: @escaping () -> Bool? = Power.lidClosed
  ) {
    self.now = now
    self.programs = ProgramOutput(now: now)
    self.lidClosed = lidClosed
  }
  deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
  public func reset() {
    programs.retain([])
  }
  public func updateAwake(mode: Mode, settings: JSONObject, battery: Battery?) {
    let active = awakeRequest.update(mode: mode, now: now())
    let minimum =
      SleepSettings.minimum(settings)
    let safeBattery = battery.map { $0.plugged || Double($0.percent) >= minimum } ?? true
    let policy = SleepSettings.policy(settings)
    let enabled = settings["swift_keep_awake"] as? Bool ?? (policy != "never")
    keepAwake(enabled && safeBattery && (policy == "always" || active))
  }
  public var isKeepingAwake: Bool { assertion != 0 }
  public func keepAwake(_ active: Bool) {
    if active && assertion == 0 {
      IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "SidePulse is monitoring active work" as CFString, &assertion)
    } else if !active && assertion != 0 {
      IOPMAssertionRelease(assertion)
      assertion = 0
    }
  }
  public func sync(
    devices: [Device], mode: Mode, settings: JSONObject, battery: Battery?,
    agentsActive: Bool? = nil
  ) throws {
    guard settings["swift_mirror"] as? Bool != false else {
      reset()
      return
    }
    programs.retain(devices)
    let previewingBattery = powerPreview.update(battery: battery, settings: settings, now: now())
    let active = agentsActive ?? ![.done, .idle].contains(mode)
    if let closed = lidClosed() {
      if let previousLid, previousLid != closed {
        if !closed || LidAnimationPolicy.shouldClose(settings: settings, agentsActive: active) {
          lidState = closed ? "lid_closed" : "lid_open"
          let animation = settings[lidState + "_animation"] as? JSONObject
          lidUntil = now().addingTimeInterval(
            (animation?["duration_seconds"] as? Double ?? (closed ? 1.3 : 1)) + 0.15)
          holdClosed = LidAnimationPolicy.shouldHold(
            closed: closed, settings: settings, agentsActive: active, battery: battery)
        } else {
          lidUntil = .distantPast
          holdClosed = false
        }
      }
      previousLid = closed
    }
    if holdClosed
      && !LidAnimationPolicy.shouldHold(
        closed: previousLid, settings: settings, agentsActive: active, battery: battery)
    {
      holdClosed = false
    }
    var failures = [String]()
    for device in devices {
      let config = (settings["devices"] as? [JSONObject])?.first {
        $0["id"] as? String == device.id
      }
      let display =
        config?["led_display"] as? String ?? settings["led_display"] as? String ?? "agent"
      if display == "custom", config?["manual_program"] as? String == nil {
        programs.forget(device.id)
        continue
      }
      do {
        let source: String
        if display == "custom", let manual = config?["manual_program"] as? String {
          source = try Programs.normalize(manual)
        } else if now() < lidUntil || holdClosed {
          let entry = (settings["agent_animations"] as? [String: JSONObject])?[lidState] ?? [:]
          if let saved = (settings[lidState + "_animation"] as? JSONObject)?["program"] as? String,
            !saved.isEmpty
          {
            source = try Programs.normalize(saved)
          } else {
            source = try Programs.resolve(
              style: entry["style"] as? String ?? lidState.replacingOccurrences(of: "_", with: "-"),
              entry: entry, count: device.count, settings: settings)
          }
        } else if display == "battery" || previewingBattery, let battery {
          source = battery.program(count: device.count, settings: settings)
        } else {
          source = try Programs.program(mode, count: device.count, settings: settings)
        }
        let program = Programs.brightness(source, level: config?["brightness"] as? Int ?? 255)
        try programs.send(program, to: device)
      } catch { failures.append("\(device.name): \(error.localizedDescription)") }
    }
    if !failures.isEmpty { throw PulseError(failures.joined(separator: "\n")) }
  }
  public static func legacyRunning() -> Bool {
    ["io.sidepulse.agentstatus", "io.sidepulse.service"].contains { label in
      (try? SystemCommand.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"])) != nil
    }
  }
}
