import CoreGraphics
import Foundation
import IOKit

public enum Power {
  public static func lidClosed() -> Bool? { flag("AppleClamshellState") }
  static func flag(_ key: String) -> Bool? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    return IORegistryEntryCreateCFProperty(entry, key as CFString, nil, 0)?.takeRetainedValue()
      as? Bool
  }
  static func externalDisplay() -> Bool? {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
  }
}

/// Use only the two pmset commands authorized by the optional admin-installed helper.
/// Remember ownership before changing the setting so a restarted app can restore it.
public final class SleepOverride {
  private var grace = Date.distantPast
  private var lastMode = Mode.unknown
  private var lastLid: Bool?
  private let marker = Paths.support.appendingPathComponent("owns-disablesleep")
  private var requested: Bool?
  public init() {}
  public func update(mode: Mode, settings: JSONObject, battery: Battery?, owner: Bool) throws {
    let policy = settings["swift_closed_lid"] as? String ?? "never"
    if lastMode != mode {
      if [.done, .blocked, .waiting].contains(mode) {
        grace = Date().addingTimeInterval(300)
      } else {
        grace = .distantPast
      }
      lastMode = mode
    }
    let minimum =
      (settings["sleep_prevention"] as? JSONObject)?["min_battery_percent"] as? Int ?? 20
    let safeBattery = battery.map { $0.plugged || $0.percent >= minimum } ?? true
    let wanted =
      owner && safeBattery
      && (policy == "always"
        || (policy == "agents" && ([.working, .tool, .progress].contains(mode) || Date() < grace)))
    if requested != wanted {
      if wanted {
        guard FileManager.default.fileExists(atPath: "/etc/sudoers.d/sidepulse-swift-disablesleep")
        else {
          requested = false
          throw PulseError(
            "Install the optional sleep helper before enabling closed-lid operation.")
        }
        guard let disabled = Power.flag("SleepDisabled") else {
          throw PulseError("Cannot determine the macOS sleep state.")
        }
        if !disabled {
          try Paths.directory(Paths.support)
          try Data().write(to: marker, options: .atomic)
          try SystemCommand.run(
            "/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        }
      } else {
        try restore()
      }
      requested = wanted
    }
    let lid = Power.lidClosed()
    if wanted, lastLid == false, lid == true, Power.externalDisplay() == false {
      try SystemCommand.run("/usr/bin/pmset", ["displaysleepnow"])
    }
    lastLid = lid
  }
  public func restore() throws {
    guard FileManager.default.fileExists(atPath: marker.path) else { return }
    try SystemCommand.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    try FileManager.default.removeItem(at: marker)
  }
}
