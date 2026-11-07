import XCTest

@testable import PulseCLI
@testable import PulseCore

final class RemainingBoundaryTests: IsolatedTests {
  func testProfileImportWithoutCustomLibraryAndUnnamedLibraryItems() throws {
    XCTAssertThrowsError(try Profiles.delete("profile:absent"))
    XCTAssertThrowsError(
      try Settings.setAnimation(.idle, program: "off", libraryID: "custom:absent"))
    let file = root.appendingPathComponent("profile.json")
    var mapping = try Programs.profile("cyan")
    var doc: JSONObject = [
      "format": "sidepulse-animation-profile", "version": 1, "name": "Basic", "animations": mapping,
    ]
    try saveObject(doc, to: file)
    try Profiles.load(from: file)
    mapping[Mode.idle.rawValue] = "custom:unnamed"
    doc["animations"] = mapping
    doc["custom_animations"] = ["custom:unnamed": ["program": "off"]]
    try saveObject(doc, to: file)
    try Profiles.load(from: file)
    let library = try XCTUnwrap(Settings.read()["custom_agent_animations"] as? [String: JSONObject])
    XCTAssertEqual(library["custom:unnamed"]?["name"] as? String, "custom:unnamed")
  }

  func testDefaultTransportAdaptersRejectNonDeviceFixtures() throws {
    let device = try volume()
    try Data().write(to: device.root.appendingPathComponent("STATUS.TXT"))
    XCTAssertThrowsError(try Device.inspect(device.root))
    try Data("release_version 1.1.0\n".utf8).write(
      to: device.root.appendingPathComponent("STATUS.TXT"))
    XCTAssertEqual(try Device.inspect(device.root).serial, "")
    let transport = Device.Transport()
    XCTAssertThrowsError(try transport.pro([1], root.appendingPathComponent("missing")))
    XCTAssertThrowsError(try transport.dot([1], root.appendingPathComponent("missing")))
    var failing = transport
    failing.openFile = { _, _ in
      errno = 9999
      return -1
    }
    XCTAssertThrowsError(try Device.inspect(device.root).write("off", transport: failing)) {
      error in
      XCTAssertEqual((error as? POSIXError)?.code, .EIO)
    }
  }

  func testDefaultDotWaitAllowsAnAcknowledgementOnNextPoll() throws {
    var transaction: UInt16 = 0
    var polls = 0
    try DotChannel.upload(
      [1],
      readStatus: {
        polls += 1
        var status = Array("SPC2".utf8) + [UInt8](repeating: 0, count: 12)
        if polls >= 3 {
          status[4] = UInt8(truncatingIfNeeded: transaction)
          status[5] = UInt8(transaction >> 8)
          status[6] = 3
          status[8] = 1
          status[10] = 1
          status[12] = 1
        }
        return status
      },
      submit: {
        transaction = $0
        XCTAssertEqual($1, [1])
      })
    XCTAssertEqual(polls, 3)
  }

  func testDefaultAppOpenRejectsMissingBundleWithoutOpeningOtherApps() throws {
    let executable = root.appendingPathComponent("Missing.app/Contents/MacOS/sidepulsectl")
    XCTAssertThrowsError(try AppInstallation.open(executable: executable))
    Args.words = ["start", "--foreground"]
    XCTAssertThrowsError(try CLI.appCommand(executable: executable))
  }

  func testDefaultContinuousReportAndFollowWaitCanBeCancelled() async throws {
    let battery = Battery(percent: 50, charging: false, plugged: false, watts: 0)
    Args.words = ["leds"]
    try await Task {
      try await CLI.batteryCommand(
        read: { battery }, discover: { [] },
        wait: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
        })
    }.value
    Args.words = ["--device", root.appendingPathComponent("missing").path]
    try await Task {
      try await CLI.monitor(
        "leds", legacyRunning: { false },
        wait: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
        })
    }.value
    Args.words = ["logs", "--follow"]
    let follow = Task { try await CLI.serviceCommand("service") }
    try await Task.sleep(for: .milliseconds(20))
    follow.cancel()
    do {
      try await follow.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
  }
}

extension RemainingBoundaryTests {
  func testDefaultScoreboardWaitIsCancellable() async throws {
    let task = Task {
      try await Scoreboard.run(
        device: nil, score: nil, dryRun: true,
        fetch: { url in
          let json: JSONObject = [
            "events": [
              [
                "competitions": [
                  [
                    "competitors": [
                      ["team": ["displayName": "Spain"], "score": "1"],
                      ["team": ["displayName": "Argentina"], "score": "2"],
                    ]
                  ]
                ]
              ]
            ]
          ]
          return (
            try JSONSerialization.data(withJSONObject: json),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        }, output: { _ in })
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
  }

  func testDefaultAwakePolicyAndSnapshotChargerFallback() throws {
    let output = Output()
    let battery = Battery(percent: 50, charging: false, plugged: false, watts: 42)
    output.updateAwake(
      mode: .idle, settings: ["sleep_prevention_policy": "never"], battery: battery)
    XCTAssertFalse(output.isKeepingAwake)
    try History.record(.idle, battery: 50, snapshot: battery)
    XCTAssertEqual(History.recent().last?.chargerWatts, 42)
    _ = Jobs.running("fixture-absent", scope: .auto)
    XCTAssertEqual(Jobs.logDirectory(scope: .auto), Paths.support)
    XCTAssertThrowsError(
      try Jobs.configure("unknown", executable: root, start: false, scope: .auto))
    try Jobs.giveBack()
  }
}
