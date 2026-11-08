import Foundation
import PulseCore

extension CLI {
  static func deliver(
    preferPhone: Bool, discover: () -> [Device] = Device.discover,
    push: (String?, String?, String?, String?) async throws -> Void = Bridge.push
  ) async throws {
    let path = try Args.option("--device")
    let fileName = try Args.option("--file-name") ?? "LEDS.LED"
    let all = Args.flag("--all")
    let dry = Args.flag("--dry-run")
    let requested = try Args.option("--to")
    let title = try Args.option("--title")
    let message = try Args.option("--message")
    let notification = title != nil || message != nil
    guard path == nil || (!all && requested == nil) else {
      throw PulseError("--device conflicts with --all or --to.")
    }
    let source = Args.words.isEmpty && notification ? nil : try Args.program()
    let devices: [Device]
    if let path {
      devices = [try Device.inspect(URL(fileURLWithPath: path), fileName: fileName)]
    } else {
      devices = try discover().map { try Device.inspect($0.root, fileName: fileName) }
    }
    let destinations = try Destination.select(
      devices: devices, phones: path == nil ? Bridge.phones() : [],
      requested: path == nil ? requested : "local", all: all, hasProgram: source != nil,
      notification: notification, preferPhone: preferPhone)
    var failures = [String]()
    for target in destinations {
      if dry {
        print("Would send to " + target.name)
        continue
      }
      do {
        switch target {
        case .device(let device):
          guard let source else { throw PulseError("Supply an LED program.") }
          try device.write(source)
        case .phone(let phone):
          try await push(phone.id, source, title, message)
        }
        print("Sent to " + target.name)
      } catch { failures.append(target.name + ": " + error.localizedDescription) }
    }
    if !failures.isEmpty { throw PulseError(failures.joined(separator: "\n")) }
  }
}
