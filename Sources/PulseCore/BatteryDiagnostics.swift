import Foundation
import IOKit

/// The hardware boundary is kept separate from property interpretation so recorded
/// IOKit snapshots can exercise the same conversion as a connected Mac.
public enum PowerRegistry {
  static func properties(
    _ name: String, plane: String? = nil,
    read: (io_registry_entry_t, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>) ->
      kern_return_t = {
        IORegistryEntryCreateCFProperties($0, $1, kCFAllocatorDefault, 0)
      }
  ) -> JSONObject? {
    let entry: io_registry_entry_t
    if let plane {
      entry = IORegistryEntryFromPath(kIOMainPortDefault, plane + ":/" + name)
    } else {
      entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(name))
    }
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    var result: Unmanaged<CFMutableDictionary>?
    guard read(entry, &result) == KERN_SUCCESS
    else { return nil }
    return result?.takeRetainedValue() as? JSONObject
  }
  public static let fullChargeWatts: Double = {
    baseline(properties("product", plane: "IODeviceTree"))
  }()
  static func baseline(_ source: JSONObject?) -> Double {
    let properties = source ?? [:]
    func string(_ key: String) -> String {
      if let data = properties[key] as? Data {
        return String(decoding: data, as: UTF8.self).lowercased()
      }
      return (properties[key] as? String ?? "").lowercased()
    }
    let model = string("product-name") + " " + string("product-description")
    let chip = string("product-soc-name")
    guard model.contains("macbook pro") else { return 100 }
    if model.contains("16-inch") { return 140 }
    if model.contains("14-inch") { return chip.contains("pro") || chip.contains("max") ? 96 : 70 }
    return 100
  }
}

public struct BatteryDiagnostics {
  /// Compatible names and units with the original battery status JSON.
  public let values: JSONObject
  public let adapterPower: Double
  public let charged: Bool
  private struct PowerProfile {
    let voltage: Double
    let current: Double
    var watts: Double { voltage * current }
    var json: [String: Double] { ["voltage": voltage, "current": current, "watts": watts] }
  }
  public init(properties p: JSONObject, fullWatts: Double = PowerRegistry.fullChargeWatts) {
    func number(_ key: String, in object: JSONObject, fallback: Double = 0) -> Double {
      guard let value = object[key] as? NSNumber, value.doubleValue.isFinite else {
        return fallback
      }
      return value.doubleValue.rounded(.towardZero)
    }
    func n(_ key: String, _ fallback: Double = 0) -> Double {
      number(key, in: p, fallback: fallback)
    }
    let adapter = p["AdapterDetails"] as? JSONObject ?? [:]
    func a(_ key: String, _ fallback: Double = 0) -> Double {
      number(key, in: adapter, fallback: fallback)
    }
    var profiles = (adapter["UsbHvcMenu"] as? [Any] ?? []).compactMap {
      entry -> PowerProfile? in
      guard let entry = entry as? JSONObject else { return nil }
      let voltage = number("MaxVoltage", in: entry) / 1000
      let current = number("MaxCurrent", in: entry) / 1000
      guard voltage > 0 && current > 0 else { return nil }
      return PowerProfile(voltage: voltage, current: current)
    }
    profiles.sort { $0.watts < $1.watts }
    let adapterVoltage = a("AdapterVoltage", a("Voltage")) / 1000
    let adapterCurrent = a("Current") / 1000
    let watts = a("Watts", -1)
    let power =
      watts > 0
      ? watts
      : adapterVoltage * adapterCurrent > 0
        ? adapterVoltage * adapterCurrent : profiles.last?.watts ?? 0
    let voltage = n("Voltage") / 1000
    let amperage = (n("Amperage") == 0 ? n("InstantAmperage") : n("Amperage")) / 1000
    let rawMax = n("AppleRawMaxCapacity", -1)
    let rawCurrent = n("AppleRawCurrentCapacity", -1)
    let design = n("DesignCapacity", -1)
    let capacity = n("CurrentCapacity")
    let percent = capacity >= 0 && capacity <= 100 ? capacity : n("StateOfCharge")
    let temperature = n("Temperature", -1)
    let baseline = fullWatts.isFinite ? max(1, fullWatts) : 100
    adapterPower = power
    charged = p["FullyCharged"] as? Bool ?? false
    values = [
      "percent": Int(min(100, max(0, percent))),
      "is_charging": p["IsCharging"] as? Bool ?? false,
      "is_charged": charged,
      "is_plugged": p["ExternalConnected"] as? Bool ?? false,
      "battery_present": p["BatteryInstalled"] as? Bool ?? true,
      "voltage": voltage, "amperage": amperage, "battery_watts": voltage * amperage,
      "time_to_full": Int(n("AvgTimeToFull", -1)), "time_to_empty": Int(n("AvgTimeToEmpty", -1)),
      "cycle_count": Int(n("CycleCount", -1)),
      "temperature_c": temperature >= 0 ? temperature / 100 as Any : NSNull(),
      "design_capacity_mah": Int(design),
      "max_capacity_mah": Int(rawMax > 0 ? rawMax : n("MaxCapacity", -1)),
      "current_capacity_mah": Int(rawCurrent >= 0 ? rawCurrent : n("CurrentCapacity", -1)),
      "health_percent": rawMax > 0 && design > 0
        ? Int((rawMax / design * 100).rounded(.toNearestOrEven)) : -1,
      "condition": n("PermanentFailureStatus") != 0
        ? "Service Recommended"
        : p["BatteryInstalled"] as? Bool == false ? "" : "Normal",
      "adapter_connected": !adapter.isEmpty, "adapter_watts": Int(watts),
      "adapter_voltage": adapterVoltage, "adapter_current": adapterCurrent, "adapter_power": power,
      "adapter_name": adapter["Name"] as? String ?? "",
      "adapter_manufacturer": adapter["Manufacturer"] as? String ?? "",
      "adapter_model": adapter["Model"] as? String ?? "",
      "adapter_serial": (adapter["SerialString"] ?? adapter["SerialNumber"]) as? String ?? "",
      "adapter_family": Self.family(Int(a("FamilyCode", -1))), "pd_profiles": profiles.map(\.json),
      "full_charge_watts": baseline, "charge_speed_ratio": min(1, max(0, power / baseline)),
    ]
  }
  static func family(_ code: Int) -> String {
    switch code {
    case 0xE000_4000...0xE000_4FFF: return "USB-C Power Delivery"
    case 3: return "MagSafe"
    case 4: return "MagSafe 2"
    case 0xFF00: return "USB-C"
    case 0...: return String(format: "0x%08lx", code)
    default: return ""
    }
  }
  public static func read(fullWatts: Double = PowerRegistry.fullChargeWatts) -> Self? {
    PowerRegistry.properties("AppleSmartBattery").map { Self(properties: $0, fullWatts: fullWatts) }
  }
}
