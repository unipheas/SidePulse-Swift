import Foundation

extension Settings {
  public static func configureBattery(
    display: String? = nil, fullWatts: String? = nil, showOnPowerChange: Bool? = nil,
    previewSeconds: String? = nil
  ) throws {
    if let display, !["agent", "battery", "custom"].contains(display) {
      throw PulseError("Use agent, battery or custom display.")
    }
    var baseline: Double?
    if let fullWatts, fullWatts != "auto" {
      guard let value = Double(fullWatts), value.isFinite, value > 0 else {
        throw PulseError("Use positive watts or auto.")
      }
      baseline = value
    }
    var duration: Double?
    if let previewSeconds {
      guard let value = Double(previewSeconds), value.isFinite, value >= 0 else {
        throw PulseError("Enter a finite preview duration of zero or more.")
      }
      duration = value
    }
    try update { settings in
      var battery = settings["battery_monitoring"] as? JSONObject ?? [:]
      if fullWatts != nil { battery["full_charge_watts"] = baseline }
      if let showOnPowerChange { battery["show_on_power_change"] = showOnPowerChange }
      if let duration { battery["power_change_preview_seconds"] = duration }
      if let display { settings["led_display"] = display }
      settings["battery_monitoring"] = battery
    }
  }
}
