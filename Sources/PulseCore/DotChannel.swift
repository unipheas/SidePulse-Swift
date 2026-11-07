import Foundation
import USBControl

enum DotChannel {
  static func upload(
    _ bytes: [UInt8], root: URL,
    connect: (String) -> OpaquePointer? = { pulse_usb_connect($0) }
  ) throws {
    guard let device = connect(root.path) else {
      throw PulseError("Cannot access the selected Dot USB control endpoint.")
    }
    defer { pulse_usb_release(device) }
    try upload(
      bytes,
      readStatus: {
        var raw = [UInt8](repeating: 0, count: 16)
        guard pulse_usb_transfer(device, 0xc0, 0x51, 0, &raw, 16) != 0 else {
          throw PulseError("Cannot read Dot status.")
        }
        return raw
      },
      submit: { id, payload in
        var buffer = payload
        _ = pulse_usb_transfer(device, 0x40, 0x50, id, &buffer, UInt16(buffer.count))
      })
  }
  static func upload(
    _ bytes: [UInt8], readStatus: () throws -> [UInt8], submit: (UInt16, [UInt8]) -> Void,
    uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    wait: () -> Void = { usleep(5000) }
  ) throws {
    guard (1...512).contains(bytes.count) else { throw PulseError("Invalid Dot payload length.") }
    func status() throws -> (id: Int, state: Int, length: Int, received: Int, applied: Int) {
      let raw = try readStatus()
      guard raw.count == 16, raw.prefix(4).elementsEqual("SPC2".utf8), raw[6] <= 5, raw[7] == 0
      else { throw PulseError("Invalid Dot acknowledgement.") }
      func word(_ offset: Int) -> Int { Int(raw[offset]) | (Int(raw[offset + 1]) << 8) }
      return (word(4), Int(raw[6]), word(8), word(10), word(12))
    }
    let before = try status()
    guard before.state != 2 else { throw PulseError("Dot is busy.") }
    var id = UInt16.random(in: 1...UInt16.max)
    while Int(id) == before.id { id = UInt16.random(in: 1...UInt16.max) }
    // Even a failed OUT may have reached firmware. Reconcile this ID without replay.
    submit(id, bytes)
    let deadline = uptime() + 2
    repeat {
      let ack = try status()
      if ack.id == Int(id) && ![1, 2].contains(ack.state) {
        guard ack.state == 3, ack.length == bytes.count, ack.received == bytes.count,
          ack.applied == (before.applied + 1) % 65536
        else {
          throw PulseError("Dot did not confirm the full LED program.")
        }
        return
      }
      wait()
    } while uptime() < deadline
    throw PulseError("Dot write acknowledgement timed out.")
  }
}
