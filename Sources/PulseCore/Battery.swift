import Foundation
import IOKit.ps

public struct Battery: Sendable {
  public let percent: Int, charging: Bool, plugged: Bool, watts: Int
  public var charged = false
  public var adapterPower: Double? = nil
  public static func read() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in list {
      guard
        let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? JSONObject,
        data["Type"] as? String == "InternalBattery",
        let capacity = data["Current Capacity"] as? Int,
        let maxCapacity = data["Max Capacity"] as? Int, maxCapacity > 0
      else { continue }
      let diagnostics = BatteryDiagnostics.read()
      return Battery(
        percent: min(100, max(0, capacity * 100 / maxCapacity)),
        charging: data["Is Charging"] as? Bool == true,
        plugged: data["Power Source State"] as? String == "AC Power",
        watts: (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? JSONObject)?["Watts"]
          as? Int ?? 0, charged: diagnostics?.charged ?? false,
        adapterPower: diagnostics?.adapterPower)
    }
    return nil
  }
  public func program(count requested: Int, fullWatts: Double = PowerRegistry.fullChargeWatts)
    -> String
  {
    let count = min(8, max(1, requested))
    let percent = charged ? 100 : min(100, max(0, self.percent))
    let fill = Double(count) * (Double(percent) / 100)
    let pulsing = plugged && charging && percent < 100
    let color =
      pulsing ? "#80FFC8" : percent <= 20 ? "#FF2600" : percent <= 50 ? "#FFB000" : "#00FF66"
    let colors = (0..<count).map { index in
      Programs.scaleColor(color, by: max(0, min(1, fill - Double(index))))
    }
    var lines = [
      colors.enumerated().map { "\($0.offset):\($0.element) 360ms ease" }.joined(separator: ";")
    ]
    if pulsing {
      let speed = min(1, max(0, (adapterPower ?? Double(watts)) / max(1, fullWatts)))
      let pulse = Int((180 + 1220 * speed).rounded(.toNearestOrEven))
      let cycle = Int((max(0.9, 3 - 2.1 * speed) * 1000).rounded(.toNearestOrEven))
      let frontier = min(count - 1, Int(fill))
      lines.append("\(frontier):\(color) \(pulse)ms pulse")
      let hold = cycle - 360 - pulse
      if hold > 0 { lines.append("\(frontier):\(colors[frontier]) \(hold)ms none") }
      lines.append("repeat")
    }
    return lines.joined(separator: "\n")
  }
}
