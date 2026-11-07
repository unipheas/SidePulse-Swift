import AVFoundation
import XCTest

@testable import PulseCLI
@testable import PulseCore

final class ExampleTests: IsolatedTests {
  func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
    return buffer
  }
  func testAudioRMSAndEmptyBuffers() {
    let level = AudioMeter.Level()
    level.update(buffer([1, -1, 0, 0]))
    XCTAssertEqual(level.read(), sqrt(0.5), accuracy: 0.000001)
    level.update(buffer([]))
    XCTAssertEqual(level.read(), sqrt(0.5), accuracy: 0.000001)
    level.update(buffer([0, 0]))
    XCTAssertEqual(level.read(), 0)
  }
  func testAudioDenialAndStartFailureDoNotStartOrStopAnInactiveInput() async {
    for allowed in [false, true] {
      var started = false
      let input = AudioMeter.Input(
        authorize: { allowed },
        start: { _ in
          started = true
          throw PulseError("Input disconnected")
        }, stop: { XCTFail("Input did not start") })
      do {
        try await AudioMeter.run(device: nil, dryRun: true, input: input)
        XCTFail("Expected input failure")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(allowed ? "disconnected" : "Microphone"))
      }
      XCTAssertEqual(started, allowed)
    }
  }
  func testAudioSmoothingDecayDeduplicationAndCancellationReleaseInput() async throws {
    var level: AudioMeter.Level?
    var stopped = false
    var programs: [String] = []
    var frames = 0
    let input = AudioMeter.Input(
      authorize: { true },
      start: {
        level = $0
        $0.update(self.buffer([1]))
      }, stop: { stopped = true })
    do {
      try await AudioMeter.run(
        device: nil, dryRun: true, input: input,
        wait: {
          frames += 1
          level?.update(self.buffer([frames < 4 ? 1 : 0]))
          if frames == 200 { throw CancellationError() }
        }, output: { programs.append($0) })
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    XCTAssertTrue(stopped)
    XCTAssertGreaterThan(programs.count, 4)
    XCTAssertLessThan(programs.count, frames)
    XCTAssertNotEqual(programs[0], programs[2])
    XCTAssertTrue(programs.last!.contains("0:#001400"))
    for program in programs { XCTAssertNoThrow(try LEDPreview(program: program, count: 8)) }
  }
  func testAudioCanWriteToDeviceAndStopsAfterWriteFailure() async throws {
    let device = try volume()
    var stopped = false
    let input = AudioMeter.Input(
      authorize: { true }, start: { $0.update(self.buffer([0.5])) }, stop: { stopped = true })
    do {
      try await AudioMeter.run(
        device: device, dryRun: false, input: input, wait: { throw CancellationError() })
    } catch is CancellationError {}
    XCTAssertTrue(stopped)
    XCTAssertTrue(
      try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")).contains("cosine"))
    try FileManager.default.removeItem(at: device.root.appendingPathComponent("STATUS.TXT"))
    stopped = false
    do {
      try await AudioMeter.run(device: device, dryRun: false, input: input)
      XCTFail("Expected removed device")
    } catch { XCTAssertTrue(stopped) }
  }
  func feed(_ score: Int = 2) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "events": [
        [
          "competitions": [
            [
              "competitors": [
                ["team": ["displayName": "Spain"], "score": String(score)],
                ["team": ["displayName": "Argentina"], "score": 1],
              ]
            ]
          ]
        ]
      ]
    ])
  }
  func response(_ url: URL, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }
  func testScoreboardFeedUpdatesOnlyWhenGoalsChange() async throws {
    var polls = 0
    var programs = [String]()
    do {
      try await Scoreboard.run(
        device: nil, score: nil, dryRun: true,
        fetch: { url in
          polls += 1
          return (try self.feed(polls < 3 ? 2 : 3), self.response(url))
        }, wait: { if polls == 3 { throw CancellationError() } }, output: { programs.append($0) })
    } catch is CancellationError {}
    XCTAssertEqual(polls, 3)
    XCTAssertEqual(programs.count, 2)
    XCTAssertNotEqual(programs[0], programs[1])
    XCTAssertTrue(programs[0].contains("7:#0000FF"))
  }
  func testScoreboardRejectsBadScoresMissingMatchAndBrokenFeeds() async throws {
    for score in ["-1-2", "1-", "1-2-3", "a-b"] {
      do {
        try await Scoreboard.run(device: nil, score: score, dryRun: true)
        XCTFail("Expected invalid score")
      } catch {}
    }
    for (data, status) in [
      (Data("{}".utf8), 200), (Data("oops".utf8), 200), (try feed(), 503),
      (Data("{\"events\":[{}]}".utf8), 200),
    ] {
      do {
        try await Scoreboard.run(
          device: nil, score: nil, dryRun: true,
          fetch: { (data, self.response($0, status: status)) })
        XCTFail("Expected invalid feed")
      } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    let device = try volume("Dot")
    try await Scoreboard.run(device: device, score: "99-99", dryRun: false)
    XCTAssertEqual(
      try String(contentsOf: device.root.appendingPathComponent("LEDS.LED")),
      "0:#FF0000 250ms cosine;1:#0000FF 250ms cosine")
  }
  func testDeliveryAcceptsExplicitFilePathAndFileName() async throws {
    let device = try volume()
    for arguments in [
      ["--device", device.root.path, "--file-name", "CUSTOM.LED"],
      ["--device", device.root.appendingPathComponent("CUSTOM.LED").path],
    ] {
      Args.words = arguments + ["#123456"]
      try await CLI.deliver(preferPhone: false)
      XCTAssertEqual(
        try String(contentsOf: device.root.appendingPathComponent("CUSTOM.LED")), "#123456")
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: device.root.appendingPathComponent("LEDS.LED").path))
  }
}
