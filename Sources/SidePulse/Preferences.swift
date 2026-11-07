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
          }.accessibilityIdentifier("save-done-duration")
        }
        if model.legacy && !Jobs.running(Jobs.prefix + "service") {
          Button("Use this installation for device output", action: model.takeControl)
        }
        if let paused = model.settings["swift_paused_jobs"] as? [String], !paused.isEmpty {
          Button("Restore previous installation", action: model.restorePrevious)
        }
        Toggle(
          "Mirror status on connected devices",
          isOn: Binding(
            get: { model.mirror }, set: { value in model.change { $0["swift_mirror"] = value } }))
        ForEach(model.devices) { device in
          DeviceDisplayPreference(id: device.id, title: device.name)
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
        .accessibilityIdentifier("session-terminal")
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
              })
          ).accessibilityIdentifier("custom-terminal-path")
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
          }.accessibilityIdentifier("open-session-" + provider)
        }
      }
      Section("Session timing") {
        ForEach(
          [
            ("idle_timeout_seconds", "Mark activity stale after"),
            ("recent_session_retention_seconds", "Keep recent sessions for"),
          ], id: \.0
        ) { key, label in
          SessionTimingPreference(key: key, label: label)

        }
      }
      Section("Lid animations") {
        ForEach(["lid_open", "lid_closed"], id: \.self) { state in
          LidAnimationEditor(state: state)
        }
      }
      Section("Mac") {
        Toggle(
          "Show lights beneath the notch",
          isOn: Binding(
            get: { model.settings["virtual_status_device_enabled"] as? Bool ?? false },
            set: { value in model.change { $0["virtual_status_device_enabled"] = value } }
          )
        ).accessibilityIdentifier("notch-enabled")
        if model.settings["virtual_status_device_enabled"] as? Bool == true {
          let config = Settings.device(NotchDisplay.deviceID, in: model.settings)
          Picker(
            "Notch display",
            selection: Binding(
              get: { config["led_display"] as? String ?? "agent" },
              set: { value in
                model.change {
                  Settings.editDevice(
                    NotchDisplay.deviceID, in: &$0, values: ["led_display": value])
                }
              }
            )
          ) {
            Text("Agent status").tag("agent")
            Text("Battery").tag("battery")
            Text("Hidden").tag("custom")
          }.accessibilityIdentifier("notch-display")
          Slider(
            value: Binding(
              get: { Double(config["brightness"] as? Int ?? 255) },
              set: { value in
                model.change {
                  Settings.editDevice(
                    NotchDisplay.deviceID, in: &$0, values: ["brightness": Int(value)])
                }
              }
            ), in: 0...255, step: 1
          ) { Text("Notch brightness") }.accessibilityIdentifier("notch-brightness")
        }
        Toggle(
          "Show menu bar icon",
          isOn: Binding(
            get: { model.settings["show_menu_bar_icon"] as? Bool ?? true },
            set: { value in model.change { $0["show_menu_bar_icon"] = value } }))
        Toggle(
          "Open at login",
          isOn: Binding(
            get: { model.login },
            set: model.setLogin))
      }
      PowerPreferences()
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
              })
          ).accessibilityIdentifier("transcript-" + provider)
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
  func configure(_ install: Bool) { model.configureHooks(provider, install: install) }
}

struct SessionTimingPreference: View {
  @EnvironmentObject var model: Dashboard
  let key: String
  let label: String
  @State private var draft = ""
  var body: some View {
    HStack {
      Text(label)
      Spacer()
      SettingField(label: label, text: $draft, identifier: key)
      Button("Apply") {
        guard let value = Double(draft), value.isFinite, value >= 0 else {
          model.problem = "Enter a finite number of seconds, zero or more."
          return
        }
        model.change {
          var timing = $0["agent_list"] as? JSONObject ?? [:]
          timing[key] = value
          $0["agent_list"] = timing
        }
      }.accessibilityIdentifier(key + "-apply")
    }.onAppear {
      draft = String(
        format: "%g",
        Settings.seconds(
          model.settings, key,
          default: key == "idle_timeout_seconds" ? 3600 : 172800))
    }
  }
}
