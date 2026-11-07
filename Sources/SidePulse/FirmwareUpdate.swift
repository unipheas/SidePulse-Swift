import PulseCore
import SwiftUI

@MainActor final class FirmwareUpdate: ObservableObject {
  @Published var selected: Device?
  @Published var confirm = false
  @Published private(set) var status = ""
  @Published private(set) var busy = false
  private let upgrade: (Device, Bool) async throws -> String
  init(upgrade: @escaping (Device, Bool) async throws -> String = FirmwareUpdate.perform) {
    self.upgrade = upgrade
  }
  nonisolated static func perform(_ device: Device, dry: Bool) async throws -> String {
    try await Firmware.upgrade(device, version: nil, file: nil, dryRun: dry)
  }
  func request(_ device: Device) {
    selected = device
    confirm = true
  }
  func install() async {
    confirm = false
    if let selected { await update(selected, dry: false) }
  }
  func update(_ device: Device, dry: Bool) async {
    guard !busy else { return }
    busy = true
    status = "Checking firmware…"
    defer { busy = false }
    do { status = try await upgrade(device, dry) } catch { status = error.localizedDescription }
  }
}
