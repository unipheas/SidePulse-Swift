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
  @Published var needsSetup = false
  @Published var legacy = true
  @Published var login = SMAppService.mainApp.status == .enabled
  @Published var history = [(Date, Mode)]()
  let monitor = Monitor(), output = Output()
  let sleepOverride: SleepOverride
  var timer: Timer?
  private let relay = Relay()
  private var relaying = false
  private var ownsOutput = false
  private var ticks = 0
  private let phoneOutput: PhoneOutput
  private var sending = false
  private let notch = NotchDisplay()
  let actions: MacActions
  private let discover: () -> [Device]
  private let outputInUse: (() -> Bool)?
  private(set) var ownershipTask: Task<Void, Never>?
  init(
    discover: @escaping () -> [Device] = Device.discover,
    outputInUse: (() -> Bool)? = nil,
    poll: Bool = true, actions: MacActions? = nil,
    sleepOverride: SleepOverride = SleepOverride(), phoneOutput: PhoneOutput = PhoneOutput()
  ) {
    self.actions = actions ?? MacActions()
    self.sleepOverride = sleepOverride
    self.phoneOutput = phoneOutput
    self.discover = discover
    self.outputInUse = outputInUse
    do { try Settings.migrate() } catch { problem = error.localizedDescription }
    history = History.recent().suffix(500).map { ($0.date, $0.mode) }
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { try? self?.sleepOverride.restore() }
    }
    refresh()
    needsSetup = settings["setup_screen_completed"] as? Bool != true
    guard poll else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  var mirror: Bool { settings["swift_mirror"] as? Bool ?? true }
  var appearance: AppAppearance {
    AppAppearance(rawValue: settings["appearance"] as? String ?? "auto") ?? .auto
  }
  var menuBarVisible: Bool { settings["show_menu_bar_icon"] as? Bool ?? true }
  var menuBarInsertion: Binding<Bool> {
    Binding(get: { self.menuBarVisible }, set: menuBarVisibilityChanged)
  }
  func menuBarVisibilityChanged(_ visible: Bool) {
    guard menuBarVisible != visible else { return }
    // MenuBarExtra can report changes while SwiftUI is reconciling its scenes.
    Task { @MainActor in change { $0["show_menu_bar_icon"] = visible } }
  }
  func prepareInstallation(bundle: Bundle = .main) {
    guard bundle.bundleIdentifier == "com.unipheas.SidePulseSwift",
      let executable = bundle.executableURL,
      let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    else { return }
    do {
      try actions.refreshServices(
        executable.deletingLastPathComponent().appendingPathComponent("sidepulsectl"), version)
    } catch { problem = error.localizedDescription }
  }
  func refresh() {
    do {
      receiveSettings(try Settings.read())
      if ticks % 5 == 0 {
        let found = discover()
        if devices != found { devices = found }
        receiveSettings(try Settings.remember(devices, settings: settings))
        if let outputInUse {
          let active = outputInUse()
          if legacy != active { legacy = active }
        } else if ownershipTask == nil {
          // launchctl can wait for process teardown; never block animation frames.
          ownershipTask = Task { [weak self] in
            let active = await Task.detached(priority: .utility) {
              Output.legacyRunning() || Jobs.running(Jobs.prefix + "service")
            }.value
            if self?.legacy != active { self?.legacy = active }
            self?.ownershipTask = nil
          }
        }
      }
      ticks += 1
      let retention = Settings.seconds(
        settings, "recent_session_retention_seconds", default: 172800)
      let recent = monitor.sessions().filter { Date().timeIntervalSince($0.date) <= retention }
      if sessions != recent { sessions = recent }
      let currentMode = Monitor.aggregate(sessions, settings: settings)
      if mode != currentMode { mode = currentMode }
      if history.last?.1 != mode {
        history.append((Date(), mode))
        if history.count > 500 { history.removeFirst() }
      }
      let battery = Battery.read()
      do {
        try notch.sync(settings: settings, mode: mode, battery: battery)
      } catch {
        try? notch.update(nil)
        problem = "Notch lights: " + error.localizedDescription
      }
      do {
        try sleepOverride.update(mode: mode, settings: settings, battery: battery, owner: !legacy)
      } catch { problem = "Sleep control: " + error.localizedDescription }
      if !legacy {
        ownsOutput = true
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
        output.updateAwake(mode: mode, settings: settings, battery: battery)
        do {
          try output.sync(
            devices: devices, mode: mode, settings: settings, battery: battery,
            agentsActive: Monitor.hasActive(sessions, settings: settings))
        } catch { problem = error.localizedDescription }
        if !sending {
          let current = mode
          let config = settings
          sending = true
          Task {
            defer { sending = false }
            do {
              try await phoneOutput.sync(mode: current, settings: config, battery: battery)
            } catch { problem = error.localizedDescription }
          }
        }

      } else {
        if ownsOutput {
          ownsOutput = false
          Task { await relay.stop() }
        }
        output.reset()
        output.keepAwake(false)
      }
      try History.record(
        mode, battery: battery?.percent, snapshot: battery,
        keepingAwake: output.isKeepingAwake, power: PowerSnapshot.read())
    } catch { problem = error.localizedDescription }
  }
  private func receiveSettings(_ value: JSONObject) {
    if !NSDictionary(dictionary: settings).isEqual(to: value) {
      settings = value
      if NSApplication.shared.appearance?.name != appearance.native?.name {
        NSApplication.shared.appearance = appearance.native
      }
    }
  }
  deinit {
    timer?.invalidate()
    ownershipTask?.cancel()
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

extension Dashboard {
  func setLogin(_ enabled: Bool) {
    do { login = try actions.login(enabled) } catch { problem = error.localizedDescription }
  }
  func takeControl() {
    do {
      try actions.takeControl()
      legacy = false
      refresh()
    } catch { problem = error.localizedDescription }
  }
  func restorePrevious() {
    do {
      try actions.giveBack()
      legacy = true
      refresh()
    } catch { problem = error.localizedDescription }
  }
  func configureHooks(_ provider: String, install: Bool) {
    do { try actions.configureHooks(provider, install: install) } catch {
      problem = error.localizedDescription
    }
  }
  func setClosedLid(_ value: String) {
    guard value == "never" || actions.helperInstalled() else {
      problem = "Install the sleep helper below before enabling closed-lid operation."
      return
    }
    change { $0["swift_closed_lid"] = value }
  }
  func preview(_ source: String, on device: Device) {
    do {
      _ = try LEDPreview(program: source, count: device.count)
      try Settings.update {
        Settings.editDevice(
          device.id, in: &$0, values: ["led_display": "custom", "manual_program": source])
      }
      try device.write(source)
      refresh()
    } catch { problem = error.localizedDescription }
  }
  func toggleService(_ job: String) -> Bool {
    do {
      let running = try actions.job(job, start: !actions.jobRunning(job))
      refresh()
      return running
    } catch { problem = error.localizedDescription }
    return actions.jobRunning(job)
  }

  func preview(_ source: String, on phone: Phone) async {
    do {
      _ = try LEDPreview(program: source, count: 8)
      try Settings.update {
        Settings.editDevice(phone.deviceID, in: &$0, values: ["led_display": "custom"])
      }
      try await actions.previewPhone(phone, source)
      refresh()
    } catch { problem = error.localizedDescription }
  }

  func deferSetup() {
    do {
      try Settings.update { $0["setup_screen_completed"] = true }
      needsSetup = false
      refresh()
    } catch { problem = error.localizedDescription }
  }

}
