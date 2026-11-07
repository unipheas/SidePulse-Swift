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
      if let change, !["yes", "no"].contains(change) { throw PulseError("Use yes or no.") }
      try Settings.configureBattery(
        display: display, fullWatts: full,
        showOnPowerChange: change.map { $0 == "yes" }, previewSeconds: preview)
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
          try jsonPrint(
            BatteryDiagnostics.read(
              fullWatts: fullWatts ?? (try Settings.read()["battery_monitoring"] as? JSONObject)?[
                "full_charge_watts"] as? Double ?? PowerRegistry.fullChargeWatts)?.values ?? [
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
        as? Double ?? PowerRegistry.fullChargeWatts
      let program = battery.program(count: device.count, fullWatts: baseline)
      if dry { print(program) } else { try device.write(program) }
      if once { return }
      try await Task.sleep(for: .seconds(interval))
    } while !Task.isCancelled
  }
}
