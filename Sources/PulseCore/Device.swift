import CryptoKit
import Darwin
import Foundation
import IOKit.ps
import JavaScriptCore

public struct Device: Identifiable, Equatable {
  public let root: URL, model: String, firmware: String, serial: String
  public var id: String { root.path }
  public var count: Int { model == "Dot" ? 2 : 8 }
  public var name: String { root.lastPathComponent }
  public static func inspect(_ root: URL) throws -> Device {
    let url = root.appendingPathComponent("STATUS.TXT")
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 65536) ?? Data()
    var fields = [String: String]()
    for line in String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
      .split(whereSeparator: \.isNewline)
    {
      let pair = line.split(separator: " ", maxSplits: 1)
      if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
    }
    let dot = fields["app_version"] != nil
    let pro = fields["release_version"] != nil
    guard dot != pro else { throw PulseError("Unrecognized SidePulse volume at \(root.path).") }
    return Device(
      root: root.standardizedFileURL, model: dot ? "Dot" : "Pro",
      firmware: fields[dot ? "app_version" : "release_version"]!, serial: fields["serial"] ?? "")
  }
  public static func discover() -> [Device] {
    let roots =
      (try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
    return roots.compactMap { try? inspect($0) }.sorted { $0.id < $1.id }
  }
  public func write(_ source: String) throws {
    let program = try Programs.normalize(source)
    let digest = SHA256.hash(data: Data(root.resolvingSymlinksInPath().path.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let lock = Paths.home.appendingPathComponent(".cache/sidepulse/device-locks/" + digest)
    try withLock(lock) {
      guard try Device.inspect(root) == self else {
        throw PulseError("The device changed before the write.")
      }
      let url = root.appendingPathComponent("LEDS.LED")
      let fd = open(url.path, O_NOFOLLOW | O_CREAT | O_TRUNC | O_WRONLY, 0o600)
      if fd < 0 {
        let failure = errno
        guard [EROFS, EACCES, EPERM].contains(failure),
          firmware.compare("1.1.0", options: .numeric) != .orderedAscending
        else {
          throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        if model == "Pro" {
          try ReadChannel.upload(Array(program.utf8), root: root)
        } else {
          try DotChannel.upload(Array(program.utf8), root: root)
        }
        return
      }
      let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try file.write(contentsOf: Data(program.utf8))
      try file.synchronize()
      try file.close()
    }
  }
}

public enum Programs {
  public static func normalize(_ source: String) throws -> String {
    let text = source.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 512, text.components(separatedBy: "\n").count <= 20,
      !text.contains("\0")
    else {
      throw PulseError("LED programs must contain 1–512 bytes and at most 20 lines.")
    }
    return text
  }
  public static var animationNames: [String] {
    ((try? FileManager.default.contentsOfDirectory(
      atPath: Bundle.module.resourceURL!.appendingPathComponent("animations").path)) ?? [])
      .filter { $0.hasSuffix(".LED") }.map { String($0.dropLast(4)) }.sorted()
  }
  public static func preset(_ name: String, count: Int) throws -> String {
    guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
      throw PulseError("Invalid animation name.")
    }
    for key in ["\(name)-\(count)", name] {
      if let url = Bundle.module.url(
        forResource: key, withExtension: "LED", subdirectory: "animations")
      {
        return try normalize(String(contentsOf: url, encoding: .utf8))
      }
    }
    throw PulseError("Unknown animation: \(name)")
  }
  public static func profile(_ name: String) throws -> [String: String] {
    guard ["cyan", "ember", "purple"].contains(name),
      let file = Bundle.module.url(
        forResource: name, withExtension: "json", subdirectory: "profiles"),
      let mapping = try object(file)["animations"] as? [String: String]
    else { throw PulseError("Unknown profile.") }
    return mapping
  }
  public static func program(_ mode: Mode, count: Int, settings: JSONObject) throws -> String {
    let entry = (settings["agent_animations"] as? [String: JSONObject])?[mode.rawValue]
    let style = entry?["style"] as? String
    if let style, let entry,
      let program = try? resolve(style: style, entry: entry, count: count, settings: settings)
    {
      return program
    }
    let mapping = try profile("cyan")
    return try preset(mapping[mode.rawValue] ?? "idle-pulse", count: count)
  }
  static func resolve(style: String, entry: JSONObject, count: Int, settings: JSONObject) throws
    -> String
  {
    if let inline = entry["custom_program"] as? String, !inline.isEmpty {
      return try normalize(inline)
    }
    if let program = (settings["custom_agent_animations"] as? [String: JSONObject])?[style]?[
      "program"] as? String
    {
      return try normalize(program)
    }
    if style.hasPrefix("custom:"),
      let item = (settings["custom_agent_animations"] as? [String: JSONObject])?[style],
      let file = item["file"] as? String, file == URL(fileURLWithPath: file).lastPathComponent
    {
      for base in [Paths.support, Paths.legacyConfig] {
        if let text = try? String(
          contentsOf: base.appendingPathComponent("animations/" + file), encoding: .utf8)
        {
          return try normalize(text)
        }
      }
    }
    return try preset(style, count: count)
  }
  public static func dim(_ source: String, brightness: Int) -> String {
    let scale = max(0, min(255, brightness))
    guard scale < 255 else { return source }
    let regex = try! NSRegularExpression(pattern: "#[A-Fa-f0-9]{6}")
    let result = NSMutableString(string: source)
    for match in regex.matches(in: source, range: NSRange(location: 0, length: result.length))
      .reversed()
    {
      let color = (result.substring(with: match.range) as NSString)
      let rgb = [1, 3, 5].map {
        Int(color.substring(with: NSRange(location: $0, length: 2)), radix: 16)! * scale / 255
      }
      result.replaceCharacters(
        in: match.range, with: String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2]))
    }
    return result as String
  }
}

/// The same bytecode shipped with the device simulator validates and renders the LED language.
public final class LEDPreview {
  private let context: JSContext
  private let count: Int
  public init(program: String, count: Int) throws {
    self.count = count == 2 ? 2 : 8
    guard let ctx = JSContext(),
      let url = Bundle.module.url(forResource: "sdled", withExtension: "wasm")
    else { throw PulseError("Missing LED simulator.") }
    context = ctx
    ctx.setObject([UInt8](try Data(contentsOf: url)), forKeyedSubscript: "moduleBytes" as NSString)
    ctx.setObject(
      [UInt8](try Programs.normalize(program).utf8), forKeyedSubscript: "programBytes" as NSString)
    ctx.setObject(self.count, forKeyedSubscript: "ledCount" as NSString)
    let packed =
      ctx.evaluateScript(
        """
        var engine = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(moduleBytes))).exports;
        engine.sdled_reset(ledCount,0);
        new Uint8Array(engine.memory.buffer,engine.sdled_input_ptr(),512).set(programBytes);
        engine.sdled_parse(ledCount,programBytes.length,0);
        """)?.toUInt32() ?? 0
    guard ctx.exception == nil, packed & 1 != 0 else {
      throw PulseError("LED syntax error at line \((packed >> 16) & 255), column \(packed >> 24).")
    }
  }
  public func frame(milliseconds: Int) -> [UInt8] {
    context.setObject(max(0, milliseconds), forKeyedSubscript: "now" as NSString)
    let result = context.evaluateScript(
      "engine.sdled_step(ledCount,now); Array.from(new Uint8Array(engine.memory.buffer,engine.sdled_output_ptr(),ledCount*3))"
    )
    return (result?.toArray() as? [NSNumber] ?? []).map(\.uint8Value)
  }
}

public struct Battery {
  public let percent: Int, charging: Bool, plugged: Bool, watts: Int
  public static func read() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in list {
      guard
        let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? JSONObject,
        data["Type"] as? String == "InternalBattery",
        let capacity = data["Current Capacity"] as? Int,
        let maxCapacity = data["Max Capacity"] as? Int, maxCapacity > 0
      else { continue }
      return Battery(
        percent: min(100, max(0, capacity * 100 / maxCapacity)),
        charging: data["Is Charging"] as? Bool == true,
        plugged: data["Power Source State"] as? String == "AC Power",
        watts: (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? JSONObject)?["Watts"]
          as? Int ?? 0)
    }
    return nil
  }
  public func program(count: Int) -> String {
    let fill = Double(percent * count) / 100
    let full = Int(fill)
    let color =
      charging ? "#80FFC8" : percent < 20 ? "#FF2600" : percent < 50 ? "#FFB000" : "#00FF66"
    var program = (0..<count).map { i in
      let scale = Int(255 * max(0, min(1, fill - Double(i))))
      return "\(i):\(Programs.dim(color,brightness:scale)) 360ms ease"
    }.joined(separator: ";")
    if charging && percent < 100 {
      let duration = max(300, 1600 - min(100, watts) * 11)
      program += "\n\(min(count-1,full)):#80FFC8 \(duration)ms pulse\nrepeat"
    }
    return program
  }
}
