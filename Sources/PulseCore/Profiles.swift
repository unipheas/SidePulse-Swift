import Foundation

public enum Profiles {
  static let states = Mode.allCases.map(\.rawValue) + ["lid_closed", "lid_open"]
  @discardableResult
  public static func save(name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw PulseError("Enter a profile name.") }
    let id = "profile:" + UUID().uuidString
    try Settings.update { settings in
      var saved = settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
      let entries = animationEntries(settings)
      var mapping = try Programs.profile("cyan")
      var custom = settings["custom_agent_animations"] as? [String: JSONObject] ?? [:]
      for (state, entry) in entries {
        guard let style = entry["style"] as? String else { continue }
        if let inline = entry["custom_program"] as? String {
          let key = "custom:" + UUID().uuidString
          custom[key] = ["name": name + " " + state, "program": try Programs.normalize(inline)]
          mapping[state] = key
        } else {
          mapping[state] = style
        }
      }
      saved[id] = ["name": name, "animations": mapping]
      settings["custom_agent_animations"] = custom
      settings["agent_animation_profiles"] = saved
      settings["swift_profile"] = id
    }
    return id
  }
  public static func delete(_ id: String) throws {
    guard id.hasPrefix("profile:") else { throw PulseError("Choose a saved profile.") }
    try Settings.update { settings in
      var saved = settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
      guard saved.removeValue(forKey: id) != nil else { throw PulseError("Unknown profile.") }
      settings["agent_animation_profiles"] = saved
      if settings["swift_profile"] as? String == id { settings["swift_profile"] = "current" }
    }
  }
  public static func select(_ id: String) throws {
    try Settings.update { settings in
      let saved = settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
      let mapping: [String: String]
      if let stored = saved[id]?["animations"] as? [String: String] {
        mapping = stored
      } else {
        mapping = try Programs.profile(id)
      }
      try apply(mapping, to: &settings)
      settings["swift_profile"] = id
    }
  }
  public static func export(to url: URL) throws {
    let settings = try Settings.read()
    let entries = animationEntries(settings)
    var map = try Programs.profile("cyan")
    var custom = [String: JSONObject]()
    for state in states {
      guard let entry = entries[state], let style = entry["style"] as? String else { continue }
      if style.hasPrefix("custom") {
        let id = style == "custom" ? "custom:" + state : style
        let text = try Programs.resolve(style: style, entry: entry, count: 8, settings: settings)
        custom[id] = ["name": String(id.dropFirst(7)), "program": text]
        map[state] = id
      } else {
        map[state] = style
      }
    }
    try saveObject(
      [
        "format": "sidepulse-animation-profile", "version": 1,
        "name": settings["swift_profile"] as? String ?? "Current", "animations": map,
        "custom_animations": custom,
      ], to: url)
  }
  public static func load(from url: URL) throws {
    let doc = try object(url)
    guard doc["format"] as? String == "sidepulse-animation-profile", doc["version"] as? Int == 1,
      let name = doc["name"] as? String, !name.isEmpty,
      let map = doc["animations"] as? [String: String],
      Set(Mode.allCases.map(\.rawValue)).isSubset(of: Set(map.keys)),
      Set(map.keys).isSubset(of: Set(states))
    else {
      throw PulseError("Invalid SidePulse animation profile.")
    }
    let custom = doc["custom_animations"] as? [String: JSONObject] ?? [:]
    try Settings.update { settings in
      var registry = settings["custom_agent_animations"] as? [String: JSONObject] ?? [:]
      var mapping = map
      for (state, id) in map {
        if id.hasPrefix("custom:") {
          guard let item = custom[id], let source = item["program"] as? String else {
            throw PulseError("Missing custom animation.")
          }
          let text = try Programs.normalize(source)
          let incoming = ["name": item["name"] as? String ?? id, "program": text]
          var key = id
          if registry[key] != nil && registry[key]?["program"] as? String != text {
            key += "-" + UUID().uuidString
          }
          registry[key] = incoming
          mapping[state] = key
        } else {
          _ = try Programs.preset(id, count: 8)
        }
      }
      var saved = settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
      let id = "profile:" + UUID().uuidString
      saved[id] = ["name": name, "animations": mapping]
      settings["custom_agent_animations"] = registry
      settings["agent_animation_profiles"] = saved
      try apply(mapping, to: &settings)
      settings["swift_profile"] = id
    }
  }
  private static func animationEntries(_ settings: JSONObject) -> [String: JSONObject] {
    var entries = settings["agent_animations"] as? [String: JSONObject] ?? [:]
    for state in ["lid_open", "lid_closed"] {
      if let source = (settings[state + "_animation"] as? JSONObject)?["program"] as? String {
        entries[state] = ["style": "custom", "custom_program": source]
      }
    }
    return entries
  }
  private static func apply(_ mapping: [String: String], to settings: inout JSONObject) throws {
    settings["agent_animations"] = mapping.mapValues { ["style": $0] }
    for state in ["lid_open", "lid_closed"] {
      guard let style = mapping[state] else { continue }
      let source = try Programs.resolve(style: style, entry: [:], count: 8, settings: settings)
      var lid =
        settings[state + "_animation"] as? JSONObject ?? [
          "duration_seconds": state == "lid_open" ? 1.0 : 1.3
        ]
      lid["program"] = source
      settings[state + "_animation"] = lid
    }
  }

}
