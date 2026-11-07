import Foundation

public struct Change: Codable, Identifiable {
  public let date: Date
  public let mode: Mode
  public let battery: Int?
  public var id: Date { date }
}

public enum History {
  static var file: URL { Paths.support.appendingPathComponent("history.jsonl") }
  public static func recent() -> [Change] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    return data.split(separator: 10).compactMap { try? JSONDecoder().decode(Change.self, from: $0) }
  }
  public static func record(_ mode: Mode, battery: Int?) throws {
    try withLock(Paths.support.appendingPathComponent("history.lock")) {
      let entry = Change(date: Date(), mode: mode, battery: battery)
      var data = (try? Data(contentsOf: file)) ?? Data()
      if let last = data.split(separator: 10).last,
        (try? JSONDecoder().decode(Change.self, from: last))?.mode == mode
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
    let changes = recent()
    let data: String
    if url.pathExtension.lowercased() == "html" {
      let rows = changes.map {
        "<tr><td>\($0.date.ISO8601Format())</td><td>\($0.mode.label)</td><td>\($0.battery.map(String.init) ?? "")</td></tr>"
      }.joined()
      data =
        "<!doctype html><meta charset=utf-8><title>SidePulse history</title><table><tr><th>Time (UTC)</th><th>State</th><th>Battery %</th></tr>\(rows)</table>"
    } else {
      data =
        "time_utc,state,battery_percent\n"
        + changes.map {
          "\($0.date.ISO8601Format()),\($0.mode.rawValue),\($0.battery.map(String.init) ?? "")\n"
        }.joined()
    }
    try Data(data.utf8).write(to: url, options: .atomic)
  }
}
