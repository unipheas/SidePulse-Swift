import AppKit
import PulseCore
import ServiceManagement
import SwiftUI

@MainActor final class Dashboard: ObservableObject {
  @Published var mode = Mode.idle
  @Published var devices = [Device]()
  @Published var sessions = [Session]()
  @Published var settings: JSONObject = [:]
  @Published var problem: String?
  @Published var legacy = false
  @Published var login = SMAppService.mainApp.status == .enabled
  @Published var history = [(Date, Mode)]()
  let monitor = Monitor(), output = Output(), sleepOverride = SleepOverride()
  var timer: Timer?
  private let relay = Relay()
  private var relaying = false
  private var ticks = 0
  private var lastPhoneMode: Mode?
  private var sending = false
  private let discover: () -> [Device]
  private let outputInUse: () -> Bool
  init(
    discover: @escaping () -> [Device] = Device.discover,
    outputInUse: @escaping () -> Bool = {
      Output.legacyRunning() || Jobs.running(Jobs.prefix + "service")
    },
    poll: Bool = true
  ) {
    self.discover = discover
    self.outputInUse = outputInUse
    history = History.recent().suffix(500).map { ($0.date, $0.mode) }
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { try? self?.sleepOverride.restore() }
    }
    refresh()
    guard poll else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  var mirror: Bool { settings["swift_mirror"] as? Bool ?? true }
  func refresh() {
    do {
      settings = try Settings.read()
      if ticks % 5 == 0 {
        devices = discover()
        legacy = outputInUse()
      }
      ticks += 1
      sessions = monitor.sessions()
      mode = Monitor.aggregate(sessions, settings: settings)
      if history.last?.1 != mode {
        try History.record(mode, battery: Battery.read()?.percent)
        history.append((Date(), mode))
        if history.count > 500 { history.removeFirst() }
      }
      let battery = Battery.read()
      try sleepOverride.update(mode: mode, settings: settings, battery: battery, owner: !legacy)
      if mirror && !legacy {
        if !relaying {
          relaying = true
          let currentSessions = sessions
          Task {
            defer { relaying = false }
            do { try await relay.sync(currentSessions) } catch {
              problem = error.localizedDescription
            }
          }
        }
        output.keepAwake(
          settings["swift_keep_awake"] as? Bool == true
            && [.working, .tool, .progress].contains(mode) && (battery?.percent ?? 100) >= 20)
        try output.sync(devices: devices, mode: mode, settings: settings, battery: battery)
        if settings["swift_phone_mirror"] as? Bool == true, !sending, lastPhoneMode != mode {
          let current = mode
          let config = settings
          lastPhoneMode = current
          sending = true
          Task {
            defer { sending = false }
            do {
              let program = try Programs.program(current, count: 8, settings: config)
              for phone in try Bridge.phones() {
                try await Bridge.push(to: phone.id, program: program, title: nil, message: nil)
              }
            } catch { problem = error.localizedDescription }
          }
        } else if settings["swift_phone_mirror"] as? Bool != true {
          lastPhoneMode = nil
        }

      } else {
        output.reset()
        output.keepAwake(false)
      }
    } catch { problem = error.localizedDescription }
  }
  func change(_ body: (inout JSONObject) throws -> Void) {
    do {
      try Settings.update(body)
      refresh()
    } catch { problem = error.localizedDescription }
  }
  func setProfile(_ name: String) {
    do {
      try Profiles.select(name)
      refresh()
    } catch { problem = error.localizedDescription }
  }
}
