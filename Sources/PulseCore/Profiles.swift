import Foundation

public enum Profiles {
  static let states = Mode.allCases.map(\.rawValue) + ["lid_closed", "lid_open"]
  public static func select(_ id: String) throws {
    try Settings.update { settings in
      let saved = settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
      let mapping: [String: String]
      if let stored = saved[id]?["animations"] as? [String: String] {
        mapping = stored
      } else {
        mapping = try Programs.profile(id)
      }
      settings["agent_animations"] = mapping.mapValues { ["style": $0] }
      settings["swift_profile"] = id
    }
  }
  public static func export(to url: URL) throws {
    let settings = try Settings.read()
    let entries = settings["agent_animations"] as? [String: JSONObject] ?? [:]
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
      settings["agent_animations"] = mapping.mapValues { ["style": $0] }
      settings["swift_profile"] = id
    }
  }
}
