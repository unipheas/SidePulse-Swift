import PulseCore
import SwiftUI

struct PowerPreferences: View {
  @EnvironmentObject var model: Dashboard
  @State private var minimum = "20"
  @State private var helperStatus = ""
  @State private var busy = false
  var body: some View {
    Section("Sleep prevention") {
      Picker(
        "Keep Mac awake",
        selection: Binding(
          get: {
            model.settings["swift_keep_awake"] as? Bool == false
              ? "never" : model.settings["sleep_prevention_policy"] as? String ?? "agents"
          },
          set: { value in
            model.change {
              $0["sleep_prevention_policy"] = value
              $0["swift_keep_awake"] = value != "never"
            }
          }
        )
      ) {
        Text("Never").tag("never")
        Text("While agents work").tag("agents")
        Text("Always").tag("always")
      }
      HStack {
        Text("Allow sleep on battery below")
        Spacer()
        SettingField(
          label: "Minimum battery percent", text: $minimum, unit: "%", identifier: "sleep-minimum")
        Button("Apply") {
          do {
            try Settings.setSleepMinimum(minimum)
            model.refresh()
          } catch { model.problem = error.localizedDescription }
        }.accessibilityIdentifier("save-sleep-minimum")
      }
      Picker(
        "Keep awake with lid closed",
        selection: Binding(
          get: { model.settings["swift_closed_lid"] as? String ?? "never" },
          set: { value in
            guard
              value == "never"
                || FileManager.default.fileExists(
                  atPath: "/etc/sudoers.d/sidepulse-swift-disablesleep")
            else {
              model.problem = "Install the sleep helper below before enabling closed-lid operation."
              return
            }
            model.change { $0["swift_closed_lid"] = value }
          }
        )
      ) {
        Text("Never").tag("never")
        Text("While agents work").tag("agents")
        Text("Always").tag("always")
      }
      HStack {
        Text(helperStatus).foregroundStyle(.secondary)
        Spacer()
        Button("Install sleep helper…") { helper("install") }.disabled(busy)
        Button("Remove sleep helper…") { helper("uninstall") }.disabled(busy)
      }
      Text(
        "The optional helper lets SidePulse manage closed-lid sleep. Installation requires administrator approval."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.onAppear {
      let value =
        (model.settings["sleep_prevention"] as? JSONObject)?["min_battery_percent"] as? Double ?? 20
      minimum = String(format: "%g", value)
      refreshStatus()
    }
  }
  private func refreshStatus() {
    helperStatus =
      FileManager.default.fileExists(atPath: "/etc/sudoers.d/sidepulse-swift-disablesleep")
      ? "Helper installed" : "Helper not installed"
  }
  private func helper(_ action: String) {
    guard let executable = Bundle.main.executableURL else { return }
    busy = true
    Task {
      defer {
        busy = false
        refreshStatus()
      }
      do {
        _ = try await Task.detached {
          try AppInstallation.sleepHelper(
            action: action, executable: executable, dryRun: false, administratorPrompt: true)
        }.value
      } catch { model.problem = error.localizedDescription }
    }
  }
}
