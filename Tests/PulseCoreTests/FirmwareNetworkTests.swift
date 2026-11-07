import XCTest

@testable import PulseCore

private final class FirmwareResponse: URLProtocol {
  static var status = 200
  static var payload = Data()
  static var declaredLength: Int?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SidePulse-Swift")
    XCTAssertEqual(request.timeoutInterval, 30)
    let headers = Self.declaredLength.map { ["Content-Length": String($0)] }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.payload)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class FirmwareNetworkTests: IsolatedTests {
  func testFirmwareStreamValidatesHTTPAndBothSizeLimits() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FirmwareResponse.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    for (status, size, declared, success) in [
      (200, 3, 3, true), (503, 3, 3, false), (200, 0, Firmware.limit + 1, false),
      (200, Firmware.limit + 1, -1, false),
    ] {
      FirmwareResponse.status = status
      FirmwareResponse.payload = Data(repeating: 0x41, count: size)
      FirmwareResponse.declaredLength = declared < 0 ? nil : declared
      do {
        let data = try await Firmware.fetch(
          "https://fixture.invalid/firmware.zip", session: session)
        XCTAssertTrue(success)
        XCTAssertEqual(data, FirmwareResponse.payload)
      } catch { XCTAssertFalse(success, error.localizedDescription) }
    }
  }
  func testFirmwareSelectionRejectsInvalidVersionsMissingModelsAndChecksumMismatch() async throws {
    let device = try volume()
    for (version, file) in [("1.1.0", "/tmp/unused.zip"), ("../bad", nil)] {
      do {
        _ = try await Firmware.upgrade(
          device, version: version, file: file, dryRun: true,
          fetch: { _ in
            XCTFail("Invalid options must not download")
            return Data()
          })
        XCTFail("Expected invalid options")
      } catch {}
    }
    for mismatch in [false, true] {
      do {
        _ = try await Firmware.upgrade(
          device, version: "1.1.0", file: nil, dryRun: true,
          fetch: { address in
            if address.hasSuffix("SHA256SUMS.txt") {
              return Data(
                (String(repeating: "0", count: 64)
                  + "  sidepulse-\(mismatch ? "pro" : "dot")-1.1.0-ota.zip").utf8)
            }
            return Data("wrong digest".utf8)
          })
        XCTFail("Expected missing or invalid firmware")
      } catch {
        XCTAssertTrue(
          error.localizedDescription.contains(mismatch ? "checksum mismatch" : "No compatible"))
      }
    }
  }
}

extension FirmwareNetworkTests {
  func testMalformedReleaseListingFailsBeforeDownloadingAnArchive() async throws {
    do {
      _ = try await Firmware.upgrade(
        volume(), version: nil, file: nil, dryRun: true, fetch: { _ in Data("{}".utf8) })
      XCTFail("Expected missing releases")
    } catch { XCTAssertEqual(error.localizedDescription, "No compatible firmware release.") }
  }
}
