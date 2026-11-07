import XCTest

@testable import PulseCLI
@testable import PulseCore
@testable import SidePulse

/// Intercept only these read-only fixture requests. No real phone or firmware is contacted.
private final class DefaultNetworkResponse: URLProtocol {
  private static let lock = NSLock()
  private static var responses: [String: Data] = [:]
  static func fixture(_ values: [String: Data]) { lock.withLock { responses = values } }
  override class func canInit(with request: URLRequest) -> Bool {
    ["api.github.com", "raw.githubusercontent.com", "site.api.espn.com", "bridge.sidepulse.io"]
      .contains(request.url?.host ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let data = Self.lock.withLock { Self.responses[request.url!.absoluteString] ?? Data("[]".utf8) }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Length": String(data.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class DefaultNetworkTests: IsolatedTests {
  func testDefaultFirmwareAndScoreboardAdaptersValidateServerResponses() async throws {
    XCTAssertTrue(URLProtocol.registerClass(DefaultNetworkResponse.self))
    defer { URLProtocol.unregisterClass(DefaultNetworkResponse.self) }
    let device = try volume()
    do {
      _ = try await FirmwareUpdate.perform(device, dry: true)
      XCTFail("Empty firmware listing must be reported")
    } catch { XCTAssertEqual(error.localizedDescription, "No compatible firmware release.") }
    do {
      try await Scoreboard.run(device: nil, score: nil, dryRun: true)
      XCTFail("Malformed scoreboard must be reported")
    } catch { XCTAssertEqual(error.localizedDescription, "Scoreboard unavailable.") }
  }
}

extension DefaultNetworkTests {
  @MainActor func testDefaultPhonePreviewAdapterUsesOnlyTheInterceptedFixtureRequest() async throws
  {
    XCTAssertTrue(URLProtocol.registerClass(DefaultNetworkResponse.self))
    defer { URLProtocol.unregisterClass(DefaultNetworkResponse.self) }
    try Bridge.store(token: String(repeating: "a", count: 64), name: "Fixture Phone")
    let phone = try XCTUnwrap(Bridge.phones().first)
    try await MacActions().previewPhone(phone, "off")
  }
}

extension DefaultNetworkTests {
  @MainActor func testFirmwareControllerDefaultAdapterReportsUnavailableRelease() async throws {
    XCTAssertTrue(URLProtocol.registerClass(DefaultNetworkResponse.self))
    defer { URLProtocol.unregisterClass(DefaultNetworkResponse.self) }
    let controller = FirmwareUpdate()
    await controller.update(try volume(), dry: true)
    XCTAssertEqual(controller.status, "No compatible firmware release.")
    XCTAssertFalse(controller.busy)
  }
}

extension DefaultNetworkTests {
  @MainActor func testDefaultFirmwareAdapterVerifiesAnInterceptedReleaseWithoutFlashing()
    async throws
  {
    let archiveURL = try firmwareArchive()
    let archive = try Data(contentsOf: archiveURL)
    let base = "https://raw.githubusercontent.com/inteliwear/sidepulse/main/firmware/v1.1.0/"
    DefaultNetworkResponse.fixture([
      "https://api.github.com/repos/inteliwear/sidepulse/contents/firmware?ref=main": Data(
        #"[{"name":"v1.1.0"}]"#.utf8),
      base + "SHA256SUMS.txt": Data(
        (Firmware.digest(archive) + "  " + archiveURL.lastPathComponent).utf8),
      base + archiveURL.lastPathComponent: archive,
    ])
    XCTAssertTrue(URLProtocol.registerClass(DefaultNetworkResponse.self))
    defer {
      URLProtocol.unregisterClass(DefaultNetworkResponse.self)
      DefaultNetworkResponse.fixture([:])
    }
    let device = try volume()
    let controller = FirmwareUpdate()
    await controller.update(device, dry: true)
    XCTAssertEqual(controller.status, "Verified SidePulse Pro firmware 1.1.0 (dry run).")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: device.root.appendingPathComponent("FIRMWARE.BIN").path))
  }
}
