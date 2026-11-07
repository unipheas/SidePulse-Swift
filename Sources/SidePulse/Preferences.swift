import AppKit
import PulseCore
import ServiceManagement
import SwiftUI

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
      Section("Linked phones") {
        Toggle(
          "Mirror LED states to paired phones",
          isOn: Binding(
            get: { model.settings["swift_phone_mirror"] as? Bool ?? false },
            set: { value in model.change { $0["swift_phone_mirror"] = value } }))
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
      Section("Closed-lid operation") {
        Picker(
          "Keep awake with lid closed",
          selection: Binding(
            get: { model.settings["swift_closed_lid"] as? String ?? "never" },
            set: { value in
              if value != "never"
                && !FileManager.default.fileExists(
                  atPath: "/etc/sudoers.d/sidepulse-swift-disablesleep")
              {
                model.problem =
                  "Install the optional sleep helper from the project before enabling this setting."
                return
              }
              model.change { $0["swift_closed_lid"] = value }
            })
        ) {
          Text("Never").tag("never")
          Text("While agents work").tag("agents")
          Text("Always").tag("always")
        }
      }
      Section("Transcript recovery") {
        ForEach(["codex", "claude"], id: \.self) { provider in
          Toggle(
            provider.capitalized,
            isOn: Binding(
              get: {
                (model.settings["transcript_monitoring"] as? [String: Bool])?[provider] ?? false
              },
              set: { value in
                model.change { config in
                  var enabled = config["transcript_monitoring"] as? [String: Bool] ?? [:]
                  enabled[provider] = value
                  config["transcript_monitoring"] = enabled
                }
              }))
        }
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
        "sidepulsectl"), FileManager.default.isExecutableFile(atPath: cli.path)
    else {
      model.problem = "Build and launch the packaged app to configure hooks."
      return
    }
    do { try Hooks.configure(provider, executable: cli, install: install) } catch {
      model.problem = error.localizedDescription
    }
  }
}
