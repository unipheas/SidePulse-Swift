import Foundation

public enum Destination {
  case device(Device)
  case phone(Phone)
  public var name: String {
    switch self {
    case .device(let value): return value.name
    case .phone(let value): return value.name
    }
  }
  func matches(_ query: String) -> Bool {
    let key = query.lowercased()
    switch self {
    case .device(let device):
      return [
        "local", device.name.lowercased(), device.id.lowercased(),
        device.id.lowercased() + "/leds.led",
      ].contains(key)
    case .phone(let phone):
      return key == "phone" || key == phone.name.lowercased()
        || (key.count >= 4 && phone.id.lowercased().hasPrefix(key))
    }
  }
  public static func select(
    devices: [Device], phones: [Phone], requested: String?, all: Bool,
    hasProgram: Bool, notification: Bool, preferPhone: Bool
  ) throws -> [Destination] {
    let local = devices.map(Self.device)
    let mobile = phones.map(Self.phone)
    if all {
      guard requested == nil else { throw PulseError("Choose --all or --to.") }
      if notification && mobile.isEmpty { throw PulseError("Link a phone to send notifications.") }
      let selected = (hasProgram ? local : []) + mobile
      guard !selected.isEmpty else { throw PulseError("No destinations found.") }
      return selected
    }
    let candidates: [Self]
    if let requested {
      candidates = (local + mobile).filter { $0.matches(requested) }
    } else {
      candidates =
        notification || (preferPhone && !mobile.isEmpty) || local.isEmpty ? mobile : local
    }
    guard candidates.count == 1 else {
      throw PulseError(
        candidates.isEmpty
          ? "No matching SidePulse destination."
          : "Choose a destination using --to ID or use --all.")
    }
    if case .device = candidates[0], notification {
      throw PulseError("Choose a phone to display notifications.")
    }
    return candidates
  }
}
