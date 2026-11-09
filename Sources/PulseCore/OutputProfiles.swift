import Foundation

/// Optional per-output profiles, with the existing global animations as fallback.
/// Dot and Pro selections apply to every device of that model, independent of mount path.
public enum OutputProfiles {
  public static let settingsKey = "output_animation_profiles"

  public enum Target: String, CaseIterable, Identifiable {
    case dot = "Dot"
    case pro = "Pro"
    case notch = "Notch"
    public var id: String { rawValue }
    public var count: Int { self == .dot ? 2 : 8 }
    public var detail: String {
      switch self {
      case .dot: return "Two LEDs · Applies to all Dot devices"
      case .pro: return "Eight LEDs · Applies to all Pro devices"
      case .notch: return "Enable the Notch output in Devices"
      }
    }
  }

  public static func selection(for target: Target, settings: JSONObject) -> String {
    (settings[settingsKey] as? JSONObject)?[target.rawValue] as? String ?? "global"
  }

  /// Assigning an output never applies its profile to the global editor or other outputs.
  public static func select(_ profile: String, for target: Target) throws {
    try Settings.update { settings in
      if profile != "global" { _ = try mapping(profile, settings: settings) }
      var selections = settings[settingsKey] as? JSONObject ?? [:]
      selections[target.rawValue] = profile == "global" ? nil : profile
      settings[settingsKey] = selections
    }
  }

  static func remove(_ profile: String, from settings: inout JSONObject) {
    guard let selections = settings[settingsKey] as? JSONObject else { return }
    settings[settingsKey] = selections.filter { $0.value as? String != profile }
  }

  private static func mapping(_ profile: String, settings: JSONObject) throws -> [String: String] {
    if let mapping = (settings["agent_animation_profiles"] as? [String: JSONObject])?[profile]?[
      "animations"]
      as? [String: String]
    {
      return mapping
    }
    return try Programs.profile(profile)
  }

  private static func override(_ state: String, target: Target, settings: JSONObject) -> String? {
    let profile = selection(for: target, settings: settings)
    guard profile != "global", let map = try? mapping(profile, settings: settings),
      let style = map[state]
    else {
      return nil
    }
    return try? Programs.resolve(style: style, entry: [:], count: target.count, settings: settings)
  }

  public static func program(_ mode: Mode, target: Target, settings: JSONObject) throws -> String {
    if let program = override(mode.rawValue, target: target, settings: settings) { return program }
    return try Programs.program(mode, count: target.count, settings: settings)
  }

  public static func program(_ mode: Mode, device: Device, settings: JSONObject) throws -> String {
    try program(mode, target: device.model == "Dot" ? .dot : .pro, settings: settings)
  }

  static func lidProgram(_ state: String, device: Device, settings: JSONObject) throws -> String {
    if let program = override(
      state, target: device.model == "Dot" ? .dot : .pro, settings: settings)
    {
      return program
    }
    if let saved = (settings[state + "_animation"] as? JSONObject)?["program"] as? String,
      !saved.isEmpty
    {
      return try Programs.normalize(saved)
    }
    let entry = (settings["agent_animations"] as? [String: JSONObject])?[state] ?? [:]
    return try Programs.resolve(
      style: entry["style"] as? String ?? state.replacingOccurrences(of: "_", with: "-"),
      entry: entry, count: device.count, settings: settings)
  }

  public static func notchVisible(mode: Mode, settings: JSONObject) -> Bool {
    settings["notch_attention_only"] as? Bool != true || mode == .waiting || mode == .blocked
  }
}
