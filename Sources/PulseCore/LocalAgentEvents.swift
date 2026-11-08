import CryptoKit
import Darwin
import Foundation

/// A local, content-free lifecycle snapshot. This is not an inference detector.
public enum LocalAgentEvents {
  static var directory: URL { Paths.support.appendingPathComponent("local-agents") }
  static let retention: TimeInterval = 86400
  static let capacity = 4096
  struct Record: Codable {
    let version: Int
    let source: String
    let run: String
    let sequence: UInt64
    let state: Mode
    let startedAt: Date
    let updatedAt: Date
    let leaseSeconds: Double

    var terminal: Bool { state == .done || state == .idle }
    func validate() throws {
      guard version == 1, LocalAgentEvents.slug(source, limit: 48),
        LocalAgentEvents.slug(run, limit: 128), sequence > 0,
        leaseSeconds.isFinite, (5...3600).contains(leaseSeconds),
        startedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
        startedAt <= updatedAt
      else { throw PulseError("Invalid local agent event.") }
    }
    func session(now: Date) -> Session {
      let lease = updatedAt.addingTimeInterval(leaseSeconds)
      let active = [.working, .tool, .progress].contains(state)
      return Session(
        provider: "local", session: source + ":" + run, name: source,
        event: "LocalAgentEvent", date: updatedAt, origin: "Local adapter",
        mode: active && now >= lease ? .unknown : state,
        leaseExpiresAt: active ? lease : nil)
    }
  }

  static func slug(_ text: String, limit: Int) -> Bool {
    !text.isEmpty && text.utf8.count <= limit && text.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || [45, 46, 95].contains($0)
    }
  }
  static func file(source: String, run: String) -> URL {
    let hash = SHA256.hash(data: Data((source + "\u{0}" + run).utf8))
      .map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(hash + ".json")
  }
  static func read(
    _ file: URL, openFile: (String, Int32) -> Int32 = { open($0, $1) },
    readBytes: (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }
  ) throws -> Record {
    let fd = openFile(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size > 0, info.st_size <= 8192
    else { throw PulseError("Invalid local agent snapshot file.") }
    let data = try readBytes(handle, 8193) ?? Data()
    let record = try JSONDecoder().decode(Record.self, from: data)
    try record.validate()
    return record
  }
  static func write(
    _ record: Record, to file: URL,
    create: (String, Int32, mode_t) -> Int32 = { open($0, $1, $2) },
    replace: (String, String) -> Int32 = { rename($0, $1) }
  ) throws {
    let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
    let fd = create(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try handle.write(contentsOf: JSONEncoder().encode(record))
    try handle.synchronize()
    guard replace(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
  }

  /// Sequence numbers increase within a unique run. Finished runs cannot be resurrected.
  /// No prompts, responses, tool arguments, paths, or arbitrary payload fields are accepted.
  @discardableResult
  public static func record(
    source: String, run: String, state: Mode, sequence: UInt64,
    startedAt: Date, leaseSeconds: Double = 60, now: Date = Date()
  ) throws -> Bool {
    let incoming = Record(
      version: 1, source: source, run: run, sequence: sequence, state: state,
      startedAt: startedAt, updatedAt: now, leaseSeconds: leaseSeconds)
    return try record(incoming, capacity: capacity)
  }

  static func record(_ incoming: Record, capacity: Int) throws -> Bool {
    try incoming.validate()
    let source = incoming.source, run = incoming.run, now = incoming.updatedAt
    let destination = file(source: source, run: run)
    return try withLock(directory.appendingPathComponent("events.lock")) {
      let previous: Record?
      do { previous = try read(destination) } catch let error as POSIXError where error.code == .ENOENT {
        previous = nil
      }
      if let previous {
        guard previous.source == source, previous.run == run,
          previous.startedAt == incoming.startedAt
        else {
          throw PulseError("Local agent identity mismatch.")
        }
        guard incoming.sequence > previous.sequence, !previous.terminal, now >= previous.updatedAt else {
          return false
        }
      } else {
        guard now.timeIntervalSince(incoming.startedAt) < retention else {
          throw PulseError("New local agent runs must have started within the last 24 hours.")
        }
        try admitRun(now: now, capacity: capacity)
      }
      try write(incoming, to: destination)
      return true
    }
  }

  /// Bound snapshots and tombstones. The immutable start time prevents delayed events
  /// from recreating an expired run after its tombstone has been pruned.
  private static func admitRun(now: Date, capacity: Int) throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      .filter { $0.pathExtension == "json" }
    guard files.count >= capacity else { return }
    var remaining = files.count
    for file in files {
      guard let record = try? read(file),
        file.lastPathComponent == self.file(source: record.source, run: record.run).lastPathComponent,
        now.timeIntervalSince(record.updatedAt) >= retention,
        now.timeIntervalSince(record.startedAt) >= retention
      else { continue }
      try FileManager.default.removeItem(at: file)
      remaining -= 1
      if remaining < capacity { return }
    }
    throw PulseError("Local agent snapshot limit reached; wait for expired runs to leave retention.")
  }

  /// Cache unchanged snapshots in the long-running monitor; timestamps still expire
  /// on every poll, even when no files changed.
  public final class Reader {
    private struct Cached {
      let modified: Date
      let inode: UInt64
      let size: UInt64
      let record: Record
    }
    private var cached = [URL: Cached]()
    public init() {}
    public func sessions(now: Date = Date()) -> [Session] {
      guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { cached = [:]; return [] }
      var next = [URL: Cached]()
      var sessions = [Session]()
      for file in files.filter({ $0.pathExtension == "json" }).prefix(capacity) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let modified = attributes[.modificationDate] as? Date,
          let inode = attributes[.systemFileNumber] as? UInt64,
          let size = attributes[.size] as? UInt64
        else { continue }
        let entry: Cached
        if let existing = cached[file], existing.modified == modified,
          existing.inode == inode, existing.size == size
        {
          entry = existing
        } else {
          guard let record = try? read(file),
            file.lastPathComponent == LocalAgentEvents.file(
              source: record.source, run: record.run).lastPathComponent
          else { continue }
          entry = Cached(modified: modified, inode: inode, size: size, record: record)
        }
        next[file] = entry
        let record = entry.record
        guard record.updatedAt <= now.addingTimeInterval(5),
          now.timeIntervalSince(record.updatedAt) < retention
        else { continue }
        sessions.append(record.session(now: now))
      }
      cached = next
      return sessions
    }
  }

  public static func sessions(now: Date = Date()) -> [Session] {
    Reader().sessions(now: now)
  }
}
