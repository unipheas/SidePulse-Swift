import Foundation

public struct RelayConfiguration: Codable, Equatable {
  public var version = 1
  public var server: String
  public var receiver_channel: String
  public var outbound_channel: String
  public var machine_name: String
  static var file: URL { Paths.support.appendingPathComponent("relay.json") }
  public static func read() throws -> Self {
    let url = [file, Paths.legacyConfig.appendingPathComponent("relay.json")].first {
      FileManager.default.fileExists(atPath: $0.path)
    }
    guard let url else {
      return Self(
        server: Bridge.server, receiver_channel: "", outbound_channel: "",
        machine_name: ProcessInfo.processInfo.hostName)
    }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
  public func save() throws {
    guard version == 1 else { throw PulseError("Unsupported relay settings version.") }
    _ = try Bridge.address(server, channel: "validation")
    for channel in [receiver_channel, outbound_channel] where !channel.isEmpty {
      guard channel.range(of: #"^[A-Za-z0-9_-]{11,128}$"#, options: .regularExpression) != nil
      else {
        throw PulseError(
          "Relay codes must contain 11–128 letters, numbers, hyphens or underscores.")
      }
    }
    try Paths.directory(Paths.support)
    try JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
  }
  public static func receiver() throws -> Self {
    var config = try read()
    if config.receiver_channel.isEmpty {
      config.receiver_channel = UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try config.save()
    }
    return config
  }
  public static func link(_ channel: String) throws {
    var config = try read()
    config.outbound_channel = channel
    try config.save()
  }
}

/// One receiver task per running service. Event timestamps prevent repeated forwarding.
public actor Relay {
  private var configuration: RelayConfiguration?
  private var receiver: Task<Void, Never>?
  private var forwarded = [String: Date]()
  public init() {}
  public func stop() {
    receiver?.cancel()
    receiver = nil
  }
  public func sync(_ sessions: [Session]) async throws {
    let config = try RelayConfiguration.read()
    if config != configuration {
      receiver?.cancel()
      receiver = nil
      if !config.receiver_channel.isEmpty {
        receiver = Task {
          try? await Bridge.receive(channel: config.receiver_channel, origin: config.server)
        }
      }
      forwarded = [:]
      configuration = config
    }
    guard !config.outbound_channel.isEmpty else { return }
    for item in sessions where !item.session.hasPrefix("relay:") && forwarded[item.id] != item.date
    {
      // Expired activity must not awaken the receiving device after restarting the sender.
      guard Date().timeIntervalSince(item.date) < 3600 else { continue }
      let row: JSONObject = [
        "logged_at": Events.timestamp(item.date),
        "event": [
          "hook_event_name": item.event, "session_id": item.threadID ?? item.session,
          "agent_id": item.session, "sidepulse_status": item.mode.rawValue,
          "session_title": item.name,
        ],
      ]
      try await Bridge.send(
        channel: config.outbound_channel, provider: item.provider, row: row, origin: config.server)
      forwarded[item.id] = item.date
    }
    forwarded = forwarded.filter { key, _ in sessions.contains { $0.id == key } }
  }
}
