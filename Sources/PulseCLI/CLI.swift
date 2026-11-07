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
    sidepulse-swift — native macOS companion
      devices | firmware version [--device PATH]
      firmware upgrade [--device PATH] [--version X.Y.Z | --file ZIP] [--dry-run]
      write [--device PATH | --all] [--dry-run] PROGRAM
      agent-monitor status [--json] | live | leds | doctor
      agent-monitor install|uninstall [codex|claude|cursor|grok|junie|all]
      hook-log --provider NAME [--event NAME] < event.json
      battery status | leds [--device PATH]
      settings [done SECONDS] | animations | service run|start|stop|status
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
    case "help", "-h", "--help": print(help)
    case "version", "--version", "-V": print("SidePulse Swift 0.1.0")
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
    case "write":
      let devices = try Args.devices()
      let all = Args.flag("--all")
      let dry = Args.flag("--dry-run")
      let source = try Args.program()
      guard !devices.isEmpty else { throw PulseError("Connect a SidePulse.") }
      for device in try all ? devices : [Args.one(devices)] {
        if !dry { try device.write(source) }
        print(
          (dry ? "Would write " : "Wrote ") + device.root.appendingPathComponent("LEDS.LED").path)
      }
    case "setup": try configure(install: true)
    case "agent-monitor":
      let sub = Args.pop() ?? "status"
      switch sub {
      case "install", "uninstall": try configure(install: sub == "install")
      case "doctor":
        try listDevices()
        print(
          "Native event directory: \(Paths.support.path)/events\nCompatible hook directory: \(Paths.legacyState.path)"
        )
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
      let data = try FileHandle.standardInput.read(upToCount: 2_097_153) ?? Data()
      if let raw = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
        try Events.record(provider: provider, raw: raw, named: event)
      }
      if provider == "cursor" { print("{}") }
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
    case "unlink": try Bridge.remove(Args.require("phone ID"))
    case "link":
      if let token = Args.pop() {
        try Bridge.store(token: token, name: try Args.option("--name") ?? "Phone")
      } else {
        try await Bridge.pair()
      }
    case "push":
      let to = try Args.option("--to")
      let title = try Args.option("--title")
      let message = try Args.option("--message")
      let source = Args.words.isEmpty && (title != nil || message != nil) ? nil : try Args.program()
      try await Bridge.push(to: to, program: source, title: title, message: message)
    case "relay":
      let action = try Args.require("send or receive")
      let channel = try Args.require("channel")
      switch action {
      case "receive": try await Bridge.receive(channel: channel)
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
  static func listDevices() throws {
    let devices = try Args.devices()
    try Args.end()
    for device in devices { print("SidePulse \(device.model) · \(device.firmware) · \(device.id)") }
    if devices.isEmpty { print("No SidePulse mounted.") }
  }
  static func configure(install: Bool) throws {
    let selected = Args.pop() ?? "all"
    try Args.end()
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    for provider in selected == "all" ? providers : [selected] {
      try Hooks.configure(provider, executable: executable, install: install)
      print("\(provider): \(install ? "installed" : "removed")")
    }
  }
  static func monitor(_ sub: String) async throws {
    let json = Args.flag("--json")
    try Args.end()
    let monitor = Monitor()
    let output = Output()
    repeat {
      let settings = try Settings.read()
      let rows = monitor.sessions()
      let mode = Monitor.aggregate(rows, settings: settings)
      if sub == "leds" {
        guard !Output.legacyRunning() else {
          throw PulseError("The existing SidePulse service owns LED output.")
        }
        try output.sync(
          devices: Device.discover(), mode: mode, settings: settings, battery: Battery.read())
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
      }
      if sub == "status" { return }
      try await Task.sleep(for: .seconds(1))
    } while !Task.isCancelled
  }
}
