import AppKit
import PulseCore
import ServiceManagement
import SwiftUI

struct Animations: View {
  @EnvironmentObject var model: Dashboard
  @State var selected = Mode.working
  @State var source = ""
  @State var count = 8
  @State private var profileName = ""
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
        ForEach(
          saved.keys.sorted().filter { !["cyan", "ember", "purple"].contains($0) }, id: \.self
        ) { key in
          Text(saved[key]?["name"] as? String ?? key).tag(key)
        }
        ForEach(["cyan", "ember", "purple"], id: \.self) { Text($0.capitalized).tag($0) }
      }
      HStack {
        TextField("New profile name", text: $profileName)
        Button("Save profile") {
          do {
            try Profiles.save(name: profileName)
            profileName = ""
            model.refresh()
          } catch { model.problem = error.localizedDescription }
        }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Delete profile") {
          do {
            try Profiles.delete(model.settings["swift_profile"] as? String ?? "")
            model.refresh()
          } catch { model.problem = error.localizedDescription }
        }.disabled(!(model.settings["swift_profile"] as? String ?? "").hasPrefix("profile:"))
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
        Menu("Show on device") {
          ForEach(model.devices) { device in
            Button(device.name) {
              do {
                _ = try LEDPreview(program: source, count: device.count)
                model.change { settings in
                  var rows = settings["devices"] as? [JSONObject] ?? []
                  var row = rows.first { $0["id"] as? String == device.id } ?? ["id": device.id]
                  row["led_display"] = "custom"
                  rows.removeAll { $0["id"] as? String == device.id }
                  rows.append(row)
                  settings["devices"] = rows
                }
                try device.write(source)
              } catch { model.problem = error.localizedDescription }
            }
          }
        }.disabled(model.devices.isEmpty || model.legacy)
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
