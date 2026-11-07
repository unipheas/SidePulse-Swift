import Foundation
import IOKit.pwr_mgt

/// One owner writes changed LED programs, including reconnects.
public final class Output {
  private var sent = [String: String]()
  private var failed = [String: String]()
  private var assertion: IOPMAssertionID = 0
  public init() {}
  deinit { if assertion != 0 { IOPMAssertionRelease(assertion) } }
  public func reset() {
    sent.removeAll()
    failed.removeAll()
  }
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
        if display == "battery", let battery {
          source = battery.program(count: device.count)
        } else {
          source = try Programs.program(mode, count: device.count, settings: settings)
        }
        let program = Programs.dim(source, brightness: config?["brightness"] as? Int ?? 255)
        if sent[device.id] != program {
          guard failed[device.id] != program else { continue }
          failed[device.id] = program
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
