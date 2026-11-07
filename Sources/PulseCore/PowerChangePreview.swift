import Foundation

/// Shared timing for the physical, phone, and on-screen battery previews.
public struct PowerChangePreview {
  private var previousPower: Bool?
  private var until = Date.distantPast
  public init() {}
  public mutating func update(battery: Battery?, settings: JSONObject, now: Date) -> Bool {
    if let plugged = battery?.plugged {
      let options = settings["battery_monitoring"] as? JSONObject ?? [:]
      if let previousPower, previousPower != plugged,
        options["show_on_power_change"] as? Bool != false
      {
        until = now.addingTimeInterval(options["power_change_preview_seconds"] as? Double ?? 7)
      }
      previousPower = plugged
    }
    return now < until
  }
}
