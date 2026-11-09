import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class OutputProfileTests: IsolatedTests {
  private func settings() -> JSONObject {
    [
      "agent_animations": Dictionary(
        uniqueKeysWithValues: Mode.allCases.map {
          ($0.rawValue, ["style": "custom", "custom_program": "#123456"])
        }),
      "output_animation_profiles": ["Dot": "ember", "Pro": "purple", "Notch": "cyan"],
      "virtual_status_device_enabled": true,
    ]
  }

  func testLegacyAndUnsetSelectionsUseExactGlobalProgramsForEveryState() throws {
    var settings = settings()
    settings[OutputProfiles.settingsKey] = nil
    for target in OutputProfiles.Target.allCases {
      XCTAssertEqual(OutputProfiles.selection(for: target, settings: settings), "global")
      for mode in Mode.allCases {
        XCTAssertEqual(
          try OutputProfiles.program(mode, target: target, settings: settings),
          try Programs.program(mode, count: target.count, settings: settings))
      }
    }
    XCTAssertTrue(OutputProfiles.notchVisible(mode: .idle, settings: settings))
  }

  func testDotProAndNotchResolveIndependentProfilesAtTheirLEDCounts() throws {
    let settings = settings()
    for (target, profile) in [
      (OutputProfiles.Target.dot, "ember"), (.pro, "purple"), (.notch, "cyan"),
    ] {
      let map = try Programs.profile(profile)
      for mode in Mode.allCases {
        XCTAssertEqual(
          try OutputProfiles.program(mode, target: target, settings: settings),
          try Programs.preset(try XCTUnwrap(map[mode.rawValue]), count: target.count))
      }
    }
    XCTAssertEqual(try Programs.program(.working, count: 8, settings: settings), "#123456")
  }

  func testSavedProfilesResolveCustomLibraryAndMissingStatesFallBack() throws {
    var settings = settings()
    settings[OutputProfiles.settingsKey] = ["Dot": "profile:test", "Pro": "profile:missing"]
    settings["agent_animation_profiles"] = [
      "profile:test": [
        "animations": [
          "working": "custom:test", Mode.done.rawValue: "missing-preset",
        ]
      ]
    ]
    settings["custom_agent_animations"] = ["custom:test": ["program": "#ABCDEF"]]
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .dot, settings: settings), "#ABCDEF")
    for mode in [Mode.done, .idle] {
      XCTAssertEqual(try OutputProfiles.program(mode, target: .dot, settings: settings), "#123456")
    }
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .pro, settings: settings), "#123456")
    settings["custom_agent_animations"] = [:]
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .dot, settings: settings), "#123456")
    settings[OutputProfiles.settingsKey] = ["Dot": 12]
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .dot, settings: settings), "#123456")
  }

  func testSelectionPersistsWithoutChangingGlobalLibraryOrDevicePreferences() throws {
    var original = settings()
    original["swift_profile"] = "current"
    original["custom_agent_animations"] = ["custom:keep": ["program": "off"]]
    original["agent_animation_profiles"] = [
      "profile:keep": ["name": "Keep", "animations": ["working": "custom:keep"]]
    ]
    original["devices"] = [["id": "/Volumes/Dot", "brightness": 50, "led_display": "battery"]]
    original["agent_list"] = ["completed_visible_seconds": 15]
    original["unrelated_future_setting"] = ["value": true]
    try saveObject(original, to: Settings.url)
    try OutputProfiles.select("profile:keep", for: .dot)
    var saved = try Settings.read()
    XCTAssertEqual(OutputProfiles.selection(for: .dot, settings: saved), "profile:keep")
    XCTAssertEqual(OutputProfiles.selection(for: .pro, settings: saved), "purple")
    saved[OutputProfiles.settingsKey] = original[OutputProfiles.settingsKey]
    XCTAssertEqual(saved as NSDictionary, original as NSDictionary)
    try Settings.migrate()
    XCTAssertEqual(
      OutputProfiles.selection(for: .dot, settings: try Settings.read()), "profile:keep")
    let before = try Settings.read()
    XCTAssertThrowsError(try OutputProfiles.select("profile:unknown", for: .dot))
    XCTAssertEqual(try Settings.read() as NSDictionary, before as NSDictionary)
    try OutputProfiles.select("global", for: .dot)
    XCTAssertEqual(OutputProfiles.selection(for: .dot, settings: try Settings.read()), "global")
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .dot, settings: Settings.read()), "#123456")
  }

  func testDeletionOnlyClearsAssignmentsThatReferenceDeletedProfile() throws {
    var settings = settings()
    settings["swift_profile"] = "current"
    try saveObject(settings, to: Settings.url)
    let id = try Profiles.save(name: "Independent")
    try OutputProfiles.select(id, for: .dot)
    try OutputProfiles.select(id, for: .notch)
    let before = try Settings.read()
    try Profiles.delete(id)
    let after = try Settings.read()
    XCTAssertEqual(OutputProfiles.selection(for: .dot, settings: after), "global")
    XCTAssertEqual(OutputProfiles.selection(for: .notch, settings: after), "global")
    XCTAssertEqual(OutputProfiles.selection(for: .pro, settings: after), "purple")
    XCTAssertEqual(
      after["agent_animations"] as? NSDictionary, before["agent_animations"] as? NSDictionary)
    XCTAssertEqual(
      after["custom_agent_animations"] as? NSDictionary,
      before["custom_agent_animations"] as? NSDictionary)
    XCTAssertEqual(try OutputProfiles.program(.working, target: .dot, settings: after), "#123456")
  }

  func testGlobalProfileChangesDoNotReplaceOutputSelections() throws {
    try saveObject(settings(), to: Settings.url)
    try Profiles.select("cyan")
    let after = try Settings.read()
    XCTAssertEqual(OutputProfiles.selection(for: .dot, settings: after), "ember")
    XCTAssertEqual(OutputProfiles.selection(for: .pro, settings: after), "purple")
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .dot, settings: after),
      try Programs.preset(Programs.profile("ember")["working"]!, count: 2))
  }

  func testSimultaneousOutputsReconnectAndProfileChangesWriteOnlyChangedPrograms() throws {
    let dot = try volume("Dot")
    let pro = try volume("Pro")
    let moved = Device(
      root: root.appendingPathComponent("MovedDot"), model: "Dot", firmware: "1.0.0",
      serial: "fixture")
    var sent = [(Device, String)]()
    let output = Output(lidClosed: { nil }, write: { sent.append(($0, $1)) })
    var settings = settings()
    try output.sync(devices: [dot, pro], mode: .working, settings: settings, battery: nil)
    XCTAssertEqual(sent.map { $0.0 }, [dot, pro])
    XCTAssertEqual(
      sent[0].1, try OutputProfiles.program(.working, target: .dot, settings: settings))
    XCTAssertEqual(
      sent[1].1, try OutputProfiles.program(.working, target: .pro, settings: settings))
    try output.sync(devices: [dot, pro], mode: .working, settings: settings, battery: nil)
    XCTAssertEqual(sent.count, 2)
    try output.sync(devices: [pro], mode: .working, settings: settings, battery: nil)
    try output.sync(devices: [moved, pro], mode: .working, settings: settings, battery: nil)
    XCTAssertEqual(sent.count, 3)
    XCTAssertEqual(sent[2].0, moved)
    XCTAssertEqual(sent[2].1, sent[0].1)
    settings[OutputProfiles.settingsKey] = ["Dot": "cyan", "Pro": "purple"]
    try output.sync(devices: [moved, pro], mode: .working, settings: settings, battery: nil)
    XCTAssertEqual(sent.count, 4)
    XCTAssertEqual(sent.last?.0, moved)
    XCTAssertEqual(
      sent.last?.1, try OutputProfiles.program(.working, target: .dot, settings: settings))
    settings["swift_mirror"] = false
    try output.sync(devices: [moved, pro], mode: .done, settings: settings, battery: nil)
    XCTAssertEqual(sent.count, 4)
  }

  func testHardwareManualBatteryBrightnessAndLidPrecedenceArePreserved() throws {
    let dot = try volume("Dot")
    let pro = try volume("Pro")
    var sent = [String: String]()
    var closed = false
    var now = Date(timeIntervalSince1970: 100)
    let output = Output(now: { now }, lidClosed: { closed }, write: { sent[$0.id] = $1 })
    var settings = settings()
    settings["lid_closed_animation"] = ["program": "#010203", "duration_seconds": 2.0]
    Settings.editDevice(dot.id, in: &settings, values: ["brightness": 128])
    let battery = Battery(percent: 42, charging: false, plugged: false, watts: 0)
    try output.sync(devices: [dot, pro], mode: .working, settings: settings, battery: battery)
    XCTAssertEqual(
      sent[dot.id],
      Programs.brightness(
        try OutputProfiles.program(.working, target: .dot, settings: settings), level: 128))
    Settings.editDevice(
      dot.id, in: &settings, values: ["led_display": "custom", "manual_program": "#112233"])
    Settings.editDevice(pro.id, in: &settings, values: ["led_display": "battery"])
    try output.sync(devices: [dot, pro], mode: .working, settings: settings, battery: battery)
    XCTAssertEqual(sent[dot.id], "brightness 128\n#112233")
    XCTAssertEqual(sent[pro.id], battery.program(count: 8, settings: settings))
    closed = true
    try output.sync(devices: [dot, pro], mode: .idle, settings: settings, battery: battery)
    XCTAssertEqual(sent[dot.id], "brightness 128\n#112233")
    XCTAssertEqual(
      sent[pro.id], try OutputProfiles.lidProgram("lid_closed", device: pro, settings: settings))
    now.addTimeInterval(60)
    try output.sync(devices: [dot, pro], mode: .idle, settings: settings, battery: battery)
    XCTAssertEqual(
      sent[pro.id], try OutputProfiles.lidProgram("lid_closed", device: pro, settings: settings))
    try output.sync(devices: [dot, pro], mode: .working, settings: settings, battery: battery)
    XCTAssertEqual(sent[pro.id], battery.program(count: 8, settings: settings))
    Settings.editDevice(dot.id, in: &settings, values: ["manual_program": NSNull()])
    sent = [:]
    try output.sync(devices: [dot, pro], mode: .done, settings: settings, battery: battery)
    XCTAssertNil(sent[dot.id])
  }

  func testLidProgramsUseModelLayoutAndFallBackWithoutChangingDurations() throws {
    let dot = try volume("Dot")
    let pro = try volume("Pro")
    var settings = settings()
    settings["lid_open_animation"] = ["program": "#010203", "duration_seconds": 12.0]
    for state in ["lid_open", "lid_closed"] {
      for (device, profile) in [(dot, "ember"), (pro, "purple")] {
        XCTAssertEqual(
          try OutputProfiles.lidProgram(state, device: device, settings: settings),
          try Programs.preset(Programs.profile(profile)[state]!, count: device.count))
      }
    }
    settings[OutputProfiles.settingsKey] = [:] as [String: String]
    XCTAssertEqual(
      try OutputProfiles.lidProgram("lid_open", device: dot, settings: settings), "#010203")
    XCTAssertEqual(
      try OutputProfiles.lidProgram("lid_closed", device: dot, settings: settings),
      try Programs.preset("lid-closed", count: 2))
    XCTAssertEqual(
      (settings["lid_open_animation"] as? JSONObject)?["duration_seconds"] as? Double, 12)
  }

  @MainActor func testNotchAttentionVisibilityGatesEveryModeIncludingBatteryPreview() throws {
    var settings = settings()
    settings["notch_attention_only"] = true
    let battery = Battery(percent: 42, charging: false, plugged: false, watts: 0)
    for display in ["agent", "battery", "custom"] {
      Settings.editDevice(
        NotchDisplay.deviceID, in: &settings, values: ["led_display": display, "brightness": 128])
      for preview in [false, true] {
        for mode in Mode.allCases {
          let program = try NotchDisplay.program(
            settings: settings, mode: mode, battery: battery, previewingBattery: preview)
          if [.waiting, .blocked].contains(mode) && display != "custom" {
            let source =
              display == "battery" || preview
              ? battery.program(count: 8, settings: settings)
              : try OutputProfiles.program(mode, target: .notch, settings: settings)
            XCTAssertEqual(program, Programs.brightness(source, level: 128))
          } else {
            XCTAssertNil(program, "Must hide the panel for \(mode), \(display), preview=\(preview)")
          }
        }
      }
    }
    settings["notch_attention_only"] = false
    Settings.editDevice(NotchDisplay.deviceID, in: &settings, values: ["led_display": "agent"])
    XCTAssertNotNil(try NotchDisplay.program(settings: settings, mode: .idle, battery: nil))
    settings["virtual_status_device_enabled"] = false
    XCTAssertNil(try NotchDisplay.program(settings: settings, mode: .waiting, battery: nil))
  }

  @MainActor func testOutputPickersAndVisibilityTogglePersistWithoutApplyingGlobalProfile() throws {
    // The Notch is deliberately disabled: inspecting actions must not create a visible panel.
    var settings = settings()
    settings["virtual_status_device_enabled"] = false
    try saveObject(settings, to: Settings.url)
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let original = try Settings.read()["agent_animations"] as? NSDictionary
    for target in OutputProfiles.Target.allCases {
      let view = OutputProfilePicker(target: target).environmentObject(model)
      let picker = try view.inspect().find(ViewType.Picker.self)
      try picker.select(value: "purple")
      XCTAssertEqual(OutputProfiles.selection(for: target, settings: try Settings.read()), "purple")
      try picker.select(value: "global")
      XCTAssertEqual(OutputProfiles.selection(for: target, settings: try Settings.read()), "global")
    }
    let controls = OutputProfileSettings().environmentObject(model)
    let toggle = try controls.inspect().find(ViewType.Toggle.self)
    try toggle.tap()
    XCTAssertEqual(try Settings.read()["notch_attention_only"] as? Bool, true)
    try toggle.tap()
    XCTAssertEqual(try Settings.read()["notch_attention_only"] as? Bool, false)
    XCTAssertEqual(try Settings.read()["agent_animations"] as? NSDictionary, original)
    XCTAssertNil(model.problem)
  }
  @MainActor func testUnavailableProfileIsVisibleAndInvalidSelectionDoesNotMutateSettings() throws {
    var settings = settings()
    settings["virtual_status_device_enabled"] = false
    settings[OutputProfiles.settingsKey] = ["Dot": "profile:gone"]
    try saveObject(settings, to: Settings.url)
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let before = try Settings.read()
    let view = OutputProfilePicker(target: .dot).environmentObject(model)
    XCTAssertNoThrow(try view.inspect().find(text: "Unavailable profile (using fallback)"))
    try view.inspect().find(ViewType.Picker.self).select(value: "profile:invalid")
    XCTAssertEqual(model.problem, "Unknown profile.")
    XCTAssertEqual(try Settings.read() as NSDictionary, before as NSDictionary)
  }

  func testUnknownSelectionValuesSurviveAssignmentAndProfileDeletion() throws {
    var settings = settings()
    settings[OutputProfiles.settingsKey] =
      [
        "Dot": "ember", "Pro": "profile:delete", "future-output": ["version": 2, "enabled": true],
        "Notch": 12,
      ] as JSONObject
    settings["agent_animation_profiles"] = [
      "profile:delete": ["animations": ["working": "idle-pulse"]]
    ]
    try saveObject(settings, to: Settings.url)
    XCTAssertEqual(OutputProfiles.selection(for: .dot, settings: settings), "ember")
    XCTAssertEqual(OutputProfiles.selection(for: .notch, settings: settings), "global")
    try OutputProfiles.select("cyan", for: .dot)
    try Profiles.delete("profile:delete")
    let selections = try XCTUnwrap(try Settings.read()[OutputProfiles.settingsKey] as? JSONObject)
    XCTAssertEqual(selections["Dot"] as? String, "cyan")
    XCTAssertNil(selections["Pro"])
    XCTAssertEqual(selections["Notch"] as? Int, 12)
    XCTAssertEqual(
      selections["future-output"] as? NSDictionary, ["version": 2, "enabled": true] as NSDictionary)
  }

  func testFirstOutputSelectionCreatesRegistryAndCanRestoreInheritance() throws {
    var original = settings()
    original[OutputProfiles.settingsKey] = nil
    try saveObject(original, to: Settings.url)
    try OutputProfiles.select("ember", for: .dot)
    var saved = try Settings.read()
    XCTAssertEqual(OutputProfiles.selection(for: .dot, settings: saved), "ember")
    XCTAssertEqual(OutputProfiles.selection(for: .pro, settings: saved), "global")
    XCTAssertEqual(OutputProfiles.selection(for: .notch, settings: saved), "global")
    saved[OutputProfiles.settingsKey] = nil
    XCTAssertEqual(saved as NSDictionary, original as NSDictionary)
    try OutputProfiles.select("global", for: .dot)
    let restored = try Settings.read()
    XCTAssertEqual(
      try OutputProfiles.program(.working, target: .dot, settings: restored), "#123456")
    XCTAssertTrue(try XCTUnwrap(restored[OutputProfiles.settingsKey] as? JSONObject).isEmpty)
  }

  @MainActor func testAllOutputPickersListSavedProfilesWithoutDuplicatingBuiltInChoices() throws {
    var settings = settings()
    settings["virtual_status_device_enabled"] = false
    settings["agent_animation_profiles"] = [
      "cyan": ["name": "Duplicate Cyan", "animations": ["working": "idle-pulse"]],
      "profile:saved": ["name": "Saved profile", "animations": ["working": "idle-pulse"]],
      "profile:unnamed": ["animations": ["working": "idle-pulse"]],
    ]
    try saveObject(settings, to: Settings.url)
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    let view = OutputProfileSettings().environmentObject(model)
    let pickers = try view.inspect().findAll(ViewType.Picker.self)
    XCTAssertEqual(pickers.count, 3)
    let labels = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    XCTAssertEqual(labels.filter { $0 == "Cyan" }.count, 3)
    XCTAssertEqual(labels.filter { $0 == "Duplicate Cyan" }.count, 0)
    XCTAssertEqual(labels.filter { $0 == "Saved profile" }.count, 3)
    XCTAssertEqual(labels.filter { $0 == "profile:unnamed" }.count, 3)
    for (picker, target) in zip(pickers, OutputProfiles.Target.allCases) {
      try picker.select(value: "profile:saved")
      XCTAssertEqual(
        OutputProfiles.selection(for: target, settings: try Settings.read()), "profile:saved")
    }
    XCTAssertNil(model.problem)
  }

}
