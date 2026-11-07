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
  private var lease: Int32 = -1
  deinit { if lease >= 0 { close(lease) } }
  struct System {
    var now: () -> Date = Date.init
    var helperInstalled = {
      FileManager.default.fileExists(atPath: "/etc/sudoers.d/sidepulse-swift-disablesleep")
    }
    var disabled = { Power.flag("SleepDisabled") }
    var lidClosed = Power.lidClosed
    var externalDisplay = Power.externalDisplay
    var disable: (Bool) throws -> Void = { value in
      try SystemCommand.run(
        "/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value ? "1" : "0"])
    }
    var sleepDisplay: () throws -> Void = {
      try SystemCommand.run("/usr/bin/pmset", ["displaysleepnow"])
    }
  }
  private let system: System
  public convenience init() { self.init(system: System()) }
  init(system: System) { self.system = system }
  public func update(mode: Mode, settings: JSONObject, battery: Battery?, owner: Bool) throws {
    // A preview window must never restore a sleep override owned by the service.
    // The advisory lease is released by the kernel after a crash; a new writer can
    // then recover the persistent marker left by the previous process.
    if !owner {
      if lease >= 0 {
        try restore()
        close(lease)
        lease = -1
        requested = nil
      }
      return
    }
    if lease < 0 {
      try Paths.directory(Paths.support)
      let fd = open(
        Paths.support.appendingPathComponent("sleep-owner.lock").path,
        O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw POSIXError(.EACCES) }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return
      }
      lease = fd
    }
    let policy = settings["swift_closed_lid"] as? String ?? "never"
    if lastMode != mode {
      if [.done, .blocked, .waiting].contains(mode) {
        grace = system.now().addingTimeInterval(300)
      } else {
        grace = .distantPast
      }
      lastMode = mode
    }
    let minimum =
      (settings["sleep_prevention"] as? JSONObject)?["min_battery_percent"] as? Double ?? 20
    let safeBattery = battery.map { $0.plugged || Double($0.percent) >= minimum } ?? true
    let wanted =
      owner && safeBattery
      && (policy == "always"
        || (policy == "agents"
          && ([.working, .tool, .progress].contains(mode) || system.now() < grace)))
    if requested != wanted {
      if wanted {
        guard system.helperInstalled()
        else {
          requested = false
          throw PulseError(
            "Install the optional sleep helper before enabling closed-lid operation.")
        }
        guard let disabled = system.disabled() else {
          throw PulseError("Cannot determine the macOS sleep state.")
        }
        if !disabled {
          try Paths.directory(Paths.support)
          try Data().write(to: marker, options: .atomic)
          try system.disable(true)
        }
      } else {
        try restore()
      }
      requested = wanted
    }
    let lid = system.lidClosed()
    if wanted, lastLid == false, lid == true, system.externalDisplay() == false {
      try system.sleepDisplay()
    }
    lastLid = lid
  }
  public func restore() throws {
    guard lease >= 0, FileManager.default.fileExists(atPath: marker.path) else { return }
    try system.disable(false)
    try FileManager.default.removeItem(at: marker)
  }
}
