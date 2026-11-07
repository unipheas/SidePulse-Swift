import XCTest

@testable import PulseCore

final class HardwareTests: IsolatedTests {
  func testFirmwareDownloadVerificationAndTransferAgainstSimulatedVolume() async throws {
    let device = try volume()
    let zip = root.appendingPathComponent("sidepulse-pro-1.1.0-ota.zip")
    let payload = Data([0x10, 0x22, 0x41])
    let documents = [
      "FIRMWARE.BIN": payload,
      "README.txt": Data("SidePulse Pro firmware update - version 1.1.0\n".utf8),
      "RELEASE_NOTES.txt": Data("Fixture release".utf8),
    ]
    let entries = documents.keys.sorted()
    for (key, data) in documents { try data.write(to: root.appendingPathComponent(key)) }
    let sum = entries.map { Firmware.digest(documents[$0]!) + "  " + $0 }.joined(separator: "\n")
    try Data(sum.utf8).write(to: root.appendingPathComponent("SHA256SUMS.txt"))
    try SystemCommand.run(
      "/usr/bin/zip",
      ["-jq", zip.path]
        + (entries + ["SHA256SUMS.txt"]).map { root.appendingPathComponent($0).path })
    let archive = try Data(contentsOf: zip)
    func download(_ address: String) throws -> Data {
      if address.contains("api.github.com") {
        return Data(#"[{"name":"v1.1.0"},{"name":"README"}]"#.utf8)
      }
      if address.hasSuffix("SHA256SUMS.txt") {
        return Data((Firmware.digest(archive) + "  " + zip.lastPathComponent).utf8)
      }
      return archive
    }
    let dry = try await Firmware.upgrade(
      device, version: nil, file: nil, dryRun: true, fetch: download)
    XCTAssertTrue(dry.contains("dry run"))
    let target = device.root.appendingPathComponent("FIRMWARE.BIN")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    let message = try await Firmware.upgrade(device, version: nil, file: zip.path, dryRun: false)
    XCTAssertTrue(message.contains("transferred"))
    XCTAssertEqual(try Data(contentsOf: target), payload)
    try Data("corrupted".utf8).write(to: root.appendingPathComponent("FIRMWARE.BIN"))
    try SystemCommand.run(
      "/usr/bin/zip", ["-jq", zip.path, root.appendingPathComponent("FIRMWARE.BIN").path])
    XCTAssertThrowsError(try Firmware.verifyZIP(zip, device: device))
  }

  func testDotAcknowledgementRequiresMatchingTransactionLengthAndCounter() throws {
    func ack(_ id: UInt16, state: UInt8, count: UInt8, applied: UInt16) -> [UInt8] {
      let word: (UInt16) -> [UInt8] = { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
      return Array("SPC2".utf8) + word(id) + [state, 0, count, 0, count, 0] + word(applied) + [
        0, 0,
      ]
    }
    let body = Array("off".utf8)
    for count in [2, 3] {
      var current: UInt16?
      var sent = 0
      var reads = 0
      func transfer() throws {
        try DotChannel.upload(
          body,
          readStatus: {
            reads += 1
            guard let current else { return ack(1, state: 0, count: 0, applied: .max) }
            return ack(current, state: reads == 2 ? 2 : 3, count: UInt8(count), applied: 0)
          },
          submit: { id, data in
            current = id
            sent += 1
            XCTAssertEqual(data, body)
          }, wait: {})
      }
      if count == 3 {
        XCTAssertNoThrow(try transfer())
      } else {
        XCTAssertThrowsError(try transfer())
      }
      XCTAssertEqual(sent, 1)
    }
    XCTAssertThrowsError(
      try DotChannel.upload(body, readStatus: { [] }, submit: { _, _ in XCTFail() }))
    XCTAssertThrowsError(
      try DotChannel.upload(
        body, readStatus: { ack(0, state: 2, count: 0, applied: 0) }, submit: { _, _ in XCTFail() })
    )
    var time = 0.0
    XCTAssertThrowsError(
      try DotChannel.upload(
        body, readStatus: { ack(0, state: 0, count: 0, applied: 0) }, submit: { _, _ in },
        uptime: { time }, wait: { time += 1 }))
  }
  func testProControlSectorRejectsBadSignaturesAndChecksums() throws {
    var decoded = [UInt8](repeating: 0, count: 64)
    decoded.replaceSubrange(0..<8, with: "READ2ME1".utf8)
    decoded[8] = 1
    decoded.replaceSubrange(
      62..<64, with: ReadChannel.bytes(ReadChannel.crc(Array(decoded.prefix(62)))))
    func sector(_ data: [UInt8]) -> [UInt8] {
      var sector = [UInt8](repeating: 0, count: 512)
      let text = Array(
        ("<!--READ2ME1:" + data.map { String(format: "%02X", $0) }.joined() + "-->\n").utf8)
      sector.replaceSubrange(256..<(256 + text.count), with: text)
      return sector
    }
    XCTAssertEqual(try ReadChannel.Status(sector(decoded)).data, decoded)
    decoded[8] = 2
    XCTAssertThrowsError(try ReadChannel.Status(sector(decoded)))
    XCTAssertThrowsError(try ReadChannel.Status([]))
    XCTAssertThrowsError(try ReadChannel.upload([1], root: root))
    XCTAssertThrowsError(try DotChannel.upload([1], root: root))
    XCTAssertThrowsError(try RawDisk.write(path: "/tmp/disk", program: "off", dryRun: false))
  }
}

extension HardwareTests {
  func testClosedLidPolicyHonorsOwnershipBatteryGraceAndExternalDisplays() throws {
    var now = Date()
    var lid = false
    var externalDisplay = false
    var disabled: Bool? = false
    var changes = [Bool]()
    var slept = 0
    var installed = false
    let system = SleepOverride.System(
      now: { now }, helperInstalled: { installed }, disabled: { disabled },
      lidClosed: { lid }, externalDisplay: { externalDisplay }, disable: { changes.append($0) },
      sleepDisplay: { slept += 1 })
    let policy = SleepOverride(system: system)
    let settings: JSONObject = ["swift_closed_lid": "agents"]
    func update(_ mode: Mode, percent: Int = 100, owner: Bool = true) throws {
      try policy.update(
        mode: mode, settings: settings,
        battery: Battery(percent: percent, charging: false, plugged: false, watts: 0), owner: owner)
    }
    XCTAssertThrowsError(try update(.working))
    installed = true
    disabled = nil
    XCTAssertThrowsError(try update(.working))
    disabled = false
    try update(.working, percent: 5)
    try update(.working, owner: false)
    XCTAssertTrue(changes.isEmpty)
    try update(.working)
    lid = true
    try update(.tool)
    XCTAssertEqual(slept, 1)
    lid = false
    try update(.working)
    externalDisplay = true
    lid = true
    try update(.done)
    XCTAssertEqual(slept, 1)
    now.addTimeInterval(301)
    try update(.done)
    XCTAssertEqual(changes, [true, false])
    disabled = true
    try update(.working)
    try policy.restore()
    XCTAssertEqual(
      changes, [true, false], "An existing system override belongs to its original owner.")
  }
}

extension HardwareTests {
  func testReadChannelNegotiationAndAcknowledgement() throws {
    let payload = Array("off".utf8)
    var symbols = [Int]()
    var statusReads = 0
    func status() throws -> ReadChannel.Status {
      statusReads += 1
      var bytes = [UInt8](repeating: 0, count: 64)
      bytes.replaceSubrange(0..<8, with: "READ2ME1".utf8)
      bytes[8] = 1
      func word(_ value: UInt32, at: Int) {
        bytes.replaceSubrange(at..<at + 4, with: ReadChannel.bytes(value))
      }
      word(512, at: 40)
      if symbols.count >= 7 {
        word(7, at: 32)
        word(1, at: 50)
      }
      if symbols.count > 7 {
        let nibbles = Array(
          symbols.dropFirst(7 + ReadChannel.start.count).dropLast(ReadChannel.end.count))
        let decoded = stride(from: 0, to: nibbles.count, by: 2).map {
          UInt8(nibbles[$0] * 16 + nibbles[$0 + 1])
        }
        bytes.replaceSubrange(12..<16, with: decoded[1..<5])
        bytes[9] = 3
        word(UInt32(payload.count), at: 16)
        word(UInt32(payload.count), at: 20)
        bytes.replaceSubrange(44..<46, with: ReadChannel.bytes(ReadChannel.crc(payload)))
      }
      bytes.replaceSubrange(
        62..<64, with: ReadChannel.bytes(ReadChannel.crc(Array(bytes.prefix(62)))))
      var sector = [UInt8](repeating: 0, count: 512)
      let text = Array(
        ("<!--READ2ME1:" + bytes.map { String(format: "%02x", $0) }.joined() + "-->\n").utf8)
      sector.replaceSubrange(256..<256 + text.count, with: text)
      return try ReadChannel.Status(sector)
    }
    try ReadChannel.upload(payload, read: { symbols.append($0) }, status: status, wait: {})
    XCTAssertEqual(Array(symbols.prefix(7)), ReadChannel.start + [16])
    XCTAssertEqual(statusReads, 3)
    XCTAssertThrowsError(
      try ReadChannel.upload([], read: { _ in XCTFail() }, status: status, wait: {}))
    symbols = []
    var time = 0.0
    XCTAssertThrowsError(
      try ReadChannel.upload(
        payload, read: { _ in }, status: status, uptime: { time }, wait: { time += 1 }))
    let stub = root.appendingPathComponent("setup.html")
    try Data(repeating: 0, count: 19 * 512).write(to: stub)
    XCTAssertThrowsError(try ReadChannel.upload(payload, root: root))
  }
}
