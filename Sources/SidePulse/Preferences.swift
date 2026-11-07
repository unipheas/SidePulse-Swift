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
          SettingField(label: "Done duration", text: $seconds, identifier: "done-seconds")
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
          Button("Use this installation for device output") {
            do {
              try Jobs.takeControl()
              model.legacy = false
              model.refresh()
            } catch { model.problem = error.localizedDescription }
          }
        }
        if let paused = model.settings["swift_paused_jobs"] as? [String], !paused.isEmpty {
          Button("Restore previous installation") {
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
      BatteryPreferences()
      Section("Linked phones") {
        Toggle(
          "Mirror LED states to paired phones",
          isOn: Binding(
            get: { model.settings["swift_phone_mirror"] as? Bool ?? false },
            set: { value in model.change { $0["swift_phone_mirror"] = value } }))
      }
      Section("Opening sessions") {
        Picker(
          "Terminal",
          selection: Binding(
            get: {
              (model.settings["session_terminal"] as? JSONObject)?["app"] as? String ?? "terminal"
            },
            set: { value in
              model.change {
                var terminal = $0["session_terminal"] as? JSONObject ?? [:]
                terminal["app"] = value
                $0["session_terminal"] = terminal
              }
            }
          )
        ) { ForEach(Terminal.choices, id: \.self) { Text($0.capitalized).tag($0) } }
        if (model.settings["session_terminal"] as? JSONObject)?["app"] as? String == "custom" {
          TextField(
            "Application path",
            text: Binding(
              get: {
                (model.settings["session_terminal"] as? JSONObject)?["custom_path"] as? String ?? ""
              },
              set: { value in
                model.change {
                  var terminal = $0["session_terminal"] as? JSONObject ?? [:]
                  terminal["custom_path"] = value
                  $0["session_terminal"] = terminal
                }
              }))
        }
        ForEach(["codex", "claude", "grok", "junie"], id: \.self) { provider in
          Picker(
            provider.capitalized,
            selection: Binding(
              get: {
                (model.settings["session_open_preferences"] as? [String: String])?[provider]
                  ?? "automatic"
              },
              set: { value in
                model.change {
                  var preferences = $0["session_open_preferences"] as? [String: String] ?? [:]
                  preferences[provider] = value == "automatic" ? nil : value
                  $0["session_open_preferences"] = preferences
                }
              }
            )
          ) {
            Text("Automatic").tag("automatic")
            Text("Terminal").tag("terminal")
            if ["codex", "claude"].contains(provider) { Text("App").tag("app") }
            if provider == "claude" { Text("VS Code").tag("vscode") }
          }
        }
      }
      Section("Session timing") {
        ForEach(
          [
            ("idle_timeout_seconds", "Mark activity stale after"),
            ("recent_session_retention_seconds", "Keep recent sessions for"),
          ], id: \.0
        ) { key, label in
          HStack {
            Text(label)
            TextField(
              "Seconds",
              value: Binding(
                get: {
                  Settings.seconds(
                    model.settings, key, default: key == "idle_timeout_seconds" ? 3600 : 172800)
                },
                set: { value in
                  guard value.isFinite && value >= 0 else { return }
                  model.change {
                    var timing = $0["agent_list"] as? JSONObject ?? [:]
                    timing[key] = value
                    $0["agent_list"] = timing
                  }
                }), format: .number
            ).labelsHidden().textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 82)
              .accessibilityLabel(label)
            Text("seconds").foregroundStyle(.secondary).fixedSize()
          }
        }
      }
      Section("Lid animations") {
        ForEach(["lid_open", "lid_closed"], id: \.self) { state in
          LidAnimationEditor(state: state)
        }
      }
      Section("Mac") {
        Toggle(
          "Show menu bar icon",
          isOn: Binding(
            get: { model.settings["show_menu_bar_icon"] as? Bool ?? true },
            set: { value in model.change { $0["show_menu_bar_icon"] = value } }))
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
            get: {
              model.settings["swift_keep_awake"] as? Bool
                ?? ((model.settings["sleep_prevention_policy"] as? String ?? "agents") != "never")
            },
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
          Button("Remove hooks") { configure(false) }
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
