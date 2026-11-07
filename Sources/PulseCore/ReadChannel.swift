import Darwin
import Foundation

/// SidePulse Pro READ2ME v1: addresses encode nibbles; ordinary buffered reads do not.
enum ReadChannel {
  static let start = [16, 16, 1, 2, 3, 4], end = [17, 17, 4, 3, 2, 1]
  static func crc(_ data: [UInt8]) -> UInt16 {
    var value: UInt16 = 0xffff
    for byte in data {
      value ^= UInt16(byte) << 8
      for _ in 0..<8 { value = value & 0x8000 == 0 ? value << 1 : (value << 1) ^ 0x1021 }
    }
    return value
  }
  static func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian, Array.init)
  }
  static func frame(id: UInt32, payload: [UInt8]) -> [Int] {
    let name = Array("LEDS.LED".utf8)
    var packet: [UInt8] = [1]
    packet += bytes(id)
    packet += [UInt8(name.count)] + name
    packet += bytes(UInt32(payload.count))
    packet += bytes(UInt32(0))
    packet += bytes(UInt16(payload.count))
    packet += payload
    packet += bytes(crc(packet))
    return start + packet.flatMap { [Int($0 >> 4), Int($0 & 15)] } + end
  }
  struct Status {
    let data: [UInt8]
    func word(_ offset: Int, _ size: Int = 4) -> UInt32 {
      data[offset..<(offset + size)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    init(_ sector: [UInt8]) throws {
      let prefix = Array("<!--READ2ME1:".utf8)
      let offset = 256 + prefix.count
      guard sector.count == 512, sector[256..<offset].elementsEqual(prefix),
        sector[(offset + 128)..<(offset + 132)].elementsEqual("-->\n".utf8)
      else { throw PulseError("Missing READ2ME status envelope.") }
      var decoded = [UInt8]()
      for i in stride(from: offset, to: offset + 128, by: 2) {
        guard let byte = UInt8(String(decoding: sector[i..<i + 2], as: UTF8.self), radix: 16) else {
          throw PulseError("Invalid status encoding.")
        }
        decoded.append(byte)
      }
      data = decoded
      guard decoded.prefix(8).elementsEqual("READ2ME1".utf8), decoded[8] == 1, decoded[9] <= 4,
        decoded[10] <= 8, decoded[11] <= 2,
        UInt32(ReadChannel.crc(Array(decoded.prefix(62)))) == word(62, 2)
      else { throw PulseError("Invalid READ2ME status checksum or version.") }
    }
  }
  static func upload(_ payload: [UInt8], root: URL) throws {
    let file = root.appendingPathComponent("setup.html")
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw PulseError("Cannot open the Pro read channel.") }
    defer { close(fd) }
    let size = 19 * 512
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size == size,
      fcntl(fd, F_NOCACHE, 1) == 0, fcntl(fd, F_RDAHEAD, 0) == 0,
      let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED
    else { throw PulseError("Cannot configure uncached reads.") }
    defer { munmap(map, size) }
    var buffer: UnsafeMutableRawPointer?
    guard posix_memalign(&buffer, Int(getpagesize()), Int(getpagesize())) == 0, let buffer else {
      throw PulseError("Cannot allocate aligned buffer.")
    }
    defer { free(buffer) }
    func read(_ sector: Int) throws {
      guard msync(map, size, MS_INVALIDATE) == 0, pread(fd, buffer, 512, off_t(sector * 512)) == 512
      else { throw PulseError("Incomplete control-sector read.") }
    }
    func status() throws -> Status {
      try read(18)
      return try Status(Array(UnsafeRawBufferPointer(start: buffer, count: 512)))
    }
    let initial = try status()
    guard initial.data[9] != 2, !payload.isEmpty, payload.count <= 512,
      payload.count <= Int(initial.word(40))
    else { throw PulseError("Pro is busy or its read channel has insufficient capacity.") }
    for symbol in start + [16] { try read(symbol) }
    var deadline = ProcessInfo.processInfo.systemUptime + 1
    while true {
      let check = try status()
      let delta = check.word(32) &- initial.word(32)
      if delta == 7 && check.word(50) != initial.word(50) { break }
      guard delta <= 7, ProcessInfo.processInfo.systemUptime < deadline else {
        throw PulseError("Control-sector probe failed.")
      }
      usleep(10000)
    }
    var id = UInt32.random(in: 1...UInt32.max)
    while id == initial.word(12) { id = UInt32.random(in: 1...UInt32.max) }
    for symbol in frame(id: id, payload: payload) { try read(symbol) }
    deadline = ProcessInfo.processInfo.systemUptime + 3
    repeat {
      let ack = try status()
      if ack.word(12) == id, ack.data[11] == 0, ack.data[9] == 3, ack.data[10] == 0,
        ack.word(16) == payload.count, ack.word(20) == payload.count,
        ack.word(44, 2) == UInt32(crc(payload))
      {
        return
      }
      usleep(10000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw PulseError("The Pro did not acknowledge the LED program.")
  }
}
