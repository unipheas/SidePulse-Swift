import Foundation
import PulseCore

extension CLI {
  static func batteryCommand() async throws {
    let action = Args.pop() ?? "status"
    let full = try Args.option("--full-watts")
    let fullWatts: Double?
    if let full, full != "auto" {
      guard let value = Double(full), value.isFinite, value > 0 else {
        throw PulseError("Use positive watts or auto.")
      }
      fullWatts = value
    } else {
      fullWatts = nil
    }
    if action == "configure" {
      let display = try Args.option("--display")
      let change = try Args.option("--show-on-power-change")
      let preview = try Args.option("--power-change-preview-seconds")
      try Args.end()
      if let display, !["agent", "battery", "custom"].contains(display) {
        throw PulseError("Use agent, battery or custom display.")
      }
      if let change, !["yes", "no"].contains(change) { throw PulseError("Use yes or no.") }
      let seconds = preview.flatMap(Double.init)
      if preview != nil, seconds == nil || seconds!.isFinite == false || seconds! < 0 {
        throw PulseError("Enter a finite preview duration of zero or more.")
      }
      try Settings.update { settings in
        var battery = settings["battery_monitoring"] as? JSONObject ?? [:]
        if full != nil { battery["full_charge_watts"] = fullWatts }
        if let change { battery["show_on_power_change"] = change == "yes" }
        if let seconds { battery["power_change_preview_seconds"] = seconds }
        if let display { settings["led_display"] = display }
        settings["battery_monitoring"] = battery
      }
      return
    }
    let json = Args.flag("--json")
    let dry = Args.flag("--dry-run")
    let once = Args.flag("--once")
    let interval = Double(try Args.option("--interval") ?? "1") ?? -1
    guard interval.isFinite && interval > 0 else {
      throw PulseError("Enter a positive polling interval.")
    }
    let path = try Args.option("--device")
    try Args.end()
    guard ["status", "leds"].contains(action) else {
      throw PulseError("Use battery status, leds or configure.")
    }
    repeat {
      guard let battery = Battery.read() else { throw PulseError("No internal battery found.") }
      if action == "status" {
        if json {
          try jsonPrint([
            "percent": battery.percent, "is_charging": battery.charging,
            "is_plugged": battery.plugged, "adapter_watts": battery.watts,
          ])
        } else {
          print(
            "\(battery.percent)% · \(battery.charging ? "charging" : "on battery or fully charged")"
          )
        }
        return
      }
      let devices =
        try path.map { [try Device.inspect(URL(fileURLWithPath: $0))] } ?? Device.discover()
      let device = try Args.one(devices)
      let settings = try Settings.read()
      let baseline =
        fullWatts ?? (settings["battery_monitoring"] as? JSONObject)?["full_charge_watts"]
        as? Double ?? 100
      let program = battery.program(count: device.count, fullWatts: baseline)
      if dry { print(program) } else { try device.write(program) }
      if once { return }
      try await Task.sleep(for: .seconds(interval))
    } while !Task.isCancelled
  }
}
