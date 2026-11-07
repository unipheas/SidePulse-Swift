import Foundation
import PulseCore

extension CLI {
  static func monitor(
    _ sub: String, discover: () -> [Device] = Device.discover,
    legacyRunning: () -> Bool = Output.legacyRunning,
    wait: (Double) async throws -> Void = Polling.wait,
    interactive: Bool = isatty(STDOUT_FILENO) != 0,
    sleep: SleepOverride = SleepOverride(), phoneOutput: PhoneOutput = PhoneOutput(),
    report: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
  ) async throws {
    try Settings.migrate()
    let json = Args.flag("--json")
    let once = Args.flag("--once")
    let dry = Args.flag("--dry-run")
    let interval = Double(try Args.option("--interval") ?? "1") ?? -1
    guard interval.isFinite && interval > 0 else {
      throw PulseError("Enter a positive polling interval.")
    }
    let path = try Args.option("--device")
    let fileName = try Args.option("--file-name") ?? "LEDS.LED"
    let stale = try Args.option("--stale-after")
    let tool = try Args.option("--tool-running-timeout")
    let maxLines = Int(try Args.option("--max-lines") ?? "5000") ?? 0
    let recent = Double(try Args.option("--recent-seconds") ?? "3600") ?? -1
    guard maxLines > 0, maxLines <= 100000, recent.isFinite, recent >= 0 else {
      throw PulseError("Use 1–100000 recent lines and a finite nonnegative time window.")
    }
    var logs = [String: URL]()
    for provider in providers {
      if let path = try Args.option("--" + provider + "-log") {
        logs[provider] = URL(fileURLWithPath: path)
      }
    }
    let noColor = Args.flag("--no-color")
    let all = Args.flag("--all")
    try Args.end()
    let redraw = interactive && !json && sub != "status" && sub != "leds" && !once
    if redraw { print("\u{1B}[?25l", terminator: "") }
    defer { if redraw { print("\u{1B}[?25h", terminator: "") } }
    let monitor = Monitor(logs: logs, maxLines: maxLines)
    let output = Output()
    defer {
      try? sleep.restore()
      output.keepAwake(false)
    }
    let relay = Relay()
    do {
      repeat {
        var settings = try Settings.read()
        var timing = settings["agent_list"] as? JSONObject ?? [:]
        for (key, value) in [
          ("idle_timeout_seconds", stale), ("tool_running_timeout_seconds", tool),
        ] {
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
          guard dry || !legacyRunning() else {
            throw PulseError("The existing SidePulse service owns LED output.")
          }
          var discovered = false
          do {
            let devices =
              try path.map { [try Device.inspect(URL(fileURLWithPath: $0), fileName: fileName)] }
              ?? discover().map { try Device.inspect($0.root, fileName: fileName) }
            discovered = true
            if dry {
              for device in devices {
                print(
                  device.id + "\n"
                    + (try Programs.program(mode, count: device.count, settings: settings)))
              }
            } else {
              settings = try Settings.remember(devices, settings: settings)
              let battery = Battery.read()
              do {
                try sleep.update(mode: mode, settings: settings, battery: battery, owner: true)
              } catch { report("Sleep control: " + error.localizedDescription) }
              output.updateAwake(mode: mode, settings: settings, battery: battery)
              var failure: Error?
              do {
                try output.sync(
                  devices: devices, mode: mode, settings: settings, battery: battery,
                  agentsActive: Monitor.hasActive(rows, settings: settings))
              } catch { failure = error }
              do {
                try History.record(
                  mode, battery: battery?.percent, snapshot: battery,
                  keepingAwake: output.isKeepingAwake, power: PowerSnapshot.read())
                try await relay.sync(rows)
              } catch {
                report(error.localizedDescription)
                if failure == nil { failure = error }
              }
              do {
                try await phoneOutput.sync(mode: mode, settings: settings, battery: battery)
              } catch {
                report(error.localizedDescription)
                if failure == nil { failure = error }
              }
              if let failure { throw failure }
            }
          } catch {
            if once { throw error }
            if !discovered { output.reset() }
            report(error.localizedDescription)
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
          let ageLimit =
            sub == "status"
            ? Settings.seconds(settings, "idle_timeout_seconds", default: 3600) : recent
          let visible = rows.filter { all || Date().timeIntervalSince($0.date) < ageLimit }
          if redraw { print("\u{1B}[2J\u{1B}[H", terminator: "") }
          print(
            ConsoleSnapshot.render(
              mode: mode, sessions: visible,
              color: interactive && !noColor
                && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            ))
          fflush(stdout)
        }
        if sub == "status" || once { break }
        try await wait(interval)
      } while !Task.isCancelled
    } catch {
      await relay.stop()
      throw error
    }
    await relay.stop()
  }
}
