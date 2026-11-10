import Foundation

/// A fixed Pro layout: battery on LED 0, aggregated agent state on LEDs 1–7.
public enum HybridDisplay {
  public static func program(mode: Mode, battery: Battery?) -> String {
    let color: String
    if let battery {
      if battery.charging { color = "#FFFFFF" }
      else if battery.percent >= 75 || battery.charged { color = "#00B8A9" }
      else if battery.percent >= 50 { color = "#0077FF" }
      else if battery.percent >= 20 { color = "#7B2CBF" }
      else { color = "#5A189A" }
    } else { color = "#303030" }

    let clear = (1...7).map { "\($0):#000000" }.joined(separator: " ")
    let start = "0:\(color) \(clear)"
    switch mode {
    case .working, .tool, .progress:
      let wave = (1...7).map { index in
        let previous = index == 1 ? 7 : index - 1
        return "\(previous):#000000 160ms none;\(index):#00E5FF 160ms none"
      }
      return ([start] + wave + ["repeat"]).joined(separator: "\n")
    case .waiting, .blocked:
      let pulse = (1...7).map { "\($0):#FF9F1C 1600ms pulse" }.joined(separator: ";")
      return [start, pulse, "repeat"].joined(separator: "\n")
    case .idle:
      let pulse = (1...7).map { "\($0):#020204 1600ms pulse" }.joined(separator: ";")
      return [start, pulse, "repeat"].joined(separator: "\n")
    case .done:
      return "0:\(color) " + (1...7).map { "\($0):#B6FF00" }.joined(separator: " ")
    case .unknown:
      return "0:\(color) " + (1...7).map { "\($0):#808080" }.joined(separator: " ")
    }
  }
}
