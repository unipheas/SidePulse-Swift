import AppKit
import XCTest

@testable import PulseCore
@testable import SidePulse

final class TerminalIntegrationTests: IsolatedTests {
  @MainActor func testDefaultTerminalAdapterLaunchesSelectedAppWithResumeArguments() async throws {
    let app = root.appendingPathComponent("TerminalFixture.app")
    let contents = app.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/TerminalFixture")
    try Paths.directory(executable.deletingLastPathComponent())
    let identifier = "com.unipheas.SidePulseSwift.TerminalFixture." + UUID().uuidString
    let info: JSONObject = [
      "CFBundleIdentifier": identifier, "CFBundleName": "TerminalFixture",
      "CFBundleExecutable": "TerminalFixture", "CFBundlePackageType": "APPL",
      "LSUIElement": true,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let source = root.appendingPathComponent("main.swift")
    // The fixture records argv and quits. It never executes the supplied shell command.
    try Data(
      """
      import AppKit
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("arguments.json")
      try JSONSerialization.data(withJSONObject: Array(CommandLine.arguments.dropFirst())).write(to: file)
      DispatchQueue.main.async { app.terminate(nil) }
      app.run()
      """.utf8
    ).write(to: source)
    try SystemCommand.run("/usr/bin/xcrun", ["swiftc", source.path, "-o", executable.path])
    let registrar =
      "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    defer { _ = try? SystemCommand.run(registrar, ["-u", app.path]) }
    let arguments = root.appendingPathComponent("arguments.json")
    func waitForArguments() async throws -> [String] {
      for _ in 0..<100 {
        if let data = try? Data(contentsOf: arguments),
          let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
          return values
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw PulseError("Fixture app did not launch")
    }
    try SystemCommand.run("/usr/bin/open", ["-n", "-a", app.path, "--args", "preflight"])
    let preflight = try await waitForArguments()
    XCTAssertEqual(preflight, ["preflight"])
    try FileManager.default.removeItem(at: arguments)
    let settings: JSONObject = ["session_terminal": ["app": "custom", "custom_path": app.path]]
    let session = Session(
      provider: "codex", session: "test", name: "Test", event: "Stop", date: Date(), mode: .done)
    try MacActions().openSession(.terminal("fixture-command"), session, settings)
    let received = try await waitForArguments()
    XCTAssertEqual(Array(received.prefix(3)), ["-e", "/bin/zsh", "-lc"])
    XCTAssertTrue(received.last?.hasSuffix("; fixture-command") == true)
    XCTAssertTrue(received.last?.contains("SidePulse Codex Test") == true)
    try FileManager.default.removeItem(at: arguments)
    try MacActions().openSession(.link(app), session, settings)
    let opened = try await waitForArguments()
    XCTAssertEqual(opened, [])
    let unhandled = URL(
      string: "sidepulse-unregistered-" + UUID().uuidString.lowercased() + "://test")!
    XCTAssertThrowsError(try MacActions().openSession(.link(unhandled), session, settings))
  }
}
