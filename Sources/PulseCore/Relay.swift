import Foundation

public struct RelayConfiguration: Codable, Equatable {
  public var version = 1
  public var server: String
  public var receiverChannel: String
  public var outboundChannel: String
  public var machineName: String
  enum CodingKeys: String, CodingKey {
    case version, server
    case receiverChannel = "receiver_channel"
    case outboundChannel = "outbound_channel"
    case machineName = "machine_name"
  }
  static var file: URL { Paths.support.appendingPathComponent("relay.json") }
  public static func read() throws -> Self {
    let url = [file, Paths.legacyConfig.appendingPathComponent("relay.json")].first {
      FileManager.default.fileExists(atPath: $0.path)
    }
    guard let url else {
      return Self(
        server: Bridge.server, receiverChannel: "", outboundChannel: "",
        machineName: Machine.name)
    }
    let values = try object(url)
    guard values["version"] as? Int == 1 else {
      throw PulseError("Unsupported relay configuration.")
    }
    return Self(
      server: values["server"] as? String ?? Bridge.server,
      receiverChannel: values["receiver_channel"] as? String ?? "",
      outboundChannel: values["outbound_channel"] as? String ?? "",
      machineName: values["machine_name"] as? String ?? Machine.name)
  }
  public func save() throws {
    guard version == 1 else { throw PulseError("Unsupported relay settings version.") }
    _ = try Bridge.address(server, channel: "validation")
    for channel in [receiverChannel, outboundChannel] where !channel.isEmpty {
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
    if config.receiverChannel.isEmpty {
      config.receiverChannel = UUID().uuidString.replacingOccurrences(of: "-", with: "")
      try config.save()
    }
    return config
  }
  public static func link(_ channel: String) throws {
    var config = try read()
    config.outboundChannel = channel
    try config.save()
  }
}

/// One receiver task per running service. Event timestamps prevent repeated forwarding.
public actor Relay {
  private var configuration: RelayConfiguration?
  private var receiver: Task<Void, Never>?
  private var forwarded = [String: Date]()
  private let send: (String, String, JSONObject, String) async throws -> Void
  private let receive: (String, String) async throws -> Void
  public init(
    send: @escaping (String, String, JSONObject, String) async throws -> Void = {
      try await Bridge.send(channel: $0, provider: $1, row: $2, origin: $3)
    },
    receive: @escaping (String, String) async throws -> Void = {
      try await Bridge.receive(channel: $0, origin: $1)
    }
  ) {
    self.send = send
    self.receive = receive
  }
  public func stop() async {
    let stopping = receiver
    receiver = nil
    configuration = nil
    stopping?.cancel()
    await stopping?.value
  }
  public func sync(_ sessions: [Session]) async throws {
    let config = try RelayConfiguration.read()
    if config != configuration {
      receiver?.cancel()
      receiver = nil
      if !config.receiverChannel.isEmpty {
        let receive = self.receive
        receiver = Task {
          try? await receive(config.receiverChannel, config.server)
        }
      }
      forwarded = [:]
      configuration = config
    }
    guard !config.outboundChannel.isEmpty else { return }
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
      try await send(config.outboundChannel, item.provider, row, config.server)
      forwarded[item.id] = item.date
    }
    forwarded = forwarded.filter { key, _ in sessions.contains { $0.id == key } }
  }
}
