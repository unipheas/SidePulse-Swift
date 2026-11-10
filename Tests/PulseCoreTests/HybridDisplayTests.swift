import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class HybridDisplayTests: IsolatedTests {
  func battery(_ percent: Int, charging: Bool = false, charged: Bool = false) -> Battery {
    Battery(percent: percent, charging: charging, plugged: charging, watts: 0, charged: charged)
  }

  func testBatteryBucketsAndChargingPrecedence() {
    let cases: [(Battery?, String)] = [
      (nil, "#303030"), (battery(0), "#5A189A"), (battery(19), "#5A189A"),
      (battery(20), "#7B2CBF"), (battery(49), "#7B2CBF"),
      (battery(50), "#0077FF"), (battery(74), "#0077FF"),
      (battery(75), "#00B8A9"), (battery(100), "#00B8A9"),
      (battery(10, charging: true), "#FFFFFF"), (battery(10, charged: true), "#00B8A9"),
    ]
    for (battery, expected) in cases {
      XCTAssertTrue(HybridDisplay.program(mode: .done, battery: battery).hasPrefix("0:\(expected) "))
    }
  }

  func testAllModesParseAndKeepBatterySeparateAcrossAnimationCycles() throws {
    for mode in Mode.allCases {
      let program = HybridDisplay.program(mode: mode, battery: battery(75))
      XCTAssertLessThanOrEqual(program.utf8.count, 512, "\(mode)")
      XCTAssertLessThanOrEqual(program.components(separatedBy: "\n").count, 20)
      let preview = try LEDPreview(program: program, count: 8)
      var agentFrames = Set<[UInt8]>()
      for time in stride(from: 20, through: 5_000, by: 20) {
        let frame = preview.frame(milliseconds: time)
        XCTAssertEqual(Array(frame.prefix(3)), [0x00, 0xB8, 0xA9], "\(mode) at \(time)")
        agentFrames.insert(Array(frame.dropFirst(3)))
      }
      if [.working, .tool, .progress, .waiting, .blocked, .idle].contains(mode) {
        XCTAssertGreaterThan(agentFrames.count, 1, "\(mode) must animate")
      }
    }
  }

  func testAgentFamiliesUseRequestedColorsAndUnknownIsDistinct() throws {
    let expected: [(Mode, [UInt8])] = [
      (.working, [0x00, 0xE5, 0xFF]), (.tool, [0x00, 0xE5, 0xFF]),
      (.progress, [0x00, 0xE5, 0xFF]), (.waiting, [0xFF, 0x9F, 0x1C]),
      (.blocked, [0xFF, 0x9F, 0x1C]), (.done, [0xB6, 0xFF, 0x00]),
      (.idle, [0x02, 0x02, 0x04]), (.unknown, [0x80, 0x80, 0x80]),
    ]
    for (mode, color) in expected {
      let preview = try LEDPreview(program: HybridDisplay.program(mode: mode, battery: nil), count: 8)
      var peak: [UInt8] = [0, 0, 0]
      for time in stride(from: 20, through: 3_500, by: 20) {
        let frame = preview.frame(milliseconds: time)
        for index in 1...7 {
          for channel in 0..<3 { peak[channel] = max(peak[channel], frame[index * 3 + channel]) }
        }
      }
      XCTAssertEqual(peak, color, "\(mode)")
    }
  }

  func testOutputRoutingPrecedenceAndDeduplication() throws {
    let pro = try volume("Pro"), dot = try volume("Dot")
    var now = Date(timeIntervalSince1970: 100), closed = false
    var writes: [(Device, String)] = []
    let output = Output(now: { now }, lidClosed: { closed }, write: { writes.append(($0, $1)) })
    var settings: JSONObject = ["output_animation_profiles": ["Pro": "purple"]]
    Settings.editDevice(pro.id, in: &settings, values: ["led_display": "hybrid", "brightness": 128])
    Settings.editDevice(dot.id, in: &settings, values: ["led_display": "hybrid"])
    let first = battery(75)
    try output.sync(devices: [pro, dot], mode: .working, settings: settings, battery: first)
    XCTAssertEqual(writes[0].1, Programs.brightness(HybridDisplay.program(mode: .working, battery: first), level: 128))
    XCTAssertEqual(writes[1].1, try OutputProfiles.program(.working, device: dot, settings: settings))
    try output.sync(devices: [pro, dot], mode: .working, settings: settings, battery: battery(80))
    XCTAssertEqual(writes.count, 2, "same battery bucket must not restart animation")
    let charging = battery(80, charging: true)
    try output.sync(devices: [pro, dot], mode: .working, settings: settings, battery: charging)
    XCTAssertEqual(writes[2].1, Programs.brightness(HybridDisplay.program(mode: .working, battery: charging), level: 128))
    XCTAssertEqual(writes.count, 4, "Dot keeps its existing power-change preview")
    closed = true
    try output.sync(devices: [pro], mode: .idle, settings: settings, battery: charging)
    XCTAssertEqual(writes.last?.1, Programs.brightness(try OutputProfiles.lidProgram("lid_closed", device: pro, settings: settings), level: 128))
    now.addTimeInterval(60)
    try output.sync(devices: [pro], mode: .working, settings: settings, battery: charging)
    XCTAssertEqual(writes.last?.1, Programs.brightness(HybridDisplay.program(mode: .working, battery: charging), level: 128))
    let count = writes.count
    settings["swift_mirror"] = false
    try output.sync(devices: [pro], mode: .done, settings: settings, battery: charging)
    XCTAssertEqual(writes.count, count)
    settings["swift_mirror"] = true
    Settings.editDevice(pro.id, in: &settings, values: ["led_display": "custom", "manual_program": "#123456"])
    try output.sync(devices: [pro], mode: .idle, settings: settings, battery: charging)
    XCTAssertEqual(writes.last?.1, "brightness 128\n#123456")
  }

  @MainActor func testHybridPickerIsOptInAndSavesOnlyDeviceChoice() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let picker = DeviceDisplayPreference(id: "/Volumes/Pro", title: "Display", allowsHybrid: true)
      .environmentObject(model)
    XCTAssertNoThrow(try picker.inspect().find(text: "Battery + agent status"))
    try picker.inspect().find(ViewType.Picker.self).select(value: "hybrid")
    XCTAssertEqual(Settings.device("/Volumes/Pro", in: try Settings.read())["led_display"] as? String, "hybrid")
    XCTAssertEqual(Settings.device("/Volumes/Pro", in: try Settings.read())["swift_hybrid_capable"] as? Bool, true)
    try picker.inspect().find(ViewType.Picker.self).select(value: "agent")
    XCTAssertEqual(Settings.device("/Volumes/Pro", in: try Settings.read())["swift_hybrid_capable"] as? Bool, true)
    let other = DeviceDisplayPreference(id: "/Volumes/Dot", title: "Display").environmentObject(model)
    XCTAssertThrowsError(try other.inspect().find(text: "Battery + agent status"))
  }
  @MainActor func testDisconnectedProCanSwitchAwayAndBack() throws {
    try Settings.update {
      Settings.editDevice("/Volumes/Pro", in: &$0, values: ["led_display": "hybrid"])
    }
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let view = DeviceManagement().environmentObject(model)
    XCTAssertNoThrow(try view.inspect().find(text: "Battery + agent status"))
    try view.inspect().find(ViewType.Picker.self).select(value: "agent")
    XCTAssertEqual(Settings.device("/Volumes/Pro", in: model.settings)["swift_hybrid_capable"] as? Bool, true)
    let refreshed = DeviceManagement().environmentObject(model)
    XCTAssertNoThrow(try refreshed.inspect().find(text: "Battery + agent status"))
    try refreshed.inspect().find(ViewType.Picker.self).select(value: "hybrid")
    XCTAssertEqual(Settings.device("/Volumes/Pro", in: try Settings.read())["led_display"] as? String, "hybrid")
  }

}
