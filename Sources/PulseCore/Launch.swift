import DiskArbitration
import Foundation

public enum Jobs {
  public static let prefix = "com.unipheas.SidePulseSwift."
  static var domain: String { "gui/\(getuid())" }
  static func plist(_ label: String) -> URL {
    Paths.home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
  }
  public static func running(_ label: String) -> Bool {
    (try? SystemCommand.run("/bin/launchctl", ["print", domain + "/" + label])) != nil
  }
  public static func configure(_ job: String, executable: URL, start: Bool) throws {
    guard ["service", "sdejectguard"].contains(job) else { throw PulseError("Unknown job.") }
    let label = prefix + job
    let file = plist(label)
    if running(label) {
      try SystemCommand.run("/bin/launchctl", ["bootout", domain + "/" + label])
    }
    if start {
      try Paths.directory(file.deletingLastPathComponent())
      let config: JSONObject = [
        "Label": label, "ProgramArguments": [executable.path, job, "run"], "RunAtLoad": true,
        "KeepAlive": true, "ThrottleInterval": 10,
      ]
      try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(
        to: file, options: .atomic)
      try SystemCommand.run("/bin/launchctl", ["bootstrap", domain, file.path])
    } else if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
  public static func takeControl() throws {
    var stopped = [String]()
    do {
      for label in ["io.sidepulse.agentstatus", "io.sidepulse.service"] where running(label) {
        guard FileManager.default.fileExists(atPath: plist(label).path) else {
          throw PulseError("Cannot locate existing login job.")
        }
        try SystemCommand.run("/bin/launchctl", ["bootout", domain + "/" + label])
        stopped.append(label)
      }
      try Settings.update {
        $0["swift_paused_jobs"] = stopped
        $0["swift_mirror"] = true
      }
    } catch {
      for label in stopped { try? resume(label) }
      throw error
    }
  }
  private static func resume(_ label: String) throws {
    guard ["io.sidepulse.agentstatus", "io.sidepulse.service"].contains(label) else {
      throw PulseError("Unknown login job.")
    }
    if !running(label) {
      try SystemCommand.run("/bin/launchctl", ["bootstrap", domain, plist(label).path])
    }
  }
  public static func giveBack() throws {
    let labels = try Settings.read()["swift_paused_jobs"] as? [String] ?? []
    for label in labels.reversed() { try resume(label) }
    try Settings.update { $0.removeValue(forKey: "swift_paused_jobs") }
  }
}

public enum EjectGuard {
  public static func run() throws {
    guard let session = DASessionCreate(nil) else {
      throw PulseError("Cannot create Disk Arbitration session.")
    }
    DARegisterDiskEjectApprovalCallback(
      session, nil,
      { disk, _ in
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        guard let rawName = DADiskGetBSDName(whole) else { return nil }
        let name = String(cString: rawName)
        for device in Device.discover() where device.model == "Pro" {
          guard let check = DASessionCreate(nil),
            let mounted = DADiskCreateFromVolumePath(nil, check, device.root as CFURL),
            let parent = DADiskCopyWholeDisk(mounted), let bsd = DADiskGetBSDName(parent),
            String(cString: bsd) == name
          else { continue }
          return Unmanaged.passRetained(
            DADissenterCreate(
              nil, DAReturn(kDAReturnNotPermitted),
              "SidePulse is protecting the Pro card" as CFString))
        }
        return nil
      }, nil)
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    withExtendedLifetime(session) { CFRunLoopRun() }
  }
}
