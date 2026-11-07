import CoreGraphics
import DiskArbitration
import XCTest

@testable import PulseCore

final class HardwareTests: IsolatedTests {
  func testEjectGuardRecoversWhenDiskArbitrationRestarts() throws {
    let file = root.appendingPathComponent("daemon.pid")
    XCTAssertNil(DiskArbitrationWatch.processID(at: file))
    for text in ["invalid", "0", "-1"] {
      try Data(text.utf8).write(to: file)
      XCTAssertNil(DiskArbitrationWatch.processID(at: file))
    }
    try Data("42\n".utf8).write(to: file)
    XCTAssertEqual(DiskArbitrationWatch.processID(at: file), 42)
    var watch = DiskArbitrationWatch()
    for pid in [nil, 42, nil, 42] { XCTAssertFalse(watch.changed(to: pid)) }
    XCTAssertTrue(watch.changed(to: 43))
    XCTAssertFalse(watch.changed(to: 43))
    var polls = 0
    try EjectGuard.run(
      createSession: { DASessionCreate(nil) },
      daemonPID: {
        polls += 1
        return polls == 1 ? 42 : 43
      })
    XCTAssertEqual(polls, 2, "The service must exit so launchd can reconnect its callbacks")
  }

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
        return Data(#"[{"name":"v1.0.0"},{"name":"v1.1.0"},{"name":"README"}]"#.utf8)
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
    let status = device.root.appendingPathComponent("STATUS.TXT")
    try Data("release_version 2.0.0\nserial fixture\n".utf8).write(to: status)
    do {
      _ = try await Firmware.upgrade(device, version: nil, file: zip.path, dryRun: false)
      XCTFail("Expected device identity change")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Device changed")) }
    let newer = try Device.inspect(device.root)
    do {
      _ = try await Firmware.upgrade(newer, version: nil, file: zip.path, dryRun: false)
      XCTFail("Expected downgrade refusal")
    } catch { XCTAssertTrue(error.localizedDescription.contains("downgrade")) }
    try Data("release_version 1.1.0\nserial fixture\n".utf8).write(to: status)
    let same = try Device.inspect(device.root)
    let unchanged = try await Firmware.upgrade(same, version: nil, file: zip.path, dryRun: false)
    XCTAssertTrue(unchanged.contains("already installed"))
    XCTAssertThrowsError(
      try Firmware.verifyZIP(root.appendingPathComponent("unofficial.zip"), device: device))
    let extra = root.appendingPathComponent("extra.txt")
    try Data("extra".utf8).write(to: extra)
    try SystemCommand.run("/usr/bin/zip", ["-jq", zip.path, extra.path])
    XCTAssertThrowsError(try Firmware.verifyZIP(zip, device: device)) { error in
      XCTAssertTrue(error.localizedDescription.contains("layout"))
    }
    try archive.write(to: zip)
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
  func testPowerCommandAdapterUsesOnlyNoninteractiveAuthorizedCommands() throws {
    XCTAssertNil(Power.flag("SleepDisabled", find: { 0 }))
    XCTAssertNil(Power.externalDisplay(list: { _, _, _ in .failure }))
    XCTAssertNil(
      Power.externalDisplay(list: { _, _, count in
        count?.pointee = 0
        return .success
      }))
    XCTAssertNil(
      Power.externalDisplay(list: { limit, _, count in
        count?.pointee = 1
        return limit == 0 ? .success : .failure
      }))
    XCTAssertNil(PowerRegistry.properties("missing-SidePulse-fixture"))
    XCTAssertNil(PowerRegistry.properties("IOPMrootDomain", read: { _, _ in -1 }))
    var calls: [[String]] = []
    let commands = PowerCommands(run: { binary, arguments in
      calls.append([binary] + arguments)
      return Data()
    })
    try commands.disable(true)
    try commands.disable(false)
    try commands.sleepDisplay()
    XCTAssertEqual(
      calls,
      [
        ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"],
        ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"],
        ["/usr/bin/pmset", "displaysleepnow"],
      ])
    let failure = PowerCommands(run: { _, _ in throw PulseError("Authorization denied") })
    XCTAssertThrowsError(try failure.disable(true))
    XCTAssertThrowsError(try failure.sleepDisplay())
  }

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
    var acknowledge = true
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
      if symbols.count > 7 && acknowledge && statusReads >= 4 {
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
    XCTAssertEqual(statusReads, 4)
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
    symbols = []
    statusReads = 0
    try ReadChannel.upload(
      payload, root: root,
      readBytes: { _, buffer, count, offset in
        XCTAssertEqual(count, 512)
        let sector = Int(offset / 512)
        if sector == 18 {
          let current = try! status()
          var bytes = [UInt8](repeating: 0, count: 512)
          let text =
            "<!--READ2ME1:" + current.data.map { String(format: "%02x", $0) }.joined() + "-->\n"
          bytes.replaceSubrange(256..<256 + text.utf8.count, with: text.utf8)
          bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: 512) }
        } else {
          symbols.append(sector)
        }
        return 512
      })
    XCTAssertEqual(statusReads, 4)
    symbols = []
    acknowledge = false
    time = 0
    XCTAssertThrowsError(
      try ReadChannel.upload(
        payload, read: { symbols.append($0) }, status: status,
        uptime: { time }, wait: { time += 1 })
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("did not acknowledge"))
    }
  }
}

extension HardwareTests {
  func testNativeAwakeAssertionHonorsGraceAndBatteryLimit() {
    var now = Date()
    let output = Output(now: { now })
    defer { output.keepAwake(false) }
    let full = Battery(percent: 90, charging: false, plugged: false, watts: 0)
    output.updateAwake(
      mode: .working, settings: ["sleep_prevention_policy": "never"], battery: full)
    XCTAssertFalse(output.isKeepingAwake)
    output.updateAwake(mode: .working, settings: [:], battery: full)
    XCTAssertTrue(output.isKeepingAwake)
    output.updateAwake(mode: .done, settings: [:], battery: full)
    XCTAssertTrue(output.isKeepingAwake)
    now.addTimeInterval(301)
    output.updateAwake(mode: .idle, settings: [:], battery: full)
    XCTAssertFalse(output.isKeepingAwake)
    output.updateAwake(
      mode: .working, settings: [:],
      battery: Battery(percent: 10, charging: false, plugged: false, watts: 0))
    XCTAssertFalse(output.isKeepingAwake)
  }
}

extension HardwareTests {
  func testPreviewCannotRestoreBackgroundServiceSleepOverride() throws {
    var disabled = false
    var changes = [Bool]()
    let system = SleepOverride.System(
      helperInstalled: { true }, disabled: { disabled },
      lidClosed: { false }, externalDisplay: { false },
      disable: { value in
        disabled = value
        changes.append(value)
      }, sleepDisplay: {})
    let service = SleepOverride(system: system)
    let preview = SleepOverride(system: system)
    try service.update(
      mode: .working, settings: ["swift_closed_lid": "always"], battery: nil, owner: true)
    try preview.update(mode: .idle, settings: [:], battery: nil, owner: false)
    try preview.restore()
    XCTAssertTrue(disabled)
    // Even a stale ownership observation cannot bypass the service's lease.
    try preview.update(mode: .idle, settings: [:], battery: nil, owner: true)
    XCTAssertTrue(disabled)
    try service.update(mode: .idle, settings: [:], battery: nil, owner: false)
    XCTAssertFalse(disabled)
    try preview.update(
      mode: .working, settings: ["swift_closed_lid": "always"], battery: nil, owner: true)
    XCTAssertTrue(disabled)
    try preview.restore()
    XCTAssertEqual(changes, [true, false, true, false])
  }
  func testRestartedOwnerRestoresAbandonedSleepMarker() throws {
    var changes = [Bool]()
    let system = SleepOverride.System(
      helperInstalled: { true }, disabled: { false },
      lidClosed: { false }, externalDisplay: { false }, disable: { changes.append($0) },
      sleepDisplay: {})
    var old: SleepOverride? = SleepOverride(system: system)
    try old?.update(
      mode: .working, settings: ["swift_closed_lid": "always"], battery: nil, owner: true)
    old = nil  // Simulate process exit without a graceful restore.
    let replacement = SleepOverride(system: system)
    try replacement.update(mode: .idle, settings: [:], battery: nil, owner: true)
    XCTAssertEqual(changes, [true, false])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: Paths.support.appendingPathComponent("owns-disablesleep").path))
  }
}

extension HardwareTests {
  func testBatterySnapshotHandlesMissingInvalidAndExternalPowerSources() throws {
    var system = Battery.System(
      info: { nil }, sources: { _ in [] }, description: { _, _ in nil },
      adapter: { ["Watts": 65] },
      diagnostics: { BatteryDiagnostics(properties: ["FullyCharged": true]) })
    XCTAssertNil(Battery.read(system: system))
    system.info = { "info" as CFString }
    XCTAssertNil(Battery.read(system: system))
    system.sources = { _ in nil }
    XCTAssertNil(Battery.read(system: system))
    system.sources = { _ in ["UPS" as CFString, "internal" as CFString] }
    for data: JSONObject? in [
      nil, [:], ["Type": "UPS"],
      ["Type": "InternalBattery", "Current Capacity": 10, "Max Capacity": 0],
    ] {
      system.description = { _, _ in data }
      XCTAssertNil(Battery.read(system: system))
    }
    system.description = { _, source in
      guard source as? String == "internal" else { return ["Type": "UPS"] }
      return [
        "Type": "InternalBattery", "Current Capacity": 150, "Max Capacity": 200,
        "Is Charging": true, "Power Source State": "AC Power",
      ]
    }
    let snapshot = try XCTUnwrap(Battery.read(system: system))
    XCTAssertEqual(snapshot.percent, 75)
    XCTAssertEqual(snapshot.watts, 65)
    XCTAssertTrue(snapshot.charging && snapshot.plugged && snapshot.charged)
    system.adapter = { nil }
    system.diagnostics = { nil }
    XCTAssertEqual(Battery.read(system: system)?.watts, 0)
    XCTAssertEqual(Battery.read(system: system)?.charged, false)
  }

  func testReadOnlyDeviceFallbackUsesOnlySupportedTransportAndDefaultFilename() throws {
    for model in ["Pro", "Dot"] {
      let device = try volume(model, version: "1.1.0")
      var sent: [(String, [UInt8], URL)] = []
      let transport = Device.Transport(
        openFile: { path, flags in
          XCTAssertEqual(path, device.root.appendingPathComponent("LEDS.LED").path)
          XCTAssertNotEqual(flags & O_NOFOLLOW, 0)
          errno = EROFS
          return -1
        }, pro: { sent.append(("Pro", $0, $1)) }, dot: { sent.append(("Dot", $0, $1)) })
      try device.write(" off\n", transport: transport)
      XCTAssertEqual(sent.count, 1)
      XCTAssertEqual(sent.first?.0, model)
      XCTAssertEqual(sent.first?.1, Array("off".utf8))
      XCTAssertEqual(sent.first?.2, device.root)
      for code in [EACCES, EPERM, ENOENT] {
        var denied = transport
        denied.openFile = { _, _ in
          errno = code
          return -1
        }
        if code == ENOENT {
          XCTAssertThrowsError(try device.write("off", transport: denied))
        } else {
          try device.write("off", transport: denied)
        }
        var custom = device
        custom.programFile = "CUSTOM.LED"
        XCTAssertThrowsError(try custom.write("off", transport: denied))
      }
      var old = device
      old = try volume(model, version: "1.0.0")
      XCTAssertThrowsError(try old.write("off", transport: transport))
    }
  }

  func testRawDiskChecksIdentityAndRejectsPartialTransfersBeforeWritingMore() throws {
    var disk = [UInt8](repeating: 0, count: 512 * 16)
    for (offset, value): (Int, UInt8) in [
      (510, 85), (511, 170), (12, 2), (13, 1), (14, 1), (16, 1), (17, 16), (19, 16), (22, 1),
      (1050, 2), (515, 255), (516, 15),
    ] {
      disk[offset] = value
    }
    disk.replaceSubrange(1024..<1035, with: "LEDS    LED".utf8)
    let file = root.appendingPathComponent("raw-fixture")
    try Data(disk).write(to: file)
    let path = "/dev/disk999"
    var opens = 0
    var writes = 0
    var checks = 0
    let base = RawDisk.IO(
      command: { command, args in
        XCTAssertEqual(command, "/usr/sbin/diskutil")
        XCTAssertEqual(args, ["info", "-plist", path])
        checks += 1
        return try PropertyListSerialization.data(
          fromPropertyList: ["WholeDisk": true, "DeviceNode": path], format: .binary, options: 0)
      },
      openFile: { _, flags in
        opens += 1
        return open(file.path, flags)
      }, size: { _ in Int64(disk.count) },
      write: { fd, bytes, size, offset in
        writes += 1
        return pwrite(fd, bytes, size, offset)
      })
    try RawDisk.write(path: path, program: "off", dryRun: false, io: base)
    XCTAssertEqual(checks, 3)
    XCTAssertEqual(writes, 2)
    let result = try Data(contentsOf: file)
    XCTAssertEqual(result[1536..<1539], Data("off".utf8))
    XCTAssertEqual(result[1052], 3)
    for failure in ["mount", "open", "size", "read", "changed", "write", "sync"] {
      var io = base
      var sizes = 0
      switch failure {
      case "mount":
        io.command = { _, _ in
          try PropertyListSerialization.data(
            fromPropertyList: ["WholeDisk": false], format: .binary, options: 0)
        }
      case "open": io.openFile = { _, _ in -1 }
      case "size": io.size = { _ in 300001 }
      case "read": io.read = { _, _, _, _ in 511 }
      case "changed":
        io.size = { _ in
          sizes += 1
          return Int64(sizes == 1 ? disk.count : 0)
        }
      case "write": io.write = { _, _, _, _ in 511 }
      default: io.sync = { _ in -1 }
      }
      XCTAssertThrowsError(
        try RawDisk.write(path: path, program: "off", dryRun: false, io: io), failure)
    }
    XCTAssertGreaterThan(opens, 1)
    var invalid = disk
    invalid[17] = 0xff
    invalid[18] = 0xff
    XCTAssertThrowsError(try RawDisk.layout(invalid))
    invalid = disk
    invalid[19] = 0
    invalid[32] = 0x40
    invalid[33] = 0x02
    invalid += [UInt8](repeating: 0, count: 512 * 560)
    XCTAssertThrowsError(try RawDisk.layout(invalid)) {
      XCTAssertTrue($0.localizedDescription.contains("allocation"))
    }
    invalid = disk
    invalid[1024] = 0
    XCTAssertThrowsError(try RawDisk.layout(invalid)) {
      XCTAssertTrue($0.localizedDescription.contains("existing LEDS.LED"))
    }
  }

  func testReadChannelRejectsInvalidMappingAllocationAndShortReads() throws {
    let file = root.appendingPathComponent("setup.html")
    try Data(count: 1).write(to: file)
    XCTAssertThrowsError(try ReadChannel.upload([1], root: root)) { error in
      XCTAssertTrue(error.localizedDescription.contains("configure"))
    }
    try Data(count: 19 * 512).write(to: file)
    XCTAssertThrowsError(try ReadChannel.upload([1], root: root, allocate: { _, _, _ in ENOMEM })) {
      error in
      XCTAssertTrue(error.localizedDescription.contains("allocate"))
    }
    XCTAssertThrowsError(try ReadChannel.upload([1], root: root, readBytes: { _, _, _, _ in 0 })) {
      error in
      XCTAssertTrue(error.localizedDescription.contains("Incomplete"))
    }
    var sector = [UInt8](repeating: 0, count: 512)
    let text = "<!--READ2ME1:" + String(repeating: "ZZ", count: 64) + "-->\n"
    sector.replaceSubrange(256..<256 + text.utf8.count, with: text.utf8)
    XCTAssertThrowsError(try ReadChannel.Status(sector)) { error in
      XCTAssertTrue(error.localizedDescription.contains("encoding"))
    }
    var contents = Data(count: 18 * 512)
    contents.append(contentsOf: sector)
    try contents.write(to: file)
    XCTAssertThrowsError(try ReadChannel.upload([1], root: root)) { error in
      XCTAssertTrue(error.localizedDescription.contains("encoding"))
    }
  }
}

extension HardwareTests {
  func testFAT12RejectsSelfReferencingAndOutOfRangeChains() throws {
    var disk = [UInt8](repeating: 0, count: 512 * 8)
    disk[11] = 0
    disk[12] = 2
    disk[13] = 1
    disk[14] = 1
    disk[16] = 1
    disk[17] = 16
    disk[19] = 8
    disk[22] = 1
    disk[510] = 85
    disk[511] = 170
    disk.replaceSubrange(1024..<1035, with: "LEDS    LED".utf8)
    disk[1050] = 2
    disk[515] = 3
    XCTAssertEqual(try RawDisk.layout(disk).data, 1536)
    disk[515] = 2
    XCTAssertThrowsError(try RawDisk.layout(disk))
    disk[515] = 20
    XCTAssertThrowsError(try RawDisk.layout(disk))
  }
}
