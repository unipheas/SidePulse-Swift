import Foundation

/// Avoid restarting an unchanged animation, and back off failed transports until retry time.
public final class ProgramOutput {
  private var sent = [String: (device: Device, program: String)]()
  private var failed = [String: (device: Device, program: String, retryAfter: Date)]()
  private let now: () -> Date
  private let write: (Device, String) throws -> Void
  public init(
    now: @escaping () -> Date = Date.init,
    write: @escaping (Device, String) throws -> Void = { try $0.write($1) }
  ) {
    self.now = now
    self.write = write
  }
  public func retain(_ devices: [Device]) {
    sent = sent.filter { key, _ in devices.contains { $0.id == key } }
    failed = failed.filter { key, _ in devices.contains { $0.id == key } }
  }
  public func forget(_ id: String) {
    sent[id] = nil
    failed[id] = nil
  }
  public func send(_ program: String, to device: Device) throws {
    if let previous = sent[device.id], previous.device == device, previous.program == program {
      return
    }
    if let failure = failed[device.id], failure.device == device,
      failure.program == program, now() < failure.retryAfter
    {
      return
    }
    failed[device.id] = (device, program, now().addingTimeInterval(10))
    // A failed partial write can have changed the LEDs, so no prior program remains confirmed.
    sent[device.id] = nil
    try write(device, program)
    failed[device.id] = nil
    sent[device.id] = (device, program)
  }
}
