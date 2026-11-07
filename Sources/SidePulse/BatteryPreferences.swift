import PulseCore
import SwiftUI

struct BatteryPreferences: View {
  @EnvironmentObject var model: Dashboard
  @State private var watts = "auto"
  @State private var seconds = "7"
  var body: some View {
    Section("Battery display") {
      Picker(
        "Default display",
        selection: Binding(
          get: { model.settings["led_display"] as? String ?? "agent" },
          set: { value in save(display: value) }
        )
      ) {
        Text("Agent status").tag("agent")
        Text("Battery").tag("battery")
        Text("Manual").tag("custom")
      }
      Toggle(
        "Preview battery when power changes",
        isOn: Binding(
          get: {
            (model.settings["battery_monitoring"] as? JSONObject)?["show_on_power_change"] as? Bool
              ?? true
          },
          set: { value in save(show: value) }
        ))
      HStack {
        Text("Power change preview")
        Spacer()
        SettingField(
          label: "Power change duration", text: $seconds, identifier: "power-preview-seconds")
      }
      HStack {
        Text("Full-speed charger")
        Spacer()
        SettingField(
          label: "Full-speed charger watts or auto", text: $watts, unit: "watts",
          identifier: "charger-watts")
      }
      Text("Auto uses the Mac's charging baseline: \(Int(PowerRegistry.fullChargeWatts)) W.")
        .font(.caption).foregroundStyle(.secondary)
      Button("Save battery settings") { save(full: watts, preview: seconds) }
    }.onAppear {
      let battery = model.settings["battery_monitoring"] as? JSONObject ?? [:]
      watts = (battery["full_charge_watts"] as? NSNumber).map { $0.stringValue } ?? "auto"
      seconds = (battery["power_change_preview_seconds"] as? NSNumber)?.stringValue ?? "7"
    }
  }
  private func save(
    display: String? = nil, full: String? = nil, show: Bool? = nil, preview: String? = nil
  ) {
    do {
      try Settings.configureBattery(
        display: display, fullWatts: full, showOnPowerChange: show, previewSeconds: preview)
      model.refresh()
    } catch { model.problem = error.localizedDescription }
  }
}
