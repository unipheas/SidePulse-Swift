import Foundation

extension History {
  static var importedFile: URL { Paths.support.appendingPathComponent("history-imported.jsonl") }

  /// Keep imported history separate from the rotating live log, and migrate it only once.
  public static func importLegacy() throws {
    try withLock(Paths.support.appendingPathComponent("history.lock")) {
      let source = Paths.legacyState.appendingPathComponent("status-history.jsonl")
      guard !FileManager.default.fileExists(atPath: importedFile.path),
        FileManager.default.fileExists(atPath: source.path)
      else { return }
      let data = try Data(contentsOf: source, options: .mappedIfSafe)
      var output = Data()
      for line in data.split(separator: 10) {
        guard let row = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject,
          let date = Events.date(row["recorded_at"]),
          let rawMode = row["agent_status"] as? String, let mode = Mode(rawValue: rawMode)
        else { continue }
        let change = Change(
          date: date, mode: mode, battery: row["battery_level"] as? Int,
          charging: row["battery_charging"] as? Bool,
          chargerWatts: row["charger_power_watts"] as? Double,
          batteryWatts: row["battery_power_watts"] as? Double,
          keepingAwake: row["sidepulse_keep_awake_active"] as? Bool,
          power: PowerSnapshot(
            lidClosed: row["lid_closed"] as? Bool,
            sleepDisabled: row["mac_sleep_disabled"] as? Bool,
            preventsSystemSleep: row["mac_prevent_system_sleep"] as? Bool,
            preventsIdleSleep: row["mac_prevent_user_idle_system_sleep"] as? Bool,
            preventsDisplaySleep: row["mac_prevent_user_idle_display_sleep"] as? Bool,
            userActive: row["mac_user_is_active"] as? Bool))
        output.append(try JSONEncoder().encode(change))
        output.append(10)
      }
      try output.write(to: importedFile, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: importedFile.path)
    }
  }
}
