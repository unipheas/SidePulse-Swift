import Foundation
import PulseCore

enum Args {
  static var words = initial(CommandLine.arguments)
  static func initial(_ arguments: [String]) -> [String] {
    let words = Array(arguments.dropFirst())
    return arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } == "agent-monitor"
      ? ["agent-monitor"] + words : words
  }
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
      write [--device PATH | --all] [--file-name NAME.LED] [--dry-run] PROGRAM
      agent-monitor status [--json] | live | leds | doctor
        [--max-lines N] [--recent-seconds N] [--PROVIDER-log PATH]
        [--device PATH] [--file-name NAME.LED] [--once] [--dry-run]
      agent-monitor install|uninstall [codex|claude|cursor|grok|junie|all]
        install|uninstall: [--log-dir PATH] [--PROVIDER-log PATH]
      agent-event --source NAME --run ID --started-at UNIX_SECONDS --state STATE --sequence N
        [--lease-seconds N]
      hook-log --provider NAME [--event NAME] [--log PATH] < event.json
      battery status [--json] | leds [--device PATH] [--file-name NAME.LED]
      battery configure [--display agent|battery] [--full-watts auto|WATTS]
        [--show-on-power-change yes|no] [--power-change-preview-seconds N]
      migrate | settings [done SECONDS] | animations | service run|start|stop|status
      service|sdejectguard run|start|restart|stop|uninstall|status
        [--scope user|system|auto] [--dry-run]
      service|sdejectguard logs [--lines N] [--follow]
      sdejectguard start --interactive
      status-bar start|stop [--foreground] [--no-start] [--uninstall] [--dry-run]
      status-bar install-sleep-helper|uninstall-sleep-helper|sleep-helper-status
      classify [--backend apple|mlx] [--model MODEL] [--json] [MESSAGE]
      update
      profile import|export FILE | history|audit FILE.csv|FILE.html
      link [TOKEN] | links | unlink ID | push [--to ID] [--title TEXT] [--message TEXT] [PROGRAM]
      relay receive CHANNEL | send CHANNEL PROVIDER < event.json
    """
  static func main() async {
    let task = Task { try await run() }
    var signals = [DispatchSourceSignal]()
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { task.cancel() }
      source.resume()
      signals.append(source)
    }
    defer { signals.forEach { $0.cancel() } }
    do { try await task.value } catch is CancellationError {
      return
    } catch {
      FileHandle.standardError.write(Data(("SidePulse: " + error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  static func run(
    executable: URL = Bundle.main.executableURL!,
    launch: (String, [String]) throws -> Data = SystemCommand.execute
  ) async throws {
    let command = Args.pop() ?? "help"
    switch command {
    case "update":
      let dry = Args.flag("--dry-run")
      try Args.end()
      if dry {
        print("https://github.com/unipheas/SidePulse-Swift/releases")
        return
      }
      try launch(
        "/usr/bin/open", ["sidepulse-native://updates"])
    case "help", "-h", "--help": print(help)
    case "version", "--version", "-V": print("SidePulse 0.2.2")
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
    case "status-bar": try appCommand()
    case "setup": try setup()
    case "agent-monitor":
      let sub = Args.pop() ?? "status"
      switch sub {
      case "status-bar": try appCommand()
      case "agent-event": try localAgentEvent()
      case "hook-log":
        Args.words.insert("hook-log", at: 0)
        try await run()
      case "install", "uninstall": try configure(install: sub == "install")
      case "version", "--version", "-V": print("SidePulse 0.2.2")
      case "help", "--help", "-h": print(help)
      case "doctor":
        let json = Args.flag("--json")
        try Args.end()
        let reports = Hooks.diagnostics()
        if json {
          print(String(decoding: try JSONEncoder().encode(reports), as: UTF8.self))
        } else {
          for row in reports { print("\(row.provider) · \(row.status) · \(row.path)") }
        }
      case "live", "watch", "status", "leds": try await monitor(sub)
      default: throw PulseError("Unknown agent-monitor command.")
      }
    case "service", "sdejectguard": try await serviceCommand(command)
    case "classify":
      let json = Args.flag("--json")
      let model = try Args.option("--model")
      let backend = try Args.option("--backend") ?? (model == nil ? "apple" : "mlx")
      guard ["apple", "mlx"].contains(backend), !(backend == "apple" && model != nil) else {
        throw PulseError("Choose --backend apple or mlx; --model selects an MLX model.")
      }
      let message =
        Args.words.isEmpty
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        : Args.words.joined(separator: " ")
      let result = try await ReplyClassifier.result(message) { text in
        if backend == "mlx" {
          return try ReplyClassifier.mlx(text, model: model ?? ReplyClassifier.defaultMLXModel)
        }
        return try await ReplyClassifier.generate(text)
      }
      if json {
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
      } else {
        print(result.label)
      }
    case "agent-event": try localAgentEvent()
    case "hook-log":
      guard let provider = try Args.option("--provider") else {
        throw PulseError("Missing --provider.")
      }
      let event = try Args.option("--event")
      let log = try Args.option("--log").map { URL(fileURLWithPath: $0) }
      try Args.end()
      defer { if provider == "cursor" { print("{}") } }
      var data = Data()
      while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        guard data.count + chunk.count <= 2_097_152 else {
          return
        }
        data.append(chunk)
      }
      if let raw = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
        do { try Events.record(provider: provider, raw: raw, named: event, log: log) } catch {
          FileHandle.standardError.write(
            Data(("SidePulse hook logging failed: " + error.localizedDescription + "\n").utf8))
        }
      }

    case "migrate":
      try Args.end()
      try Settings.migrate()
    case "settings":
      if Args.words.isEmpty {
        guard let app = try? AppInstallation.bundle(for: executable.resolvingSymlinksInPath())
        else {
          print(Settings.url.path)
          return
        }
        try launch("/usr/bin/open", ["-a", app.path, "sidepulse-native://settings"])
      } else {
        guard Args.pop() == "done", let value = Double(try Args.require("seconds")) else {
          throw PulseError("Use settings done SECONDS.")
        }
        try Args.end()
        try Settings.setDone(value)
        print("Done duration: \(value) seconds")
      }
    case "history", "audit":
      let file = try Args.require("output file")
      try Args.end()
      if command == "audit" {
        try Audit.export(to: URL(fileURLWithPath: file))
      } else {
        try History.export(to: URL(fileURLWithPath: file))
      }
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
    case "battery": try await batteryCommand()
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
        let name = try Args.option("--name")
        try Args.end()
        if name == nil
          && token.range(of: #"^[A-Za-z0-9_-]{11,63}$"#, options: .regularExpression) != nil
        {
          try RelayConfiguration.link(token)
          print("Remote receiver linked.")
        } else {
          try Bridge.store(token: token, name: name ?? "Phone")
        }
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
  static func listDevices(discover: () throws -> [Device] = Args.devices) throws {
    let json = Args.flag("--json")
    let devices = try discover()
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
    let directory = try Args.option("--log-dir").map { URL(fileURLWithPath: $0) }
    var logs = [String: URL]()
    for provider in providers {
      if let path = try Args.option("--" + provider + "-log") {
        logs[provider] = URL(fileURLWithPath: path)
      } else if let directory {
        logs[provider] = directory.appendingPathComponent(provider + ".jsonl")
      }
    }
    let selected = Args.pop() ?? "all"
    try Args.end()
    let executable = Bundle.main.executableURL!
    for provider in selected == "all" ? providers : [selected] {
      guard providers.contains(provider) else { throw PulseError("Unknown provider.") }
      if dry {
        print("Would " + (install ? "install " : "remove ") + provider + " hooks")
        continue
      }
      try Hooks.configure(provider, executable: executable, install: install, log: logs[provider])
      try Settings.update {
        var configured = $0["hook_logs"] as? [String: String] ?? [:]
        configured[provider] = install ? logs[provider]?.standardizedFileURL.path : nil
        $0["hook_logs"] = configured
      }
      print("\(provider): \(install ? "installed" : "removed")")
    }
  }
}
