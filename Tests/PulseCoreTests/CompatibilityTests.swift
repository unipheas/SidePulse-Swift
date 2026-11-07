import Foundation
import XCTest

@testable import PulseCore

final class CompatibilityTests: XCTestCase {
  func testEveryBundledAnimationParses() throws {
    for name in Programs.animationNames {
      let count = name.hasSuffix("-2") ? 2 : 8
      XCTAssertNoThrow(
        try LEDPreview(program: Programs.preset(name, count: count), count: count), name)
    }
  }
  func testReadChannelFrameMatchesProtocol() {
    XCTAssertEqual(ReadChannel.crc(Array("123456789".utf8)), 0x29b1)
    let packet = ReadChannel.frame(id: 1, payload: [0x41])
    XCTAssertEqual(Array(packet.prefix(6)), ReadChannel.start)
    XCTAssertEqual(Array(packet.suffix(6)), ReadChannel.end)
    let nibbles = Array(packet.dropFirst(6).dropLast(6))
    let bytes = stride(from: 0, to: nibbles.count, by: 2).map {
      UInt8(nibbles[$0] * 16 + nibbles[$0 + 1])
    }
    XCTAssertEqual(Array(bytes.prefix(14)), [1, 0, 0, 0, 1, 8] + Array("LEDS.LED".utf8))
    XCTAssertEqual(Array(bytes[14..<25]), [0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0x41])
    XCTAssertEqual(
      UInt16(bytes[25]) << 8 | UInt16(bytes[26]), ReadChannel.crc(Array(bytes.dropLast(2))))
  }
  func testRawWriterRejectsUnallocatedClusterAndOversizedVolume() throws {
    var disk = [UInt8](repeating: 0, count: 512 * 16)
    disk[510] = 85
    disk[511] = 170
    disk[12] = 2
    disk[13] = 1
    disk[14] = 1
    disk[16] = 1
    disk[17] = 16
    disk[19] = 16
    disk[22] = 1
    let pos = 1024
    disk.replaceSubrange(pos..<pos + 11, with: "LEDS    LED".utf8)
    disk[pos + 26] = 2
    XCTAssertThrowsError(try RawDisk.layout(disk))
    disk[515] = 0xff
    disk[516] = 0x0f
    let target = try RawDisk.layout(disk)
    XCTAssertEqual(target.data, 1536)
    XCTAssertEqual(target.directory, 1024)
    disk[pos + 11] = 1
    XCTAssertThrowsError(try RawDisk.layout(disk))
    XCTAssertThrowsError(try RawDisk.layout(Array(repeating: 0, count: 300001)))
  }
  func testNamesAndMarkers() throws {
    XCTAssertEqual(Events.explicit([:], message: "<!-- sidepulse:blocked -->"), .blocked)
    XCTAssertEqual(Events.explicit(["sidepulse_status": "done"], message: ""), .done)
    XCTAssertNil(Events.explicit([:], message: "Example: <!-- sidepulse:ask -->"))
    XCTAssertNil(Events.explicit([:], message: "```\n<!-- sidepulse:ask -->\n```"))
  }
  func testRejectsMalformedBridgeAndFirmwareManifests() throws {
    XCTAssertThrowsError(try Bridge.address("https://user@example.com", channel: "channel"))
    XCTAssertThrowsError(try Bridge.address("https://example.com/path", channel: "channel"))
    XCTAssertThrowsError(try Firmware.checksums(Data("bad  FIRMWARE.BIN".utf8)))
    let digest = String(repeating: "a", count: 64) + "  FIRMWARE.BIN\n"
    XCTAssertThrowsError(try Firmware.checksums(Data((digest + digest).utf8)))
  }
  func testBatteryProgramsForBothModels() throws {
    for percent in [0, 12, 50, 99, 100] {
      for count in [2, 8] {
        for charging in [false, true] {
          let snapshot = Battery(percent: percent, charging: charging, plugged: charging, watts: 60)
          _ = try LEDPreview(program: snapshot.program(count: count), count: count)
        }
      }
    }
  }
  func testCodexAndClaudeTranscriptAdapters() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Paths.directory(directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("00000000-0000-4000-a000-000000000001.jsonl")
    for provider in ["claude", "codex"] {
      var json: JSONObject = ["timestamp": "2026-01-01T00:00:00Z"]
      if provider == "codex" {
        json["payload"] = ["type": "task_complete", "last_agent_message": "Finished."]
      } else {
        json["type"] = "assistant"
        json["message"] = [
          "stop_reason": "end_turn", "content": [["type": "text", "text": "Finished."]],
        ]
      }
      let line = try JSONSerialization.data(withJSONObject: json)
      try line.write(to: url)
      XCTAssertEqual(TranscriptReader.last(url, provider: provider, size: line.count)?.mode, .done)
    }
  }
}
