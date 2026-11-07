import Darwin
import Foundation

public struct PulseError: LocalizedError {
  public let errorDescription: String?
  public init(_ message: String) { errorDescription = message }
}

public enum Paths {
  public static var home: URL {
    if let root = ProcessInfo.processInfo.environment["SIDEPULSE_USER_HOME"], !root.isEmpty {
      return URL(fileURLWithPath: root, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }
  public static var support: URL {
    if let path = ProcessInfo.processInfo.environment["SIDEPULSE_SWIFT_HOME"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return home.appendingPathComponent("Library/Application Support/SidePulse")
  }
  static func xdg(_ name: String, fallback: String) -> URL {
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
      return URL(fileURLWithPath: value)
    }
    return home.appendingPathComponent(fallback)
  }
  public static var legacyConfig: URL {
    xdg("XDG_CONFIG_HOME", fallback: ".config").appendingPathComponent("sidepulse/agent-monitor")
  }
  public static var legacyState: URL {
    xdg("XDG_STATE_HOME", fallback: ".local/state").appendingPathComponent(
      "sidepulse/agent-monitor")
  }
  public static func directory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
}

public typealias JSONObject = [String: Any]

public func object(_ url: URL) throws -> JSONObject {
  guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSONObject
  else {
    throw PulseError("Expected a JSON object in \(url.lastPathComponent).")
  }
  return result
}

public func saveObject(_ value: JSONObject, to url: URL) throws {
  try Paths.directory(url.deletingLastPathComponent())
  let data = try JSONSerialization.data(
    withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  try data.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@discardableResult
func withLock<T>(_ url: URL, _ action: () throws -> T) throws -> T {
  try Paths.directory(url.deletingLastPathComponent())
  let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
  guard fd >= 0 else { throw POSIXError(.EACCES) }
  defer { close(fd) }
  guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
  return try action()
}

public enum Settings {
  public static var url: URL { Paths.support.appendingPathComponent("settings.json") }
  public static func read() throws -> JSONObject {
    for file in [url, Paths.legacyConfig.appendingPathComponent("settings.json")]
    where FileManager.default.fileExists(atPath: file.path) {
      return try object(file)
    }
    return [:]
  }
  /// Materialize legacy file-backed programs before the previous installation is removed.
  public static func migrate() throws {
    try withLock(Paths.support.appendingPathComponent("settings.lock")) {
      for filename in ["links.json", "relay.json"] {
        let source = Paths.legacyConfig.appendingPathComponent(filename)
        let destination = Paths.support.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: source.path),
          !FileManager.default.fileExists(atPath: destination.path)
        {
          try saveObject(object(source), to: destination)
        }
      }
      var settings = try read()
      guard !settings.isEmpty else { return }
      var registry = settings["custom_agent_animations"] as? [String: JSONObject] ?? [:]
      var changed = !FileManager.default.fileExists(atPath: url.path)
      for (id, item) in registry where item["program"] == nil && item["file"] != nil {
        registry[id]?["program"] = try Programs.resolve(
          style: id, entry: [:], count: 8, settings: settings)
        changed = true
      }
      if changed {
        settings["custom_agent_animations"] = registry
        try saveObject(settings, to: url)
      }
    }
  }
  public static func update(_ edit: (inout JSONObject) throws -> Void) throws {
    try withLock(Paths.support.appendingPathComponent("settings.lock")) {
      var values = try read()
      try edit(&values)
      try saveObject(values, to: url)
    }
  }
  public static func seconds(_ settings: JSONObject, _ name: String, default fallback: Double)
    -> Double
  {
    let value = (settings["agent_list"] as? JSONObject)?[name] as? NSNumber
    guard let value = value?.doubleValue, value.isFinite, value >= 0 else { return fallback }
    return value
  }
  public static func setDone(_ seconds: Double) throws {
    guard seconds.isFinite, seconds >= 0 else {
      throw PulseError("Enter a finite duration of zero seconds or more.")
    }
    try update {
      var timing = $0["agent_list"] as? JSONObject ?? [:]
      timing["completed_visible_seconds"] = seconds
      $0["agent_list"] = timing
    }
  }
}

public enum SystemCommand {
  @discardableResult
  public static func run(_ binary: String, _ arguments: [String], limit: Int = 8 * 1024 * 1024)
    throws -> Data
  {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    var output = Data()
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
      if chunk.count > limit - output.count {
        process.terminate()
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
        throw PulseError("Command output exceeds the size limit.")
      }
      output.append(chunk)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw PulseError(
        "\(URL(fileURLWithPath: binary).lastPathComponent) exited with status \(process.terminationStatus)."
      )
    }
    return output
  }
}
