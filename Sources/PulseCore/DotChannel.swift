import Foundation
import USBControl

enum DotChannel {
  static func upload(_ bytes: [UInt8], root: URL) throws {
    guard let device = pulse_usb_connect(root.path) else {
      throw PulseError("Cannot access the selected Dot USB control endpoint.")
    }
    defer { pulse_usb_release(device) }
    func status() throws -> (id: Int, state: Int, length: Int, received: Int, applied: Int) {
      var raw = [UInt8](repeating: 0, count: 16)
      guard pulse_usb_transfer(device, 0xc0, 0x51, 0, &raw, 16) != 0,
        raw.prefix(4).elementsEqual("SPC2".utf8),
        raw[6] <= 5, raw[7] == 0
      else { throw PulseError("Invalid Dot acknowledgement.") }
      func word(_ offset: Int) -> Int { Int(raw[offset]) | (Int(raw[offset + 1]) << 8) }
      return (word(4), Int(raw[6]), word(8), word(10), word(12))
    }
    let before = try status()
    guard before.state != 2 else { throw PulseError("Dot is busy.") }
    var id = UInt16.random(in: 1...UInt16.max)
    while Int(id) == before.id { id = UInt16.random(in: 1...UInt16.max) }
    var payload = bytes
    // Even a failed OUT may have reached firmware. Reconcile this ID without replay.
    _ = pulse_usb_transfer(device, 0x40, 0x50, id, &payload, UInt16(bytes.count))
    let deadline = ProcessInfo.processInfo.systemUptime + 2
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
      usleep(5000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw PulseError("Dot write acknowledgement timed out.")
  }
}
