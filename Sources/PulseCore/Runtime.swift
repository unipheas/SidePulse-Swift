import Foundation
import IOKit.pwr_mgt

/// One owner writes changed LED programs, including reconnects.
public final class Output {
  private var sent = [String: String]()
  private var failed = [String: (program: String, retryAfter: Date)]()
  private let now: () -> Date
  private let lidClosed: () -> Bool?
  private var previousPower: Bool?, previousLid: Bool?
  private var previewUntil = Date.distantPast
  private var lidUntil = Date.distantPast
  private var lidState = "lid_open"
  private var lastMode: Mode?
  private var awakeUntil = Date.distantPast
  private var assertion: IOPMAssertionID = 0
  public init(
    now: @escaping () -> Date = Date.init, lidClosed: @escaping () -> Bool? = Power.lidClosed
  ) {
    self.now = now
    self.lidClosed = lidClosed
  }
  deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
  public func reset() {
    sent.removeAll()
    failed.removeAll()
  }
  public func updateAwake(mode: Mode, settings: JSONObject, battery: Battery?) {
    if [.done, .waiting, .blocked].contains(mode), lastMode != mode {
      awakeUntil = now().addingTimeInterval(300)
    }
    if [.working, .tool, .progress].contains(mode) { awakeUntil = .distantPast }
    lastMode = mode
    let minimum =
      (settings["sleep_prevention"] as? JSONObject)?["min_battery_percent"] as? Int ?? 20
    let safeBattery = battery.map { $0.plugged || $0.percent >= minimum } ?? true
    let policy = settings["sleep_prevention_policy"] as? String ?? "agents"
    let enabled = settings["swift_keep_awake"] as? Bool ?? (policy != "never")
    let active =
      policy == "always" || [.working, .tool, .progress].contains(mode) || now() < awakeUntil
    keepAwake(enabled && safeBattery && active)
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
  public func sync(devices: [Device], mode: Mode, settings: JSONObject, battery: Battery?) throws {
    sent = sent.filter { key, _ in devices.contains { $0.id == key } }
    failed = failed.filter { key, _ in devices.contains { $0.id == key } }
    let batterySettings = settings["battery_monitoring"] as? JSONObject ?? [:]
    if let plugged = battery?.plugged {
      if let previousPower, previousPower != plugged,
        batterySettings["show_on_power_change"] as? Bool != false
      {
        previewUntil = now().addingTimeInterval(
          batterySettings["power_change_preview_seconds"] as? Double ?? 7)
      }
      previousPower = plugged
    }
    if let closed = lidClosed() {
      if let previousLid, previousLid != closed {
        lidState = closed ? "lid_closed" : "lid_open"
        let animation = settings[lidState + "_animation"] as? JSONObject
        lidUntil = now().addingTimeInterval(animation?["duration_seconds"] as? Double ?? 1.3)
      }
      previousLid = closed
    }
    var failures = [String]()
    for device in devices {
      let config = (settings["devices"] as? [JSONObject])?.first {
        $0["id"] as? String == device.id
      }
      let display =
        config?["led_display"] as? String ?? settings["led_display"] as? String ?? "agent"
      if display == "custom" {
        sent[device.id] = nil
        continue
      }
      do {
        let source: String
        if now() < lidUntil {
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
        } else if display == "battery" || now() < previewUntil, let battery {
          source = battery.program(
            count: device.count, fullWatts: batterySettings["full_charge_watts"] as? Double ?? PowerRegistry.fullChargeWatts)
        } else {
          source = try Programs.program(mode, count: device.count, settings: settings)
        }
        let program = Programs.brightness(source, level: config?["brightness"] as? Int ?? 255)
        if sent[device.id] != program {
          if let failure = failed[device.id], failure.program == program, now() < failure.retryAfter
          {
            continue
          }
          failed[device.id] = (program, now().addingTimeInterval(10))
          try device.write(program)
          failed[device.id] = nil
          sent[device.id] = program
        }
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
