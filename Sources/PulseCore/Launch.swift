import DiskArbitration
import Foundation

public enum Jobs {
  public static let prefix = "com.unipheas.SidePulseSwift."
  static var domain: String { "gui/\(getuid())" }
  static func plist(_ label: String) -> URL {
    Paths.home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
  }
  static func command(_ tool: String, _ arguments: [String]) throws -> Data {
    try SystemCommand.run(tool, arguments)
  }
  public static func running(_ label: String) -> Bool { isRunning(label, run: command) }
  private static func isRunning(_ label: String, run: (String, [String]) throws -> Data) -> Bool {
    (try? run("/bin/launchctl", ["print", domain + "/" + label])) != nil
  }
  public enum Scope: String { case auto, user, system }
  public static func running(_ job: String, scope: Scope) -> Bool {
    let domain = scope == .system || (scope == .auto && geteuid() == 0) ? "system" : Self.domain
    return (try? command("/bin/launchctl", ["print", domain + "/" + prefix + job])) != nil
  }
  public static func logDirectory(scope: Scope) -> URL {
    scope == .system || (scope == .auto && geteuid() == 0)
      ? URL(fileURLWithPath: "/Library/Logs/SidePulse") : Paths.support
  }
  public static func configure(
    _ job: String, executable: URL, start: Bool, scope: Scope = .user,
    remove: Bool = true, launch: Bool = true
  ) throws {
    let system = scope == .system || (scope == .auto && geteuid() == 0)
    guard !system || geteuid() == 0 else { throw PulseError("System scope requires sudo.") }
    try configure(
      job, executable: executable, start: start, run: command,
      system: system, remove: remove, launch: launch)
  }
  static func configure(
    _ job: String, executable: URL, start: Bool, run: (String, [String]) throws -> Data,
    system: Bool = false, remove: Bool = true, launch: Bool = true,
    systemDirectory: URL = URL(fileURLWithPath: "/Library/LaunchDaemons")
  ) throws {
    guard ["service", "sdejectguard", "app"].contains(job) else { throw PulseError("Unknown job.") }
    let label = prefix + job
    guard !system || job == "sdejectguard" else {
      throw PulseError("Only the eject guard supports system scope.")
    }
    let domain = system ? "system" : Self.domain
    let file = system ? systemDirectory.appendingPathComponent(label + ".plist") : plist(label)
    if (try? run("/bin/launchctl", ["print", domain + "/" + label])) != nil {
      _ = try run("/bin/launchctl", ["bootout", domain + "/" + label])
    }
    if start {
      try Paths.directory(file.deletingLastPathComponent())
      let logRoot =
        system
        ? systemDirectory.appendingPathComponent("../Logs/SidePulse").standardizedFileURL
        : Paths.support
      try Paths.directory(logRoot)
      let config: JSONObject = [
        "Label": label,
        "ProgramArguments": job == "app" ? [executable.path] : [executable.path, job, "run"],
        "RunAtLoad": true,
        "KeepAlive": true, "ThrottleInterval": 10,
        "StandardOutPath": logRoot.appendingPathComponent(job + ".out.log").path,
        "StandardErrorPath": logRoot.appendingPathComponent(job + ".err.log").path,
      ]
      try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(
        to: file, options: .atomic)
      if launch { _ = try run("/bin/launchctl", ["bootstrap", domain, file.path]) }
    } else if remove, FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
  public static func takeControl() throws { try takeControl(run: command) }
  static func takeControl(run: (String, [String]) throws -> Data) throws {
    var stopped = [String]()
    do {
      for label in ["io.sidepulse.agentstatus", "io.sidepulse.service"]
      where isRunning(label, run: run) {
        guard FileManager.default.fileExists(atPath: plist(label).path) else {
          throw PulseError("Cannot locate existing login job.")
        }
        _ = try run("/bin/launchctl", ["bootout", domain + "/" + label])
        stopped.append(label)
      }
      try Settings.update {
        $0["swift_paused_jobs"] = stopped
        $0["swift_mirror"] = true
      }
    } catch {
      for label in stopped { try? resume(label, run: run) }
      throw error
    }
  }
  private static func resume(_ label: String, run: (String, [String]) throws -> Data) throws {
    guard ["io.sidepulse.agentstatus", "io.sidepulse.service"].contains(label) else {
      throw PulseError("Unknown login job.")
    }
    if !isRunning(label, run: run) {
      _ = try run("/bin/launchctl", ["bootstrap", domain, plist(label).path])
    }
  }
  public static func giveBack() throws { try giveBack(run: command) }
  static func giveBack(run: (String, [String]) throws -> Data) throws {
    let labels = try Settings.read()["swift_paused_jobs"] as? [String] ?? []
    for label in labels.reversed() { try resume(label, run: run) }
    try Settings.update { $0.removeValue(forKey: "swift_paused_jobs") }
  }
}

extension Jobs {
  public static func logTail(_ file: URL, lines: Int) throws -> String {
    guard lines >= 0, lines <= 10000 else { throw PulseError("Use 0–10000 log lines.") }
    guard lines > 0, FileManager.default.fileExists(atPath: file.path) else { return "" }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    // Bound memory use even for a pathological single-line service error.
    let start = size > 1_048_576 ? size - 1_048_576 : 0
    try handle.seek(toOffset: start)
    let data = try handle.read(upToCount: Int(size - start)) ?? Data()
    var entries = String(decoding: data, as: UTF8.self).split(
      separator: "\n", omittingEmptySubsequences: false)
    if entries.last?.isEmpty == true { entries.removeLast() }
    if start > 0, !entries.isEmpty { entries.removeFirst() }
    return entries.suffix(lines).joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
  }
}
