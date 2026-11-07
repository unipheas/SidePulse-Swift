import Foundation

public struct Change: Codable, Identifiable {
  public let date: Date
  public let mode: Mode
  public let battery: Int?
  public var charging: Bool? = nil
  public var chargerWatts: Double? = nil
  public var batteryWatts: Double? = nil
  public var keepingAwake: Bool? = nil
  public var power: PowerSnapshot? = nil
  public var id: Date { date }
  func sameState(as other: Self) -> Bool {
    mode == other.mode && battery == other.battery && charging == other.charging
      && chargerWatts == other.chargerWatts && batteryWatts == other.batteryWatts
      && keepingAwake == other.keepingAwake && power == other.power
  }
}

public enum History {
  static var file: URL { Paths.support.appendingPathComponent("history.jsonl") }
  public static func recent() -> [Change] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    return data.split(separator: 10).compactMap { try? JSONDecoder().decode(Change.self, from: $0) }
  }
  public static func record(
    _ mode: Mode, battery: Int?, snapshot: Battery? = nil,
    keepingAwake: Bool? = nil, power: PowerSnapshot? = nil
  ) throws {
    try withLock(Paths.support.appendingPathComponent("history.lock")) {
      let entry = Change(
        date: Date(), mode: mode, battery: battery,
        charging: snapshot?.charging,
        chargerWatts: snapshot.map { ($0.adapterPower ?? Double($0.watts)).rounded() },
        batteryWatts: snapshot?.batteryPower.map { $0.rounded() }, keepingAwake: keepingAwake,
        power: power)
      var data = (try? Data(contentsOf: file)) ?? Data()
      if let last = data.split(separator: 10).last,
        (try? JSONDecoder().decode(Change.self, from: last))?.sameState(as: entry) == true
      {
        return
      }
      if data.count >= 262144 {
        data = Data(data.suffix(131072).drop(while: { $0 != 10 }).dropFirst())
      }
      data.append(try JSONEncoder().encode(entry))
      data.append(10)
      try data.write(to: file, options: .atomic)
    }
  }
  public static func export(to url: URL) throws {
    let columns = [
      "time_utc", "state", "battery_percent", "charging", "charger_watts", "battery_watts",
      "keeping_awake", "lid_closed", "sleep_disabled", "prevents_system_sleep",
      "prevents_idle_sleep", "prevents_display_sleep", "user_active",
    ]
    let rows = recent().map { change -> [String] in
      func value<T>(_ optional: T?) -> String { optional.map { String(describing: $0) } ?? "" }
      return [
        change.date.ISO8601Format(),
        url.pathExtension.lowercased() == "html" ? change.mode.label : change.mode.rawValue,
        value(change.battery), value(change.charging), value(change.chargerWatts),
        value(change.batteryWatts),
        value(change.keepingAwake), value(change.power?.lidClosed),
        value(change.power?.sleepDisabled),
        value(change.power?.preventsSystemSleep), value(change.power?.preventsIdleSleep),
        value(change.power?.preventsDisplaySleep), value(change.power?.userActive),
      ]
    }
    try TableExport.write(title: "SidePulse history", columns: columns, rows: rows, to: url)
  }
}
