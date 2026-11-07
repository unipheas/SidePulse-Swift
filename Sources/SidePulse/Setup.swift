import PulseCore
import SwiftUI

@MainActor final class Setup: ObservableObject {
  @Published var login = false
  @Published var protectCard = true
  @Published var installHooks = true
  @Published var sleepHelper = false
  @Published private(set) var busy = false
  @Published var problem: String?

  func finish(using model: Dashboard) async {
    guard !busy else { return }
    busy = true
    problem = nil
    defer { busy = false }
    do {
      let actions = model.actions
      let cli = try actions.cli()
      if installHooks {
        for provider in providers { try actions.configureHooks(provider, install: true) }
      }
      _ = try actions.job("service", start: true)
      if protectCard { _ = try actions.job("sdejectguard", start: true) }
      if login { model.login = try actions.login(true) }
      if sleepHelper { _ = try await actions.helper("install", cli) }
      try Settings.update { $0["setup_screen_completed"] = true }
      model.needsSetup = false
      model.refresh()
    } catch { problem = error.localizedDescription }
  }
}

struct SetupView: View {
  @EnvironmentObject var model: Dashboard
  @StateObject var setup = Setup()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Welcome to SidePulse", systemImage: "waveform.path.ecg")
        .font(.title2.bold())
      Text(
        "Choose how SidePulse works on this Mac. You can change these options in Settings and Diagnostics."
      )
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle("Connect your coding agents", isOn: $setup.installHooks)
      Toggle("Prevent accidental SidePulse Pro ejection", isOn: $setup.protectCard)
      Toggle("Open at login", isOn: $setup.login)
      Toggle("Install the optional closed-lid sleep helper", isOn: $setup.sleepHelper)
      Text(
        "The sleep helper asks for administrator approval. Background monitoring keeps your lights up to date when the window is closed."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let problem = setup.problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if setup.busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("Not now", action: model.deferSetup)
        Button("Set up SidePulse") { Task { await setup.finish(using: model) } }
          .keyboardShortcut(.defaultAction)
      }.disabled(setup.busy)
    }.padding(24).frame(width: 430).interactiveDismissDisabled()
  }
}
