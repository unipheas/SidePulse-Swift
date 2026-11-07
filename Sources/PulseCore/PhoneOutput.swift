import Foundation

/// Track delivery per recipient so an unavailable phone cannot block the others.
public actor PhoneOutput {
  private struct Delivery {
    let program: String
    let retryAfter: Date
  }
  private var powerPreview = PowerChangePreview()
  private var deliveries = [String: Delivery]()
  private let phones: () throws -> [Phone]
  private let send: (Phone, String) async throws -> Void
  private let now: () -> Date
  public init(
    phones: @escaping () throws -> [Phone] = Bridge.phones,
    send: @escaping (Phone, String) async throws -> Void = {
      try await Bridge.push(to: $0.id, program: $1, title: nil, message: nil)
    }, now: @escaping () -> Date = Date.init
  ) {
    self.phones = phones
    self.send = send
    self.now = now
  }
  public func sync(mode: Mode, settings: JSONObject, battery: Battery? = Battery.read())
    async throws
  {
    guard settings["swift_phone_mirror"] as? Bool == true else {
      deliveries.removeAll()
      powerPreview = PowerChangePreview()
      return
    }
    let previewingBattery = powerPreview.update(battery: battery, settings: settings, now: now())
    let recipients = try phones().filter { phone in
      let display =
        Settings.device(phone.deviceID, in: settings)["led_display"] as? String
        ?? settings["led_display"] as? String
      return display != "custom"
    }
    // Include the destination and token: re-pairing must invalidate a prior success.
    func key(_ phone: Phone) -> String { phone.server + "/" + phone.token }
    let keys = Set(recipients.map(key))
    deliveries = deliveries.filter { keys.contains($0.key) }
    guard !recipients.isEmpty else { return }
    let program: String
    if previewingBattery, let battery {
      program = battery.program(count: 8, settings: settings)
    } else {
      program = try Programs.program(mode, count: 8, settings: settings)
    }
    var failures = [String]()
    for phone in recipients {
      let id = key(phone)
      if let previous = deliveries[id], previous.program == program,
        now() < previous.retryAfter
      {
        continue
      }
      deliveries[id] = Delivery(program: program, retryAfter: now().addingTimeInterval(10))
      do {
        try await send(phone, program)
        deliveries[id] = Delivery(program: program, retryAfter: .distantFuture)
      } catch { failures.append(phone.name + ": " + error.localizedDescription) }
    }
    if !failures.isEmpty { throw PulseError(failures.joined(separator: "\n")) }
  }
}
