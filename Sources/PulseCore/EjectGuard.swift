import DiskArbitration
import Foundation

public enum EjectGuard {
  public static func run() throws {
    try run(createSession: { DASessionCreate(nil) })
  }
  static func run(
    createSession: () -> DASession?,
    daemonPID: () -> Int? = DiskArbitrationWatch.processID
  ) throws {
    guard let session = createSession() else {
      throw PulseError("Cannot create Disk Arbitration session.")
    }
    let context = GuardContext(session: session)
    var daemon = DiskArbitrationWatch()
    let pointer = Unmanaged.passUnretained(context).toOpaque()
    DARegisterDiskEjectApprovalCallback(
      session, nil,
      { disk, pointer in
        let context = Unmanaged<GuardContext>.fromOpaque(pointer!).takeUnretainedValue()
        return context.approve(disk)
      }, pointer)
    DARegisterDiskDisappearedCallback(
      session, nil,
      { disk, pointer in
        let context = Unmanaged<GuardContext>.fromOpaque(pointer!).takeUnretainedValue()
        if let name = DADiskGetBSDName(disk) { context.forget(String(cString: name)) }
      }, pointer)
    DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    defer {
      DASessionUnscheduleFromRunLoop(
        session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    withExtendedLifetime(context) {
      while !Task.isCancelled {
        // A daemon restart invalidates registered callbacks. Exiting lets the
        // launchd KeepAlive job reconnect with a fresh session, as in the original guard.
        if daemon.changed(to: daemonPID()) { return }
        context.refresh()
        CFRunLoopRunInMode(.defaultMode, 0.5, true)
      }
    }
  }
}

struct DiskArbitrationWatch {
  private var previous: Int?
  static func processID() -> Int? {
    processID(at: URL(fileURLWithPath: "/var/run/diskarbitrationd.pid"))
  }
  static func processID(at file: URL) -> Int? {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
      let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
    else { return nil }
    return pid
  }
  mutating func changed(to pid: Int?) -> Bool {
    guard let pid else { return false }
    defer { previous = pid }
    return previous != nil && previous != pid
  }
}

/// Eject approval arrives after unmount, so retain the physical identity while the
/// card is attached. Volume discovery inside the approval callback is too late.
final class GuardContext {
  let session: DASession
  private var protected = [String: DADisk]()
  private var pending = [String: DADisk]()
  private var nextMount = Date.distantPast
  init(session: DASession) { self.session = session }
  static func builtInSD(_ description: NSDictionary) -> Bool {
    let transport = description[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
    let model = description[kDADiskDescriptionDeviceModelKey] as? String ?? ""
    return transport.contains("Secure Digital") || model.contains("SDXC")
  }
  func refresh(discover: () -> [Device] = Device.discover) {
    for device in discover() where device.model == "Pro" {
      guard let disk = DADiskCreateFromVolumePath(nil, session, device.root as CFURL),
        let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole)
      else { continue }
      protected[String(cString: name)] = disk
    }
    guard !pending.isEmpty, Date() >= nextMount else { return }
    nextMount = Date().addingTimeInterval(1)
    for (name, disk) in pending {
      if let description = DADiskCopyDescription(disk) as NSDictionary?,
        description[kDADiskDescriptionVolumePathKey] != nil
      {
        pending[name] = nil
      } else {
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), nil, nil)
      }
    }
  }
  func approve(_ disk: DADisk) -> Unmanaged<DADissenter>? {
    let whole = DADiskCopyWholeDisk(disk) ?? disk
    guard let rawName = DADiskGetBSDName(whole) else { return nil }
    let name = String(cString: rawName)
    let description = DADiskCopyDescription(whole) as NSDictionary? ?? [:]
    guard protected[name] != nil || Self.builtInSD(description) else { return nil }
    pending[name] = protected[name] ?? disk
    return Unmanaged.passRetained(
      DADissenterCreate(
        nil, DAReturn(kDAReturnNotPermitted), "SidePulse is protecting the Pro card" as CFString))
  }
  func forget(_ name: String) {
    protected[name] = nil
    pending[name] = nil
  }
}
