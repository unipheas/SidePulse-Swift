import Foundation

/// Read both the current schema and the preferences saved by earlier companion releases.
public enum SleepSettings {
  public static func policy(_ settings: JSONObject) -> String {
    let choices = ["always", "agents", "never"]
    if let direct = settings["sleep_prevention_policy"] as? String, choices.contains(direct) {
      return direct
    }
    let legacy = [settings["open_lid_awake_policy"], settings["closed_lid_awake_policy"]]
      .compactMap { $0 as? String }
    return choices.first { legacy.contains($0) } ?? "agents"
  }
  public static func closedLid(_ settings: JSONObject) -> String {
    if let direct = settings["swift_closed_lid"] as? String { return direct }
    return settings["closed_lid_system_override_enabled"] as? Bool == true
      ? policy(settings) : "never"
  }
  public static func minimum(_ settings: JSONObject) -> Double {
    let value =
      (settings["sleep_prevention"] as? JSONObject)?["min_battery_percent"]
      ?? settings["sleep_prevention_min_battery_percent"]
    guard let number = value as? NSNumber, number.doubleValue.isFinite else { return 20 }
    return min(100, max(0, number.doubleValue))
  }
}
