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
      "swift_mirror": false, "swift_closed_lid": "never", "sleep_prevention_policy": "never",
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
    app.staticTexts[title].firstMatch.click()
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
  func testDoneDurationValidatesPersistsAndSurvivesRelaunch() throws {
    select("Settings")
    let seconds = app.textFields["done-seconds"]
    XCTAssertTrue(seconds.waitForExistence(timeout: 3))
    replace(seconds, with: "not a number")
    app.buttons["Apply"].click()
    XCTAssertTrue(app.staticTexts["Enter a number of seconds."].waitForExistence(timeout: 3))
    app.buttons["OK"].click()
    replace(seconds, with: "15")
    app.buttons["Apply"].click()
    XCTAssertEqual(
      (try settings()["agent_list"] as? [String: Any])?["completed_visible_seconds"] as? Int, 15)
    app.terminate()
    app.launch()
    select("Settings")
    XCTAssertEqual(app.textFields["done-seconds"].value as? String, "15")
  }
  func testProfileSaveDeleteAndNavigation() throws {
    select("Animations")
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
