import Foundation
import IOKit.ps

public struct Battery: Sendable {
  public let percent: Int, charging: Bool, plugged: Bool, watts: Int
  public var charged = false
  public var adapterPower: Double? = nil
  public var batteryPower: Double? = nil
  public static func read() -> Battery? {
    read(system: System())
  }
  struct System {
    var info: () -> CFTypeRef? = { IOPSCopyPowerSourcesInfo()?.takeRetainedValue() }
    var sources: (CFTypeRef) -> [CFTypeRef]? = {
      IOPSCopyPowerSourcesList($0)?.takeRetainedValue() as? [CFTypeRef]
    }
    var description: (CFTypeRef, CFTypeRef) -> JSONObject? = {
      IOPSGetPowerSourceDescription($0, $1)?.takeUnretainedValue() as? JSONObject
    }
    var adapter: () -> JSONObject? = {
      IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? JSONObject
    }
    var diagnostics: () -> BatteryDiagnostics? = { BatteryDiagnostics.read() }
  }
  static func read(system: System) -> Battery? {
    guard let info = system.info(), let list = system.sources(info)
    else { return nil }
    for source in list {
      guard
        let data = system.description(info, source),
        data["Type"] as? String == "InternalBattery",
        let capacity = data["Current Capacity"] as? Int,
        let maxCapacity = data["Max Capacity"] as? Int, maxCapacity > 0
      else { continue }
      let diagnostics = system.diagnostics()
      return Battery(
        percent: min(100, max(0, capacity * 100 / maxCapacity)),
        charging: data["Is Charging"] as? Bool == true,
        plugged: data["Power Source State"] as? String == "AC Power",
        watts: system.adapter()?["Watts"] as? Int ?? 0, charged: diagnostics?.charged ?? false,
        adapterPower: diagnostics?.adapterPower,
        batteryPower: diagnostics?.values["battery_watts"] as? Double)
    }
    return nil
  }
  public func program(count: Int, settings: JSONObject) -> String {
    program(
      count: count,
      fullWatts: (settings["battery_monitoring"] as? JSONObject)?["full_charge_watts"] as? Double
        ?? PowerRegistry.fullChargeWatts)
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
