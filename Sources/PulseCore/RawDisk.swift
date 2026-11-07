import Darwin
import Foundation
import USBControl

public enum RawDisk {
  struct Layout: Equatable { let data: Int, directory: Int, entry: Int }
  static func layout(_ disk: [UInt8]) throws -> Layout {
    guard disk.count >= 512, disk.count <= 300000 else {
      throw PulseError("Expected a FAT12 volume of at most 300,000 bytes.")
    }
    func word(_ offset: Int, _ count: Int = 2) -> Int {
      (0..<count).reduce(0) { $0 | (Int(disk[offset + $1]) << ($1 * 8)) }
    }
    let clusterSize = word(13, 1)
    let reserved = word(14)
    let fat = word(22)
    let entries = word(17)
    let total = word(19) == 0 ? word(32, 4) : word(19)
    let root = reserved + fat
    let data = root + (entries * 32 + 511) / 512
    guard disk[510...511].elementsEqual([85, 170]), word(11) == 512, disk[16] == 1,
      word(28, 4) == 0,
      [1, 2, 4, 8, 16, 32, 64, 128].contains(clusterSize), reserved > 0, entries > 0, fat > 0,
      total > data, total * 512 <= disk.count
    else { throw PulseError("Invalid FAT12 geometry.") }
    let clusters = (total - data) / clusterSize
    guard (1..<4085).contains(clusters), ((clusters + 2) * 3 + 1) / 2 <= fat * 512 else {
      throw PulseError("Invalid allocation table.")
    }
    for i in 0..<entries {
      let pos = root * 512 + i * 32
      if disk[pos] == 0 { break }
      guard disk[pos..<pos + 11].elementsEqual("LEDS    LED".utf8), disk[pos + 11] & 0x18 == 0
      else { continue }
      let cluster = word(pos + 26)
      guard disk[pos + 11] & 1 == 0, (2..<clusters + 2).contains(cluster) else {
        throw PulseError("Invalid or read-only LEDS.LED entry.")
      }
      let packed = word(reserved * 512 + cluster + cluster / 2)
      let next = (packed >> (cluster % 2 == 1 ? 4 : 0)) & 0xfff
      guard next >= 0xff8 || ((2..<clusters + 2).contains(next) && next != cluster) else {
        throw PulseError("Unallocated LEDS.LED cluster.")
      }
      return Layout(
        data: (data + (cluster - 2) * clusterSize) * 512, directory: pos / 512 * 512,
        entry: pos % 512)
    }
    throw PulseError("Expected an existing LEDS.LED in the root directory.")
  }
  public static func write(path: String, program: String, dryRun: Bool) throws {
    guard path.range(of: #"^/dev/r?disk[0-9]+$"#, options: .regularExpression) != nil else {
      throw PulseError("Select an unmounted whole /dev/diskN or /dev/rdiskN.")
    }
    let payload = Array(try Programs.normalize(program).utf8)
    let name = path.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
    func verifyMount() throws {
      let response = try SystemCommand.run("/usr/sbin/diskutil", ["info", "-plist", name])
      guard
        let info = try PropertyListSerialization.propertyList(from: response, format: nil)
          as? JSONObject,
        info["WholeDisk"] as? Bool == true, info["DeviceNode"] as? String == name,
        (info["MountPoint"] as? String ?? "").isEmpty
      else { throw PulseError("Unmount the identified whole disk before raw access.") }
    }
    try verifyMount()
    let fd = open(path, (dryRun ? O_RDONLY : O_RDWR) | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
    guard fd >= 0 else { throw PulseError("Cannot open this disk exclusively.") }
    defer { close(fd) }
    let size = Int(pulse_raw_size(fd))
    guard size >= 512, size <= 300000 else {
      throw PulseError("Disk is too large or has unsupported block geometry.")
    }
    var disk = [UInt8](repeating: 0, count: size)
    for offset in stride(from: 0, to: size, by: 512) {
      let n = disk.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress!.advanced(by: offset), 512, off_t(offset))
      }
      guard n == 512 else { throw PulseError("Incomplete disk read.") }
    }
    let loc = try layout(disk)
    if dryRun { return }
    var directory = Array(disk[loc.directory..<loc.directory + 512])
    for i in 0..<4 {
      directory[loc.entry + 28 + i] = UInt8(truncatingIfNeeded: payload.count >> (8 * i))
    }
    for (offset, sector) in [
      (loc.data, payload + Array(repeating: 0, count: 512 - payload.count)),
      (loc.directory, directory),
    ] {
      try verifyMount()
      guard pulse_raw_size(fd) == size, offset >= 0, offset % 512 == 0, offset <= size - 512 else {
        throw PulseError("Disk geometry changed.")
      }
      guard sector.withUnsafeBytes({ pwrite(fd, $0.baseAddress, 512, off_t(offset)) }) == 512,
        fsync(fd) == 0
      else { throw PulseError("Raw write failed. Recheck the device before retrying.") }
    }
  }
}
