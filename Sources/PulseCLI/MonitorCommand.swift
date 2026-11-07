import Foundation
import PulseCore

extension CLI {
  static func monitor(_ sub: String) async throws {
    let json = Args.flag("--json")
    let once = Args.flag("--once")
    let dry = Args.flag("--dry-run")
    let interval = Double(try Args.option("--interval") ?? "1") ?? -1
    guard interval.isFinite && interval > 0 else {
      throw PulseError("Enter a positive polling interval.")
    }
    let path = try Args.option("--device")
    let stale = try Args.option("--stale-after")
    let tool = try Args.option("--tool-running-timeout")
    var logs = [String: URL]()
    for provider in providers {
      if let path = try Args.option("--" + provider + "-log") {
        logs[provider] = URL(fileURLWithPath: path)
      }
    }
    _ = Args.flag("--no-color")
    let all = Args.flag("--all")
    try Args.end()
    let monitor = Monitor(logs: logs)
    let output = Output()
    let sleep = SleepOverride()
    defer {
      try? sleep.restore()
      output.keepAwake(false)
    }
    var lastPhoneMode: Mode?
    repeat {
      var settings = try Settings.read()
      var timing = settings["agent_list"] as? JSONObject ?? [:]
      for (key, value) in [("idle_timeout_seconds", stale), ("tool_running_timeout_seconds", tool)]
      {
        if let value {
          guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
            throw PulseError("Enter a finite timeout of zero or more.")
          }
          timing[key] = seconds
        }
      }
      settings["agent_list"] = timing
      let rows = monitor.sessions()
      let mode = Monitor.aggregate(rows, settings: settings)
      if sub == "leds" {
        guard dry || !Output.legacyRunning() else {
          throw PulseError("The existing SidePulse service owns LED output.")
        }
        let devices =
          try path.map { [try Device.inspect(URL(fileURLWithPath: $0))] } ?? Device.discover()
        if dry {
          for device in devices {
            print(
              device.id + "\n"
                + (try Programs.program(mode, count: device.count, settings: settings)))
          }
        } else {
          let battery = Battery.read()
          try sleep.update(mode: mode, settings: settings, battery: battery, owner: true)
          output.keepAwake(
            settings["swift_keep_awake"] as? Bool == true
              && [.working, .tool, .progress].contains(mode))
          try output.sync(devices: devices, mode: mode, settings: settings, battery: battery)
          try History.record(mode, battery: battery?.percent)
          if settings["swift_phone_mirror"] as? Bool == true, lastPhoneMode != mode {
            let program = try Programs.program(mode, count: 8, settings: settings)
            for phone in try Bridge.phones() {
              try await Bridge.push(to: phone.id, program: program, title: nil, message: nil)
            }
            lastPhoneMode = mode
          }
        }
      } else if json {
        struct Report: Encodable {
          let mode: Mode
          let sessions: [Session]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        print(
          String(decoding: try encoder.encode(Report(mode: mode, sessions: rows)), as: UTF8.self))
      } else {
        print(mode.label)
        let ageLimit = Settings.seconds(settings, "idle_timeout_seconds", default: 3600)
        for row in rows where all || Date().timeIntervalSince(row.date) < ageLimit {
          print("\(row.name) · \(row.mode.label) · \(row.provider)")
        }
      }
      if sub == "status" || once { return }
      try await Task.sleep(for: .seconds(interval))
    } while !Task.isCancelled
  }
}
