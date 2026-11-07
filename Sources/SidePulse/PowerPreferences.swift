import PulseCore
import SwiftUI

struct PowerPreferences: View {
  @EnvironmentObject var model: Dashboard
  @State private var minimum = "20"
  @StateObject var helper = SleepHelper()
  var body: some View {
    Section("Sleep prevention") {
      Picker(
        "Keep Mac awake",
        selection: Binding(
          get: {
            model.settings["swift_keep_awake"] as? Bool == false
              ? "never" : SleepSettings.policy(model.settings)
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
      .accessibilityIdentifier("awake-policy")
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
          get: { SleepSettings.closedLid(model.settings) },
          set: model.setClosedLid
        )
      ) {
        Text("Never").tag("never")
        Text("While agents work").tag("agents")
        Text("Always").tag("always")
      }
      .accessibilityIdentifier("closed-lid-policy")
      HStack {
        Text(helper.status).foregroundStyle(.secondary)
        Spacer()
        Button("Install sleep helper…") { Task { await helper.perform("install", using: model) } }
          .disabled(helper.busy)
        Button("Remove sleep helper…") { Task { await helper.perform("uninstall", using: model) } }
          .disabled(helper.busy)
      }
      Text(
        "The optional helper lets SidePulse manage closed-lid sleep. Installation requires administrator approval."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.onAppear {
      let value =
        SleepSettings.minimum(model.settings)
      minimum = String(format: "%g", value)
      helper.refresh(using: model.actions)
    }
  }
}
