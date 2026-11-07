import Foundation
import PulseCore

extension CLI {
  static func serviceCommand(_ job: String) async throws {
    let action = Args.pop() ?? "status"
    if job == "service", action == "code" {
      try Args.end()
      print("sidepulsectl link " + (try RelayConfiguration.receiver()).receiverChannel)
      return
    }
    if action == "logs" {
      let count = Int(try Args.option("--lines") ?? "80") ?? -1
      let follow = Args.flag("--follow") || Args.flag("-f")
      try Args.end()
      guard count >= 0, count <= 10000 else { throw PulseError("Use 0–10000 log lines.") }
      let logs = ["out", "err"].map {
        Paths.support.appendingPathComponent(job + "." + $0 + ".log")
      }
      for file in logs {
        print("== " + file.lastPathComponent + " ==")
        print(try Jobs.logTail(file, lines: count), terminator: "")
      }
      guard follow else { return }
      var offsets = logs.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
      repeat {
        try await Task.sleep(for: .seconds(1))
        for (index, file) in logs.enumerated() {
          guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
          defer { try? handle.close() }
          let size = Int(try handle.seekToEnd())
          try handle.seek(toOffset: UInt64(size < offsets[index] ? 0 : offsets[index]))
          let data = try handle.read(upToCount: 262144) ?? Data()
          offsets[index] = Int(try handle.offset())
          FileHandle.standardOutput.write(data)
        }
      } while !Task.isCancelled
      return
    }
    switch action {
    case "status":
      try Args.end()
      print(Jobs.running(Jobs.prefix + job) ? "running" : "stopped")
    case "start", "restart", "stop", "uninstall":
      let dry = Args.flag("--dry-run")
      try Args.end()
      if dry {
        print("Would \(action) \(job)")
        return
      }
      try Jobs.configure(
        job, executable: Bundle.main.executableURL!, start: ["start", "restart"].contains(action))
    case "run":
      if job == "service" {
        try await monitor("leds")
      } else {
        try Args.end()
        try EjectGuard.run()
      }
    default: throw PulseError("Choose run, start, restart, stop, uninstall, status or logs.")
    }
  }
}
