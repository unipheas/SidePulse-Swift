import Foundation
import PulseCore

enum Args {
  static var words = Array(CommandLine.arguments.dropFirst())
  static func pop() -> String? { words.isEmpty ? nil : words.removeFirst() }
  static func flag(_ name: String) -> Bool {
    guard let index = words.firstIndex(of: name) else { return false }
    words.remove(at: index)
    return true
  }
  static func option(_ name: String) throws -> String? {
    guard let index = words.firstIndex(of: name) else { return nil }
    guard index + 1 < words.count else { throw PulseError("Missing value for \(name).") }
    words.remove(at: index)
    return words.remove(at: index)
  }
  static func require(_ label: String) throws -> String {
    guard let word = pop() else { throw PulseError("Expected \(label).") }
    return word
  }
  static func end() throws {
    if !words.isEmpty { throw PulseError("Unexpected argument: \(words[0])") }
  }
  static func program() throws -> String {
    let arg = pop()
    try end()
    if let arg, arg != "-" {
      return try Programs.normalize(arg.replacingOccurrences(of: "\\n", with: "\n"))
    }
    guard isatty(STDIN_FILENO) == 0 else {
      throw PulseError("Supply an LED program or pipe one on stdin.")
    }
    return try Programs.normalize(
      String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
  }
  static func devices() throws -> [Device] {
    if let path = try option("--device") { return [try Device.inspect(URL(fileURLWithPath: path))] }
    return Device.discover()
  }
  static func one(_ devices: [Device]) throws -> Device {
    guard devices.count == 1 else {
      throw PulseError(
        devices.isEmpty ? "Connect a SidePulse device." : "Select a device with --device PATH.")
    }
    return devices[0]
  }
}

@main struct CLI {
  static let help = """
    sidepulsectl — native macOS companion
      devices | firmware version [--device PATH]
      firmware upgrade [--device PATH] [--version X.Y.Z | --file ZIP] [--dry-run]
      audio-meter [--dry-run] | fifa-final [--score 2-1] [--dry-run]
      raw-write /dev/rdiskN [--dry-run] PROGRAM
      write [--device PATH | --all] [--dry-run] PROGRAM
      agent-monitor status [--json] | live | leds | doctor
      agent-monitor install|uninstall [codex|claude|cursor|grok|junie|all]
      hook-log --provider NAME [--event NAME] < event.json
      battery status | leds [--device PATH]
      migrate | settings [done SECONDS] | animations | service run|start|stop|status
      sdejectguard run|start|stop|status | classify MESSAGE
      profile import|export FILE | history FILE.csv|FILE.html
      link [TOKEN] | links | unlink ID | push [--to ID] [--title TEXT] [--message TEXT] [PROGRAM]
      relay receive CHANNEL | send CHANNEL PROVIDER < event.json
    """
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data(("SidePulse: " + error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  static func run() async throws {
    let command = Args.pop() ?? "help"
    switch command {
    case "update":
      let dry = Args.flag("--dry-run")
      try Args.end()
      if dry {
        print("https://github.com/unipheas/SidePulse-Swift/releases")
        return
      }
      try SystemCommand.run(
        "/usr/bin/open", ["https://github.com/unipheas/SidePulse-Swift/releases"])
    case "help", "-h", "--help": print(help)
    case "version", "--version", "-V": print("SidePulse 0.1.0")
    case "devices": try listDevices()
    case "firmware":
      switch try Args.require("version or upgrade") {
      case "version": try listDevices()
      case "upgrade":
        let devices = try Args.devices()
        let dry = Args.flag("--dry-run")
        let version = try Args.option("--version")
        let file = try Args.option("--file")
        try Args.end()
        print(
          try await Firmware.upgrade(Args.one(devices), version: version, file: file, dryRun: dry))
      default: throw PulseError("Use firmware version or upgrade.")
      }
    case "audio-meter", "fifa-final":
      let devices = try Args.devices()
      let dry = Args.flag("--dry-run")
      let device = dry ? devices.first : try Args.one(devices)
      if command == "audio-meter" {
        try Args.end()
        try await AudioMeter.run(device: device, dryRun: dry)
      } else {
        let score = try Args.option("--score")
        try Args.end()
        try await Scoreboard.run(device: device, score: score, dryRun: dry)
      }
    case "raw-write":
      let path = try Args.require("whole disk")
      let dry = Args.flag("--dry-run")
      try RawDisk.write(path: path, program: Args.program(), dryRun: dry)
    case "write", "push": try await deliver(preferPhone: command == "push")
    case "setup": try configure(install: true)
    case "agent-monitor":
      let sub = Args.pop() ?? "status"
      switch sub {
      case "install", "uninstall": try configure(install: sub == "install")
      case "version": print("SidePulse 0.1.0")
      case "doctor":
        let json = Args.flag("--json")
        try Args.end()
        let reports = Hooks.diagnostics()
        if json {
          try jsonPrint(reports)
        } else {
          for row in reports { print("\(row["provider"]!) · \(row["status"]!) · \(row["path"]!)") }
        }
      case "live", "watch", "status", "leds": try await monitor(sub)
      default: throw PulseError("Unknown agent-monitor command.")
      }
    case "service", "sdejectguard":
      switch Args.pop() ?? "status" {
      case "status": print(Jobs.running(Jobs.prefix + command) ? "running" : "stopped")
      case "start": try Jobs.configure(command, executable: Bundle.main.executableURL!, start: true)
      case "stop": try Jobs.configure(command, executable: Bundle.main.executableURL!, start: false)
      case "run":
        if command == "service" { try await monitor("leds") } else { try EjectGuard.run() }
      default: throw PulseError("Choose run, start, stop or status.")
      }
    case "classify":
      let message =
        Args.words.isEmpty
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        : Args.words.joined(separator: " ")
      print(try await ReplyClassifier.classify(message))
    case "hook-log":
      guard let provider = try Args.option("--provider") else {
        throw PulseError("Missing --provider.")
      }
      let event = try Args.option("--event")
      try Args.end()
      var data = Data()
      while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        guard data.count + chunk.count <= 2_097_152 else {
          throw PulseError("Hook payload exceeds 2 MiB.")
        }
        data.append(chunk)
      }
      if let raw = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
        try Events.record(provider: provider, raw: raw, named: event)
      }
      if provider == "cursor" { print("{}") }
    case "migrate":
      try Args.end()
      try Settings.migrate()
    case "settings":
      if Args.words.isEmpty {
        let app =
          Bundle.main.bundleURL.pathExtension == "app"
          ? Bundle.main.bundleURL
          : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else {
          print(Settings.url.path)
          return
        }
        try SystemCommand.run("/usr/bin/open", [app.path])
      } else {
        guard Args.pop() == "done", let value = Double(try Args.require("seconds")) else {
          throw PulseError("Use settings done SECONDS.")
        }
        try Args.end()
        try Settings.setDone(value)
        print("Done duration: \(value) seconds")
      }
    case "history":
      let file = try Args.require("output file")
      try Args.end()
      try History.export(to: URL(fileURLWithPath: file))
    case "profile":
      let action = try Args.require("import or export")
      let url = URL(fileURLWithPath: try Args.require("profile file"))
      try Args.end()
      if action == "import" {
        try Profiles.load(from: url)
      } else if action == "export" {
        try Profiles.export(to: url)
      } else {
        throw PulseError("Choose profile import or export.")
      }
    case "animations": print(Programs.animationNames.joined(separator: "\n"))
    case "battery":
      guard let battery = Battery.read() else { throw PulseError("No internal battery found.") }
      switch Args.pop() ?? "status" {
      case "status":
        print(
          "\(battery.percent)% · \(battery.charging ? "charging" : "on battery or fully charged")")
      case "leds":
        let device = try Args.one(Args.devices())
        try Args.end()
        try device.write(battery.program(count: device.count))
      default: throw PulseError("Use battery status or leds.")
      }
    case "links": for phone in try Bridge.phones() { print("\(phone.id)  \(phone.name)") }
    case "unlink":
      if let id = Args.pop() {
        try Args.end()
        try Bridge.remove(id)
      } else {
        for phone in try Bridge.phones() { print("\(phone.id)  \(phone.name)") }
      }
    case "link":
      if let token = Args.pop() {
        try Bridge.store(token: token, name: try Args.option("--name") ?? "Phone")
      } else {
        try await Bridge.pair()
      }
    case "relay":
      let action = try Args.require("send or receive")
      let channel = try Args.require("channel")
      switch action {
      case "receive":
        let once = Args.flag("--once")
        try Args.end()
        try await Bridge.receive(channel: channel, once: once)
      case "send":
        let provider = try Args.require("provider")
        guard providers.contains(provider),
          let row = try JSONSerialization.jsonObject(
            with: FileHandle.standardInput.readDataToEndOfFile()) as? JSONObject
        else { throw PulseError("Expected a provider and JSON event.") }
        try await Bridge.send(channel: channel, provider: provider, row: row)
      default: throw PulseError("Use relay send or receive.")
      }
    default: throw PulseError("Unknown command \(command). Run --help.")
    }
  }
  static func jsonPrint(_ value: Any) throws {
    print(
      String(
        decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys),
        as: UTF8.self))
  }
  static func listDevices() throws {
    let json = Args.flag("--json")
    let devices = try Args.devices()
    try Args.end()
    if json {
      try jsonPrint(
        devices.map {
          [
            "model": "SidePulse " + $0.model, "version": $0.firmware, "serial": $0.serial,
            "device": $0.root.path,
          ]
        })
      return
    }
    for device in devices { print("SidePulse \(device.model) · \(device.firmware) · \(device.id)") }
    if devices.isEmpty { print("No SidePulse mounted.") }
  }
  static func configure(install: Bool) throws {
    let dry = Args.flag("--dry-run")
    let selected = Args.pop() ?? "all"
    try Args.end()
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    for provider in selected == "all" ? providers : [selected] {
      guard providers.contains(provider) else { throw PulseError("Unknown provider.") }
      if dry {
        print("Would " + (install ? "install " : "remove ") + provider + " hooks")
        continue
      }
      try Hooks.configure(provider, executable: executable, install: install)
      print("\(provider): \(install ? "installed" : "removed")")
    }
  }
}
