import AVFoundation
import Foundation
import PulseCore

/// Convert the current microphone RMS to a smoothed VU meter. Audio samples stay in memory.
enum AudioMeter {
  private final class Level {
    let lock = NSLock()
    var rms: Double = 0
    func update(_ buffer: AVAudioPCMBuffer) {
      guard let samples = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return }
      var sum = 0.0
      for i in 0..<Int(buffer.frameLength) {
        let v = Double(samples[i])
        sum += v * v
      }
      let next = sqrt(sum / Double(buffer.frameLength))
      lock.withLock { rms = next }
    }
    func read() -> Double { lock.withLock { rms } }
  }
  static func run(device: Device?, dryRun: Bool) async throws {
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
      throw PulseError("Microphone access is required for the audio meter.")
    }
    let engine = AVAudioEngine()
    let level = Level()
    let input = engine.inputNode
    let format = input.inputFormat(forBus: 0)
    guard format.channelCount > 0, format.sampleRate > 0 else {
      throw PulseError("Select an input device in Sound settings.")
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in level.update(buffer)
    }
    defer {
      input.removeTap(onBus: 0)
      engine.stop()
    }
    try engine.start()
    var smoothed = 0.0
    var previous = ""
    let count = device?.count ?? 8
    while !Task.isCancelled {
      let db = 20 * log10(max(1e-9, level.read()))
      let target = pow(max(0, min(1, (db + 54) / 46)), 0.72)
      smoothed += (target - smoothed) * (1 - exp(-0.04 / (target > smoothed ? 0.045 : 0.32)))
      var parts: [String] = []
      for i in 0..<count {
        let position = Double(i) / Double(max(1, count - 1))
        let red = Int(min(1.0, position * 2.0) * 255.0)
        let green = Int(min(1.0, (1.0 - position) * 2.0) * 255.0)
        let color = String(format: "#%02X%02X00", red, green)
        let fill = max(0.0, min(1.0, smoothed * Double(count) - Double(i)))
        let brightness = Int(20.0 + 235.0 * fill)
        let dimmed = Programs.dim(color, brightness: brightness)
        parts.append("\(i):\(dimmed) 90ms cosine")
      }
      let program = parts.joined(separator: ";")
      if program != previous {
        if dryRun { print(program) } else { try device?.write(program) }
        previous = program
      }
      try await Task.sleep(for: .milliseconds(40))
    }
  }
}

enum Scoreboard {
  static func run(device: Device?, score: String?, dryRun: Bool) async throws {
    var previous: [Int] = []
    repeat {
      let goals: [Int]
      if let score {
        let parts = score.components(separatedBy: "-").compactMap(Int.init)
        guard score.range(of: #"^[0-9]+-[0-9]+$"#, options: .regularExpression) != nil,
          parts.count == 2, parts.allSatisfy({ $0 >= 0 })
        else {
          throw PulseError("Use a score such as 2-1.")
        }
        goals = parts
      } else {
        let url = URL(
          string: "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try JSONSerialization.jsonObject(with: data) as? JSONObject,
          let events = json["events"] as? [JSONObject]
        else { throw PulseError("Scoreboard unavailable.") }
        let matches = events.flatMap { $0["competitions"] as? [JSONObject] ?? [] }.map {
          $0["competitors"] as? [JSONObject] ?? []
        }
        var found: [Int]?
        for teams in matches {
          let pair = ["Spain", "Argentina"].compactMap { name -> Int? in
            let team = teams.first {
              ($0["team"] as? JSONObject)?["displayName"] as? String == name
            }
            return (team?["score"] as? String).flatMap(Int.init) ?? team?["score"] as? Int
          }
          if pair.count == 2 {
            found = pair
            break
          }
        }
        guard let found else {
          throw PulseError(
            "No Spain–Argentina match in the current feed. Use --score for a replay.")
        }
        goals = found
      }
      if goals != previous {
        let count = device?.count ?? 8
        let program = (0..<count).map { i in
          let left = i < count / 2
          let lit = left ? i < goals[0] : i >= count - min(goals[1], count / 2)
          let color = left ? "#FF0000" : "#0000FF"
          return "\(i):\(Programs.dim(color,brightness:lit ? 255 : 3)) 250ms cosine"
        }.joined(separator: ";")
        if dryRun { print(program) } else { try device?.write(program) }
        previous = goals
      }
      if score != nil { return }
      try await Task.sleep(for: .seconds(30))
    } while !Task.isCancelled
  }
}
