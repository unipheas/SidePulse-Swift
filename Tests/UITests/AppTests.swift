import XCTest

final class AppTests: XCTestCase {
  private var app: XCUIApplication!
  private var root: URL!
  override func setUpWithError() throws {
    continueAfterFailure = false
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SidePulse-UI-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: [
      "setup_screen_completed": true, "swift_mirror": false, "swift_closed_lid": "never",
      "sleep_prevention_policy": "never",
      "show_menu_bar_icon": false, "agent_list": ["completed_visible_seconds": 15],
    ]).write(to: root.appendingPathComponent("settings.json"))
    app = XCUIApplication()
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    app.launchEnvironment = [
      "SIDEPULSE_USER_HOME": root.appendingPathComponent("home").path,
      "SIDEPULSE_SWIFT_HOME": root.path,
      "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
      "XDG_STATE_HOME": root.appendingPathComponent("state").path,
    ]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
  }
  override func tearDownWithError() throws {
    app?.terminate()
    if let root { try FileManager.default.removeItem(at: root) }
  }
  private func select(_ title: String) {
    app.activate()
    app.outlines["Sidebar"].staticTexts[title].firstMatch.click()
    if !app.windows[title].waitForExistence(timeout: 2) {
      app.outlines["Sidebar"].staticTexts[title].firstMatch.click()
    }
    XCTAssertTrue(app.windows[title].waitForExistence(timeout: 3))
  }
  private func replace(_ field: XCUIElement, with value: String) {
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(value)
  }
  private func settings() throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("settings.json"))) as? [String: Any])
  }
  private func reveal(_ element: XCUIElement) {
    for _ in 0..<15 where !element.isHittable {
      app.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -180)
    }
    XCTAssertTrue(element.isHittable, app.debugDescription)
  }
  private func choose(_ picker: XCUIElement, _ value: String) {
    reveal(picker)
    picker.click()
    app.menuItems[value].firstMatch.click()
  }
  func testSessionPreferencesAndTranscriptTogglesPersist() throws {
    select("Settings")
    choose(app.popUpButtons["session-terminal"], "Custom")
    reveal(app.textFields["custom-terminal-path"])
    replace(app.textFields["custom-terminal-path"], with: "/Applications/Fixture.app")
    XCTAssertEqual(
      (try settings()["session_terminal"] as? [String: Any])?["custom_path"] as? String,
      "/Applications/Fixture.app")
    choose(app.popUpButtons["session-terminal"], "Ghostty")
    for provider in ["codex", "claude", "grok", "junie"] {
      choose(app.popUpButtons["open-session-" + provider], "Terminal")
      XCTAssertEqual(
        (try settings()["session_open_preferences"] as? [String: String])?[provider], "terminal")
      choose(app.popUpButtons["open-session-" + provider], "Automatic")
      XCTAssertNil((try settings()["session_open_preferences"] as? [String: String])?[provider])
    }
    for (label, key, value) in [
      ("Mark activity stale after", "idle_timeout_seconds", "600"),
      ("Keep recent sessions for", "recent_session_retention_seconds", "86400"),
    ] {
      let field = app.textFields[key]
      reveal(field)
      replace(field, with: value)
      app.buttons[key + "-apply"].click()
      XCTAssertEqual((try settings()["agent_list"] as? [String: Any])?[key] as? Int, Int(value))
    }
    for provider in ["codex", "claude"] {
      let toggle = app.switches["transcript-" + provider]
      reveal(toggle)
      toggle.click()
      XCTAssertEqual((try settings()["transcript_monitoring"] as? [String: Bool])?[provider], true)
      toggle.click()
      XCTAssertEqual((try settings()["transcript_monitoring"] as? [String: Bool])?[provider], false)
    }
  }
  func testLidAnimationPreviewSaveValidationAndReset() throws {
    select("Settings")
    let duration = app.textFields["lid_open-duration"]
    reveal(duration)
    replace(duration, with: "-1")
    app.buttons["lid_open-save"].click()
    XCTAssertTrue(app.windows.buttons["OK"].firstMatch.waitForExistence(timeout: 3))
    app.windows.buttons["OK"].firstMatch.click()
    replace(duration, with: "2.5")
    app.buttons["lid_open-save"].click()
    XCTAssertEqual(
      (try settings()["lid_open_animation"] as? [String: Any])?["duration_seconds"] as? Double, 2.5)
    app.buttons["lid_open-reset"].click()
    XCTAssertEqual(
      (try settings()["lid_open_animation"] as? [String: Any])?["duration_seconds"] as? Double, 1)
    XCTAssertTrue(app.buttons["Replay"].firstMatch.exists)
    app.buttons["Replay"].firstMatch.click()
  }
  func testPhoneLinkValidationAndRemovalStayLocal() throws {
    select("Devices")
    reveal(app.textFields["phone-name"])
    replace(app.textFields["phone-name"], with: "Fixture Phone")
    let token = app.secureTextFields["phone-token"]
    replace(token, with: "invalid")
    app.buttons["Link phone"].click()
    XCTAssertTrue(app.staticTexts["Invalid phone token."].waitForExistence(timeout: 3))
    replace(token, with: String(repeating: "a", count: 64))
    app.buttons["Link phone"].click()
    XCTAssertTrue(app.staticTexts["Fixture Phone"].waitForExistence(timeout: 3))
    app.buttons["Remove"].click()
    XCTAssertFalse(app.staticTexts["Fixture Phone"].exists)
  }
  func testDoneDurationValidatesPersistsAndSurvivesRelaunch() throws {
    select("Settings")
    let seconds = app.textFields["done-seconds"]
    XCTAssertTrue(seconds.waitForExistence(timeout: 3))
    replace(seconds, with: "not a number")
    app.buttons["save-done-duration"].click()
    XCTAssertTrue(app.staticTexts["Enter a number of seconds."].waitForExistence(timeout: 3))
    app.windows.buttons["OK"].firstMatch.click()
    replace(seconds, with: "15")
    app.buttons["save-done-duration"].click()
    XCTAssertEqual(
      (try settings()["agent_list"] as? [String: Any])?["completed_visible_seconds"] as? Int, 15)
    app.terminate()
    app.launch()
    select("Settings")
    XCTAssertEqual(app.textFields["done-seconds"].value as? String, "15")
  }
  func testProfileSaveDeleteAndNavigation() throws {
    select("Animations")
    app.buttons["Save as…"].click()
    let name = app.textFields["profile-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 3))
    name.click()
    name.typeText("UI Test Profile")
    app.buttons["Save profile"].click()
    let saved = try settings()["agent_animation_profiles"] as? [String: Any]
    XCTAssertEqual(saved?.count, 1)
    app.buttons["Delete profile"].click()
    XCTAssertEqual((try settings()["agent_animation_profiles"] as? [String: Any])?.count, 0)
    for section in ["Sessions", "History", "Diagnostics", "Devices", "Overview"] {
      select(section)
      XCTAssertFalse(app.alerts.firstMatch.exists, "\(section) raised an error")
    }
  }
  func testHookEventsUpdateTheVisibleStateAndReturnToIdle() throws {
    let directory = root.appendingPathComponent("events")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("codex.jsonl")
    func event(_ name: String) throws {
      let row: [String: Any] = [
        "logged_at": Date().ISO8601Format(),
        "event": ["hook_event_name": name, "session_id": "ui-session", "session_title": "UI Test"],
      ]
      var data = (try? Data(contentsOf: file)) ?? Data()
      data.append(try JSONSerialization.data(withJSONObject: row))
      data.append(10)
      try data.write(to: file)
    }
    try event("UserPromptSubmit")
    XCTAssertTrue(app.staticTexts["current-state"].waitForExistence(timeout: 3))
    let working = NSPredicate(format: "value == %@ OR label == %@", "Working", "Working")
    expectation(for: working, evaluatedWith: app.staticTexts["current-state"])
    waitForExpectations(timeout: 5)
    try event("Stop")
    expectation(
      for: NSPredicate(format: "value == %@ OR label == %@", "Done", "Done"),
      evaluatedWith: app.staticTexts["current-state"])
    waitForExpectations(timeout: 5)
    expectation(
      for: NSPredicate(format: "value == %@ OR label == %@", "Idle", "Idle"),
      evaluatedWith: app.staticTexts["current-state"])
    waitForExpectations(timeout: 18)
  }
}

extension AppTests {
  func testHistoryMetricsAndHookInstallation() throws {
    select("History")
    let metric = app.popUpButtons["history-metric"]
    for choice in ["Battery", "Charger and battery power", "Sleep and lid", "Agent state"] {
      metric.click()
      app.menuItems[choice].firstMatch.click()
      XCTAssertEqual(metric.value as? String, choice)
    }
    select("Settings")
    let install = app.buttons["Install hooks"]
    // Scroll through the settings form just as a user would.
    for _ in 0..<12 where !install.isHittable {
      app.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -250)
    }
    XCTAssertTrue(install.isHittable)
    install.click()
    let config = root.appendingPathComponent("home/.codex/config.toml")
    XCTAssertTrue(try String(contentsOf: config).contains("# BEGIN SidePulse Swift hooks"))
    app.buttons["Remove hooks"].click()
    XCTAssertFalse(try String(contentsOf: config).contains("# BEGIN SidePulse Swift hooks"))
  }
}

extension AppTests {
  func testEveryAnimationStateIsVisibleAndEditsIndependently() throws {
    select("Animations")
    for state in [
      "working", "tool_running", "long_task_progress", "waiting_for_input", "blocked_error",
      "completed", "idle_ready", "unknown",
    ] {
      XCTAssertTrue(
        app.buttons["edit-" + state].isHittable,
        state + " must be visible without changing a dropdown")
      XCTAssertTrue(app.descendants(matching: .any)["preview-" + state].firstMatch.exists)
    }
    app.buttons["edit-working"].click()
    let editor = app.textViews["animation-program"]
    XCTAssertTrue(editor.waitForExistence(timeout: 3))
    replace(editor, with: "#FF0000")
    app.buttons["Save animation"].click()
    let mapping = try settings()["agent_animations"] as? [String: [String: Any]]
    XCTAssertEqual(mapping?["working"]?["custom_program"] as? String, "#FF0000")
    XCTAssertNil(mapping?["completed"])
  }
}

extension AppTests {
  func testBatteryAndSleepSettingsValidationAndPersistence() throws {
    select("Settings")
    replace(app.textFields["power-preview-seconds"], with: "3.5")
    replace(app.textFields["charger-watts"], with: "65")
    app.buttons["Save battery settings"].click()
    let battery = try settings()["battery_monitoring"] as? [String: Any]
    XCTAssertEqual(battery?["power_change_preview_seconds"] as? Double, 3.5)
    XCTAssertEqual(battery?["full_charge_watts"] as? Double, 65)
    let minimum = app.textFields["sleep-minimum"]
    for _ in 0..<12 where !minimum.isHittable {
      app.scrollViews.element(boundBy: 1).scroll(byDeltaX: 0, deltaY: -200)
    }
    replace(minimum, with: "101")
    app.buttons["save-sleep-minimum"].click()
    XCTAssertTrue(
      app.staticTexts["Enter a battery percentage from 0 to 100."].waitForExistence(timeout: 3))
    app.windows.buttons["OK"].firstMatch.click()
    replace(minimum, with: "25.5")
    app.buttons["save-sleep-minimum"].click()
    XCTAssertEqual(
      (try settings()["sleep_prevention"] as? [String: Any])?["min_battery_percent"] as? Double,
      25.5)
  }
  func testNamedAnimationsCanBeSavedAndReused() throws {
    select("Animations")
    app.buttons["edit-working"].click()
    replace(app.textViews["animation-program"], with: "#102030")
    replace(app.textFields["Reusable animation name"], with: "Reusable fixture")
    app.buttons["Save to library"].click()
    let registry = try XCTUnwrap(
      try settings()["custom_agent_animations"] as? [String: [String: Any]])
    XCTAssertTrue(registry.values.contains { $0["name"] as? String == "Reusable fixture" })
    app.buttons["Cancel"].click()
    app.buttons["edit-idle_ready"].click()
    let preset = app.descendants(matching: .any)["load-animation-preset"].firstMatch
    XCTAssertTrue(preset.waitForExistence(timeout: 5))
    preset.click()
    app.menuItems["Reusable fixture"].firstMatch.click()
    app.buttons["Save animation"].click()
    let entries = try settings()["agent_animations"] as? [String: [String: Any]]
    let id = try XCTUnwrap(entries?["idle_ready"]?["style"] as? String)
    XCTAssertEqual(registry[id]?["program"] as? String, "#102030")
    app.buttons["edit-idle_ready"].click()
    replace(app.textViews["animation-program"], with: "#405060")
    app.buttons["Update library animation"].click()
    let updated = try XCTUnwrap(
      try settings()["custom_agent_animations"] as? [String: [String: Any]])
    XCTAssertEqual(updated.count, 1)
    XCTAssertEqual(updated[id]?["program"] as? String, "#405060")
    app.buttons["Save as new"].click()
    replace(app.textFields["Reusable animation name"], with: "Second fixture")
    app.buttons["Save to library"].click()
    XCTAssertEqual((try settings()["custom_agent_animations"] as? [String: Any])?.count, 2)
    app.buttons["Cancel"].click()
    choose(app.popUpButtons["animation-profile"], "Cyan")
    choose(app.popUpButtons["animation-profile"], "Current")
    XCTAssertEqual(try settings()["swift_profile"] as? String, "current")
  }
}

extension AppTests {
  func testHistoryRangePersistsAcrossRelaunch() throws {
    select("History")
    let range = app.popUpButtons["history-range"]
    range.click()
    app.menuItems["Last 6 hours"].firstMatch.click()
    XCTAssertEqual(
      (try settings()["history"] as? [String: Any])?["timeframe_seconds"] as? Int, 21600)
    app.terminate()
    app.launch()
    select("History")
    XCTAssertTrue(
      range.label.contains("Last 6 hours")
        || (range.value as? String)?.contains("Last 6 hours") == true, range.debugDescription)
  }
  func testDisconnectedDevicePreferencesAndForget() throws {
    app.terminate()
    var config = try settings()
    let id = "/Volumes/Fixture Dot"
    config["devices"] = [
      ["id": id, "name": "Travel Dot", "brightness": 100, "led_display": "agent"]
    ]
    try JSONSerialization.data(withJSONObject: config).write(
      to: root.appendingPathComponent("settings.json"))
    app.launch()
    select("Devices")
    XCTAssertTrue(app.staticTexts["Travel Dot"].waitForExistence(timeout: 3))
    app.popUpButtons["device-display-" + id].click()
    app.menuItems["Battery"].firstMatch.click()
    XCTAssertEqual(
      (try settings()["devices"] as? [[String: Any]])?.first { $0["id"] as? String == id }?[
        "led_display"] as? String, "battery")
    app.buttons["forget-device-" + id].click()
    XCTAssertFalse(
      (try settings()["devices"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id })
    XCTAssertFalse(app.staticTexts["Travel Dot"].exists)
  }
}

extension AppTests {
  private func filePanel(_ url: URL, action: String) {
    let button = app.buttons[action].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey("g", modifierFlags: [.command, .shift])
    let location = app.textFields["PathTextField"]
    XCTAssertTrue(location.waitForExistence(timeout: 3), app.debugDescription)
    replace(location, with: action == "Save" ? url.deletingLastPathComponent().path : url.path)
    location.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(location.waitForNonExistence(timeout: 5))
    if action == "Save" {
      replace(app.textFields["saveAsNameTextField"], with: url.lastPathComponent)
    }
    button.click()
    XCTAssertTrue(button.waitForNonExistence(timeout: 5), app.debugDescription)
    if action == "Save" {
      let exists = NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) }
      expectation(for: exists, evaluatedWith: nil)
      waitForExpectations(timeout: 5)
    }
  }

  func testProfilesImportExportAndCancel() throws {
    select("Animations")
    app.buttons["Import…"].click()
    XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 3))
    app.buttons["Cancel"].firstMatch.click()
    app.buttons["Export…"].click()
    app.buttons["Cancel"].firstMatch.click()
    app.buttons["Export…"].click()
    let file = root.appendingPathComponent("roundtrip.json")
    filePanel(file, action: "Save")
    let exported = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    XCTAssertFalse(exported.isEmpty)
    app.buttons["Import…"].click()
    filePanel(file, action: "Open")
    XCTAssertFalse(app.alerts.firstMatch.exists)
    let invalid = root.appendingPathComponent("invalid.json")
    try Data("{invalid".utf8).write(to: invalid)
    app.buttons["Import…"].click()
    filePanel(invalid, action: "Open")
    XCTAssertTrue(app.windows.buttons["OK"].firstMatch.waitForExistence(timeout: 3))
    app.windows.buttons["OK"].firstMatch.click()
    app.buttons["Save as…"].click()
    app.buttons["Cancel"].click()
  }

  func testHistoryAndEventExportsContainRecordedData() throws {
    for format in ["CSV", "HTML"] {
      select("History")
      app.menuButtons["Export…"].click()
      app.menuItems[format].firstMatch.click()
      let history = root.appendingPathComponent("history." + format.lowercased())
      filePanel(history, action: "Save")
      XCTAssertTrue(
        try String(contentsOf: history).contains(format == "CSV" ? "time_utc" : "<!doctype html>"))
      select("Diagnostics")
      let export = app.buttons["Export event " + format + "…"]
      reveal(export)
      export.click()
      let audit = root.appendingPathComponent("events." + format.lowercased())
      filePanel(audit, action: "Save")
      XCTAssertFalse(try Data(contentsOf: audit).isEmpty)
    }
  }

  func testNotchPreviewAndAwakePreferencesPersist() throws {
    select("Settings")
    let notch = app.switches["notch-enabled"]
    reveal(notch)
    notch.click()
    XCTAssertEqual(try settings()["virtual_status_device_enabled"] as? Bool, true)
    choose(app.popUpButtons["notch-display"], "Battery")
    choose(app.popUpButtons["notch-display"], "Hidden")
    choose(app.popUpButtons["notch-display"], "Agent status")
    let brightness = app.sliders["notch-brightness"]
    reveal(brightness)
    brightness.adjust(toNormalizedSliderPosition: 0.4)
    XCTAssertNotNil(
      (try settings()["devices"] as? [[String: Any]])?.first {
        $0["id"] as? String == "virtual:status-bar"
      }?["brightness"])
    reveal(notch)
    notch.click()
    XCTAssertEqual(try settings()["virtual_status_device_enabled"] as? Bool, false)
    choose(app.popUpButtons["awake-policy"], "While agents work")
    XCTAssertEqual(try settings()["sleep_prevention_policy"] as? String, "agents")
    choose(app.popUpButtons["awake-policy"], "Never")
    XCTAssertEqual(try settings()["swift_keep_awake"] as? Bool, false)
    let timing = app.textFields["idle_timeout_seconds"]
    select("Overview")
    select("Settings")
    reveal(timing)
    replace(timing, with: "-1")
    app.buttons["idle_timeout_seconds-apply"].click()
    XCTAssertTrue(
      app.staticTexts["Enter a finite number of seconds, zero or more."].waitForExistence(
        timeout: 3))
    app.windows.buttons["OK"].firstMatch.click()
  }
}

extension AppTests {
  func testInitialSetupCanBeDeferredAndStaysDismissed() throws {
    app.terminate()
    var config = try settings()
    config["setup_screen_completed"] = false
    try JSONSerialization.data(withJSONObject: config).write(
      to: root.appendingPathComponent("settings.json"))
    app.launch()
    XCTAssertTrue(app.staticTexts["Welcome to SidePulse"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Set up SidePulse"].exists)
    app.buttons["Not now"].click()
    XCTAssertEqual(try settings()["setup_screen_completed"] as? Bool, true)
    app.terminate()
    app.launch()
    XCTAssertFalse(app.staticTexts["Welcome to SidePulse"].exists)
  }
}
