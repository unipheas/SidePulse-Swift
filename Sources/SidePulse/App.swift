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
  let monitor = Monitor(), output = Output()
  var timer: Timer?
  private var ticks = 0
  init() {
    history = History.recent().suffix(500).map { ($0.date, $0.mode) }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  var mirror: Bool { settings["swift_mirror"] as? Bool ?? true }
  func refresh() {
    do {
      settings = try Settings.read()
      if ticks % 5 == 0 {
        devices = Device.discover()
        legacy = Output.legacyRunning() || Jobs.running(Jobs.prefix + "service")
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
      if mirror && !legacy {
        output.keepAwake(
          settings["swift_keep_awake"] as? Bool == true
            && [.working, .tool, .progress].contains(mode) && (battery?.percent ?? 100) >= 20)
        try output.sync(devices: devices, mode: mode, settings: settings, battery: battery)
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

@main struct SidePulseApp: App {
  @StateObject private var model = Dashboard()
  var body: some Scene {
    Window("SidePulse", id: "main") {
      DashboardView().environmentObject(model)
        .alert(
          "SidePulse",
          isPresented: Binding(
            get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
          Button("OK") { model.problem = nil }
        } message: {
          Text(model.problem ?? "")
        }
    }.defaultSize(width: 800, height: 535)
    Window("Virtual SidePulse", id: "leds") {
      LightBar(
        source: (try? Programs.program(model.mode, count: 8, settings: model.settings)) ?? "off",
        count: 8
      )
      .frame(minWidth: 280, minHeight: 80).padding(8)
    }.defaultSize(width: 420, height: 100).windowResizability(.contentSize)
    MenuBarExtra(
      "SidePulse · \(model.mode.label)",
      systemImage: model.mode == .idle ? "waveform" : "waveform.circle.fill"
    ) {
      MenuPanel().environmentObject(model)
    }
  }
}

struct MenuPanel: View {
  @EnvironmentObject var model: Dashboard
  @Environment(\.openWindow) var openWindow
  var body: some View {
    Text(model.mode.label)
    ForEach(model.sessions.prefix(5)) { item in Text("\(item.name) · \(item.mode.label)") }
    Divider()
    Button("Open SidePulse") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }
    Button("Open virtual LEDs") { openWindow(id: "leds") }
    Button("Quit SidePulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}

enum SectionName: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case sessions = "Sessions"
  case animations = "Animations"
  case settings = "Settings"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: return "dot.radiowaves.left.and.right"
    case .sessions: return "clock.arrow.circlepath"
    case .animations: return "light.beacon.max"
    case .settings: return "slider.horizontal.3"
    }
  }
}
struct DashboardView: View {
  @EnvironmentObject var model: Dashboard
  @State private var selection: SectionName? = .overview
  var body: some View {
    NavigationSplitView {
      List(SectionName.allCases, selection: $selection) { item in
        Label(item.rawValue, systemImage: item.symbol).tag(item)
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 205)
    } detail: {
      Group {
        switch selection ?? .overview {
        case .overview: Overview()
        case .sessions: SessionList()
        case .animations: Animations()
        case .settings: Preferences()
        }
      }.navigationTitle((selection ?? .overview).rawValue)
    }.frame(minWidth: 675, minHeight: 460)
  }
}

struct Overview: View {
  @EnvironmentObject var model: Dashboard
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline) {
          Image(systemName: "waveform.path.ecg").foregroundStyle(.teal)
          Text(model.mode.label).font(.system(size: 32, weight: .semibold, design: .rounded))
          Spacer()
          if let first = model.sessions.first {
            Text(first.provider.capitalized).foregroundStyle(.secondary)
          }
        }
        let count = model.devices.first?.count ?? 8
        LightBar(
          source: (try? Programs.program(model.mode, count: count, settings: model.settings))
            ?? "off", count: count)
        Text("Devices").font(.headline)
        if model.devices.isEmpty {
          ContentUnavailableView(
            "Connect a SidePulse", systemImage: "sdcard",
            description: Text("Insert a Pro card or connect a Dot over USB."))
        } else {
          ForEach(model.devices) { device in
            HStack {
              Image(systemName: device.model == "Pro" ? "sdcard.fill" : "cable.connector")
                .foregroundStyle(.teal)
              VStack(alignment: .leading) {
                Text("SidePulse \(device.model)").bold()
                Text(device.root.path).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text("Firmware \(device.firmware)").font(.callout.monospacedDigit()).foregroundStyle(
                .secondary)
            }
          }
        }
        if model.legacy {
          Label(
            "The existing SidePulse service controls the lights. Swift is previewing live status.",
            systemImage: "eye"
          ).font(.callout).foregroundStyle(.secondary)
        }
        if !model.history.isEmpty {
          Divider()
          Text("Recent changes").font(.headline)
          ForEach(Array(model.history.suffix(4).reversed()), id: \.0) { date, mode in
            HStack {
              Text(mode.label)
              Spacer()
              Text(date, style: .time).foregroundStyle(.secondary).monospacedDigit()
            }
          }
        }
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct LightBar: View {
  var source: String
  var count: Int
  @State private var simulator: LEDPreview?
  @State private var start = Date()
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading) {
      TimelineView(.animation(minimumInterval: 1 / 20)) { time in
        let rgb =
          simulator?.frame(milliseconds: Int(time.date.timeIntervalSince(start) * 1000)) ?? []
        HStack(spacing: 10) {
          ForEach(0..<count, id: \.self) { index in
            let i = index * 3
            let color =
              rgb.count > i + 2
              ? Color(
                red: Double(rgb[i]) / 255, green: Double(rgb[i + 1]) / 255,
                blue: Double(rgb[i + 2]) / 255) : Color.black
            RoundedRectangle(cornerRadius: 8).fill(color)
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 1))
              .shadow(color: color.opacity(0.55), radius: 7)
              .frame(maxWidth: 54).frame(height: 35)
          }
        }.padding(26).frame(maxWidth: .infinity).background(
          Color(red: 0.055, green: 0.073, blue: 0.085), in: RoundedRectangle(cornerRadius: 15))
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.task(id: "\(count):\(source)") {
      do {
        simulator = try LEDPreview(program: source, count: count)
        start = Date()
        error = nil
      } catch {
        simulator = nil
        self.error = error.localizedDescription
      }
    }.accessibilityLabel("LED animation preview")
  }
}

struct SessionList: View {
  @EnvironmentObject var model: Dashboard
  var body: some View {
    if model.sessions.isEmpty {
      ContentUnavailableView(
        "Waiting for agent activity", systemImage: "terminal",
        description: Text("Configure agent hooks in Settings or use your existing SidePulse hooks.")
      )
    } else {
      List(model.sessions.prefix(100)) { item in
        HStack {
          VStack(alignment: .leading) {
            Text(item.name).font(.headline)
            Text(item.provider.capitalized + " · " + item.event).font(.caption).foregroundStyle(
              .secondary)
          }
          Spacer()
          VStack(alignment: .trailing) {
            Text(item.mode.label)
            Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.vertical, 4)
      }
    }
  }
}

struct Animations: View {
  @EnvironmentObject var model: Dashboard
  @State var selected = Mode.working
  @State var source = ""
  @State var count = 8
  func load() {
    source = (try? Programs.program(selected, count: count, settings: model.settings)) ?? "off"
  }
  var body: some View {
    Form {
      Picker(
        "Profile",
        selection: Binding(
          get: { model.settings["swift_profile"] as? String ?? "current" },
          set: {
            model.setProfile($0)
            load()
          })
      ) {
        Text("Current").tag("current")
        let saved = model.settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
        ForEach(saved.keys.sorted(), id: \.self) { key in
          Text(saved[key]?["name"] as? String ?? key).tag(key)
        }
        ForEach(["cyan", "ember", "purple"], id: \.self) { Text($0.capitalized).tag($0) }
      }
      Picker("State", selection: $selected) {
        ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      Picker("Preview device", selection: $count) {
        Text("Pro · 8 LEDs").tag(8)
        Text("Dot · 2 LEDs").tag(2)
      }
      LightBar(source: source, count: count)
      TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 85)
      HStack {
        Menu("Load preset") {
          ForEach(Programs.animationNames, id: \.self) { name in
            Button(name) { source = (try? Programs.preset(name, count: count)) ?? source }
          }
        }
        Button("Import…") {
          let panel = NSOpenPanel()
          panel.allowedContentTypes = [.json]
          if panel.runModal() == .OK, let url = panel.url {
            do {
              try Profiles.load(from: url)
              model.refresh()
              load()
            } catch { model.problem = error.localizedDescription }
          }
        }
        Button("Export…") {
          let panel = NSSavePanel()
          panel.nameFieldStringValue = "SidePulse Profile.json"
          if panel.runModal() == .OK, let url = panel.url {
            do { try Profiles.export(to: url) } catch { model.problem = error.localizedDescription }
          }
        }
        Spacer()
        Button("Save animation") {
          do {
            _ = try LEDPreview(program: source, count: count)
            model.change {
              var mapping = $0["agent_animations"] as? [String: JSONObject] ?? [:]
              mapping[selected.rawValue] = ["style": "custom", "custom_program": source]
              $0["agent_animations"] = mapping
              $0["swift_profile"] = "current"
            }
          } catch { model.problem = error.localizedDescription }
        }
      }
    }.formStyle(.grouped).onAppear(perform: load).onChange(of: selected) { load() }.onChange(
      of: count
    ) { load() }
  }
}

struct Preferences: View {
  @EnvironmentObject var model: Dashboard
  @State var seconds = ""
  @State var provider = "codex"
  var body: some View {
    Form {
      Section("Agent display") {
        HStack {
          Text("Show Done for")
          Spacer()
          TextField("Seconds", text: $seconds).frame(width: 70)
          Text("seconds")
          Button("Apply") {
            guard let value = Double(seconds) else {
              model.problem = "Enter a number of seconds."
              return
            }
            do {
              try Settings.setDone(value)
              model.refresh()
            } catch { model.problem = error.localizedDescription }
          }
        }
        if model.legacy && !Jobs.running(Jobs.prefix + "service") {
          Button("Use Swift for device output") {
            do {
              try Jobs.takeControl()
              model.legacy = false
              model.refresh()
            } catch { model.problem = error.localizedDescription }
          }
        }
        if let paused = model.settings["swift_paused_jobs"] as? [String], !paused.isEmpty {
          Button("Restore original SidePulse service") {
            do {
              try Jobs.giveBack()
              model.legacy = true
              model.refresh()
            } catch { model.problem = error.localizedDescription }
          }
        }
        Toggle(
          "Mirror status on connected devices",
          isOn: Binding(
            get: { model.mirror }, set: { value in model.change { $0["swift_mirror"] = value } }))
        ForEach(model.devices) { device in
          let rows = model.settings["devices"] as? [JSONObject] ?? []
          let current = rows.first { $0["id"] as? String == device.id }
          Picker(
            device.name,
            selection: Binding(
              get: { current?["led_display"] as? String ?? "agent" },
              set: { value in
                model.change { settings in
                  var devices = settings["devices"] as? [JSONObject] ?? []
                  var entry =
                    devices.first { $0["id"] as? String == device.id } ?? ["id": device.id]
                  entry["led_display"] = value
                  devices.removeAll { $0["id"] as? String == device.id }
                  devices.append(entry)
                  settings["devices"] = devices
                }
              })
          ) {
            Text("Agent status").tag("agent")
            Text("Battery").tag("battery")
            Text("Manual").tag("custom")
          }
        }
      }
      Section("Mac") {
        Toggle(
          "Open at login",
          isOn: Binding(
            get: { model.login },
            set: { value in
              do {
                if value {
                  try SMAppService.mainApp.register()
                } else {
                  try SMAppService.mainApp.unregister()
                }
                model.login = SMAppService.mainApp.status == .enabled
              } catch { model.problem = error.localizedDescription }
            }))
        Toggle(
          "Keep Mac awake during active work",
          isOn: Binding(
            get: { model.settings["swift_keep_awake"] as? Bool ?? false },
            set: { value in model.change { $0["swift_keep_awake"] = value } }))
      }
      Section("Agent hooks") {
        Picker("Provider", selection: $provider) {
          ForEach(providers, id: \.self) { Text($0.capitalized).tag($0) }
        }
        HStack {
          Button("Install hooks") { configure(true) }
          Button("Remove Swift hooks") { configure(false) }
        }
      }
    }.formStyle(.grouped).onAppear {
      seconds = String(
        format: "%g", Settings.seconds(model.settings, "completed_visible_seconds", default: 1200))
    }
  }
  func configure(_ install: Bool) {
    guard
      let cli = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
        "sidepulse-swift"), FileManager.default.isExecutableFile(atPath: cli.path)
    else {
      model.problem = "Build and launch the packaged app to configure hooks."
      return
    }
    do { try Hooks.configure(provider, executable: cli, install: install) } catch {
      model.problem = error.localizedDescription
    }
  }
}
