import CoreImage
import CryptoKit
import Foundation

public struct Phone {
  public let name: String, id: String
  public var deviceID: String { "ios/" + id }
  let token: String, server: String
  var android: Bool { token.hasPrefix("fcm_") }
  init(token: String, name: String, server: String) throws {
    var token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if !token.hasPrefix("fcm_") {
      let development = token.lowercased().hasPrefix("dev_")
      let body = development ? String(token.dropFirst(4)) : token
      let parts = body.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
      let device = parts.first?.filter { !$0.isWhitespace }.lowercased() ?? ""
      token = (development ? "dev_" : "") + device + (parts.count == 2 ? "_" + parts[1] : "")
    }
    let pattern =
      token.hasPrefix("fcm_")
      ? #"^fcm_[!-~]{1,4096}_[0-9a-f]{32}$"#
      : #"^(dev_)?[0-9a-fA-F]{64}(_[A-Za-z0-9_-]{1,128})?$"#
    guard token.range(of: pattern, options: .regularExpression) != nil,
      token.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#%")) == nil
    else {
      throw PulseError("Invalid phone token.")
    }
    self.token = token
    self.name = name
    self.server = server
    self.id =
      token.hasPrefix("fcm_")
      ? SHA256.hash(data: Data(token.dropLast(33).utf8)).prefix(6).map {
        String(format: "%02x", $0)
      }.joined() : String(token.prefix(12))
  }
}

public enum Bridge {
  static let standard = "https://bridge.sidepulse.io"
  static var server: String { ProcessInfo.processInfo.environment["SIDEPULSE_SERVER"] ?? standard }
  static var file: URL { Paths.support.appendingPathComponent("links.json") }
  static func address(_ origin: String, channel: String) throws -> URL {
    guard let c = URLComponents(string: origin), ["https", "http"].contains(c.scheme),
      c.host != nil,
      c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      ["", "/"].contains(c.path),
      let base = c.url, !channel.isEmpty,
      channel.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\%#?")) == nil
    else { throw PulseError("Invalid bridge address.") }
    return base.appendingPathComponent("api/leds").appendingPathComponent(channel)
  }
  public static func phones() throws -> [Phone] {
    let legacy = Paths.legacyConfig.appendingPathComponent("links.json")
    guard
      let url = [file, legacy].first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else { return [] }
    let config = try object(url)
    return try ["ios", "android"].flatMap { platform in
      try (config[platform] as? [JSONObject] ?? []).map {
        try Phone(
          token: $0["token"] as? String ?? "", name: $0["name"] as? String ?? "Phone",
          server: $0["server"] as? String ?? standard)
      }
    }
  }
  static func edit(_ callback: (inout [Phone]) throws -> Void) throws {
    try withLock(Paths.support.appendingPathComponent("links.lock")) {
      var values = try phones()
      try callback(&values)
      var data: JSONObject = ["version": 1]
      for key in ["ios", "android"] {
        data[key] = values.filter { $0.android == (key == "android") }.map {
          ["name": $0.name, "server": $0.server, "token": $0.token]
        }
      }
      try saveObject(data, to: file)
    }
  }
  public static func store(token: String, name: String) throws {
    let phone = try Phone(token: token, name: name, server: server)
    try edit {
      $0.removeAll { $0.id == phone.id }
      $0.append(phone)
    }
  }
  public static func remove(_ id: String) throws {
    try edit { phones in
      guard let index = phones.firstIndex(where: { $0.id == id }) else {
        throw PulseError("Unknown phone ID.")
      }
      phones.remove(at: index)
    }
    try Settings.update { settings in
      var devices = settings["devices"] as? [JSONObject] ?? []
      devices.removeAll { $0["id"] as? String == "ios/" + id }
      settings["devices"] = devices
    }
  }
  static func post(_ data: JSONObject, url: URL) async throws {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 12
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: data)
    let response: URLResponse
    do { (_, response) = try await URLSession.shared.data(for: req) } catch {
      throw PulseError("Cannot reach the bridge.")
    }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw PulseError("Bridge rejected the request.")
    }
  }
  public static func push(to id: String?, program: String?, title: String?, message: String?)
    async throws
  {
    let links = try phones().filter { id == nil || $0.id == id || $0.name == id }
    guard links.count == 1 else {
      throw PulseError("Select one paired phone using --to ID. Use links to list phones.")
    }
    let phone = links[0]
    let event = UUID().uuidString
    var payload: JSONObject = ["data": eventData(event)]
    var alert = [String: String]()
    if let title {
      payload["title"] = title
      alert["title"] = title
    }
    if let message {
      payload["body"] = message
      alert["body"] = message
    }
    if let program { payload["leds"] = try Programs.normalize(program) }
    if phone.android {
      payload["sidepulse_event_id"] = event
    } else {
      var aps: JSONObject = ["content-available": 1]
      if !alert.isEmpty { aps["alert"] = alert }
      payload["aps"] = aps
    }
    try await post(
      payload, url: address(phone.server, channel: (phone.android ? "" : "apns_") + phone.token))
  }
  static func eventData(
    _ event: String, battery: Battery? = Battery.read(), name: String = Machine.name
  ) -> JSONObject {
    var source: JSONObject = ["name": name]
    if let battery {
      source["battery"] = [
        "level": battery.percent, "charging": battery.charging, "plugged_in": battery.plugged,
      ]
    }
    return ["sidepulse_event_id": event, "source": source]
  }
  static func events(_ channel: String, origin: String? = nil, consume: (JSONObject) throws -> Bool)
    async throws
  {
    guard channel.range(of: #"^[A-Za-z0-9_-]{11,128}$"#, options: .regularExpression) != nil else {
      throw PulseError("Invalid bridge channel.")
    }
    var req = URLRequest(url: try address(origin ?? server, channel: channel))
    req.timeoutInterval = 300
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw PulseError("Bridge stream unavailable.")
    }
    var line = Data()
    var body = Data()
    for try await byte in bytes {
      if byte != 10 {
        if byte != 13 { line.append(byte) }
        guard line.count < 2_097_152 else { throw PulseError("Oversized bridge message.") }
        continue
      }
      if line.isEmpty {
        if let json = (try? JSONSerialization.jsonObject(with: body)) as? JSONObject,
          try consume(json)
        {
          return
        }
        body.removeAll()
      } else if line.starts(with: Data("data:".utf8)) {
        body.append(line.dropFirst(5))
        body.append(10)
        guard body.count < 2_097_152 else { throw PulseError("Oversized bridge message.") }
      }
      line.removeAll()
    }
    throw PulseError("Bridge disconnected.")
  }
  public static func pair() async throws {
    let random = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    let channel = random.replacingOccurrences(of: "=", with: "").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "+", with: "-")
    var custom = URLComponents()
    custom.scheme = "sidepulse"
    custom.host = "pair"
    custom.queryItems = [
      URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "server", value: server),
      URLQueryItem(name: "channel", value: channel),
    ]
    let url = server == standard ? "sidepulse://p/" + channel : custom.string!
    print(url)
    if let filter = CIFilter(name: "CIQRCodeGenerator") {
      filter.setValue(Data(url.utf8), forKey: "inputMessage")
      if let image = filter.outputImage {
        let n = Int(image.extent.width)
        let context = CIContext()
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        context.render(
          image, toBitmap: &pixels, rowBytes: n * 4, bounds: image.extent, format: .RGBA8,
          colorSpace: CGColorSpaceCreateDeviceRGB())
        for y in (-2)..<(n + 2) {
          print(
            ((-2)..<(n + 2)).map { x in
              let dark = x >= 0 && x < n && y >= 0 && y < n && pixels[(y * n + x) * 4] < 128
              return dark ? "\u{1B}[40m  " : "\u{1B}[47m  "
            }.joined() + "\u{1B}[0m")
        }
      }
    }
    fflush(stdout)
    try await events(channel) { value in
      guard value["v"] as? Int == 1, let data = value["device"] as? JSONObject,
        let token = data["push_token"] as? String
      else { return false }
      let ios =
        value["type"] as? String == "ios_registration"
        && data["bundle_id"] as? String == "io.sidepulse.ios"
      let android =
        value["type"] as? String == "android_registration"
        && data["package_id"] as? String == "io.sidepulse.android"
      guard ios || android else { return false }
      try store(token: token, name: data["name"] as? String ?? "Phone")
      print("Phone linked.")
      return true
    }
  }
  public static func send(channel: String, provider: String, row: JSONObject, origin: String? = nil)
    async throws
  {
    guard channel.range(of: #"^[A-Za-z0-9_-]{11,128}$"#, options: .regularExpression) != nil else {
      throw PulseError("Invalid relay channel.")
    }
    let body: JSONObject = [
      "v": 1, "type": "agent_event", "event_id": UUID().uuidString,
      "source": ["name": Machine.name], "provider": provider, "line": row,
    ]
    try await post(body, url: address(origin ?? server, channel: channel))
  }
  public static func receive(channel: String, once: Bool = false, origin: String? = nil)
    async throws
  {
    guard channel.range(of: #"^[A-Za-z0-9_-]{11,128}$"#, options: .regularExpression) != nil else {
      throw PulseError("Invalid relay channel.")
    }
    _ = try address(origin ?? server, channel: channel)
    var seen = Set<String>()
    repeat {
      do {
        try await events(channel, origin: origin) { value in
          guard value["v"] as? Int == 1, value["type"] as? String == "agent_event",
            let provider = value["provider"] as? String,
            providers.contains(provider), let row = value["line"] as? JSONObject,
            let id = value["event_id"] as? String, !seen.contains(id)
          else { return false }
          var raw = row["event"] as? JSONObject ?? row
          let source = (value["source"] as? JSONObject)?["name"] as? String ?? "remote"
          raw["agent_id"] = "relay:\(source):\(raw["agent_id"] ?? raw["session_id"] ?? "default")"
          try Events.record(provider: provider, raw: raw)
          if seen.count >= 2048 { seen.removeAll() }
          seen.insert(id)
          return once
        }
        if once { return }
      } catch {
        if once || Task.isCancelled { throw error }
        try await Task.sleep(for: .seconds(1))
      }
    } while !Task.isCancelled
  }
}
