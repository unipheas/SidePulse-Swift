import XCTest

@testable import PulseCLI
@testable import PulseCore
@testable import SidePulse

/// Intercept only these read-only fixture requests. No real phone or firmware is contacted.
private final class DefaultNetworkResponse: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "api.github.com" || request.url?.host == "site.api.espn.com"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let data = Data("[]".utf8)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "2"])!
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
