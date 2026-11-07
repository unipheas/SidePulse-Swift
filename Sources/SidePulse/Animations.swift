import AppKit
import PulseCore
import SwiftUI

struct Animations: View {
  @EnvironmentObject var model: Dashboard
  @State private var count = 8
  @State private var profileName = ""
  @State private var namingProfile = false
  private let states: [Mode] = [
    .working, .tool, .progress, .waiting, .blocked, .done, .idle, .unknown,
  ]
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Picker(
            "Profile",
            selection: Binding(
              get: { model.settings["swift_profile"] as? String ?? "current" },
              set: { model.setProfile($0) }
            )
          ) {
            Text("Current").tag("current")
            let saved = model.settings["agent_animation_profiles"] as? [String: JSONObject] ?? [:]
            ForEach(
              saved.keys.sorted().filter { !["cyan", "ember", "purple"].contains($0) }, id: \.self
            ) { key in
              Text(saved[key]?["name"] as? String ?? key).tag(key)
            }
            ForEach(["cyan", "ember", "purple"], id: \.self) { Text($0.capitalized).tag($0) }
          }.frame(maxWidth: 280)
          Spacer(minLength: 8)
          Picker("Preview device", selection: $count) {
            Text("Pro · 8").tag(8)
            Text("Dot · 2").tag(2)
          }.labelsHidden().pickerStyle(.segmented).frame(width: 145)
        }
        HStack(spacing: 10) {
          Text("All eight states").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Import…") { importProfile() }
          Button("Export…") { exportProfile() }
          Button("Save as…") { namingProfile = true }
            .popover(isPresented: $namingProfile) {
              VStack(alignment: .leading, spacing: 12) {
                Text("Save animation profile").font(.headline)
                TextField("New profile name", text: $profileName)
                  .textFieldStyle(.roundedBorder).accessibilityIdentifier("profile-name")
                HStack {
                  Spacer()
                  Button("Cancel") { namingProfile = false }
                  Button("Save profile") {
                    do {
                      try Profiles.save(name: profileName)
                      profileName = ""
                      namingProfile = false
                      model.refresh()
                    } catch { model.problem = error.localizedDescription }
                  }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
              }.padding(18).frame(width: 280)
            }
          Button {
            deleteProfile()
          } label: {
            Image(systemName: "trash")
          }
          .accessibilityLabel("Delete profile").help("Delete this saved profile")
          .disabled(!(model.settings["swift_profile"] as? String ?? "").hasPrefix("profile:"))
        }.controlSize(.small)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
          ForEach(states, id: \.self) { AnimationCard(mode: $0, count: count) }
        }
      }.padding(16).frame(maxWidth: 900, alignment: .leading).frame(
        maxWidth: .infinity, alignment: .topLeading)
    }
  }
  private func importProfile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try Profiles.load(from: url)
        model.refresh()
      } catch { model.problem = error.localizedDescription }
    }
  }
  private func exportProfile() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "SidePulse Profile.json"
    if panel.runModal() == .OK, let url = panel.url {
      do { try Profiles.export(to: url) } catch { model.problem = error.localizedDescription }
    }
  }
  private func deleteProfile() {
    do {
      try Profiles.delete(model.settings["swift_profile"] as? String ?? "")
      model.refresh()
    } catch { model.problem = error.localizedDescription }
  }
}

private struct AnimationCard: View {
  @EnvironmentObject var model: Dashboard
  let mode: Mode
  let count: Int
  @State private var editing = false
  @State private var draft = ""
  private var program: String {
    (try? Programs.program(mode, count: count, settings: model.settings)) ?? "off"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(mode.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 4)
        Button("Edit") {
          draft = program
          editing = true
        }
        .buttonStyle(.borderless).font(.caption)
        .accessibilityIdentifier("edit-" + mode.rawValue)
        .popover(isPresented: $editing, arrowEdge: .trailing) {
          VStack(alignment: .leading, spacing: 14) {
            Text(mode.label + " animation").font(.headline)
            ProgramEditor(source: $draft, count: count)
            HStack {
              Menu("Load preset") {
                ForEach(Programs.animationNames, id: \.self) { name in
                  Button(name) { draft = (try? Programs.preset(name, count: count)) ?? draft }
                }
              }
              DevicePreviewMenu(source: draft)
              Spacer()
              Button("Cancel") { editing = false }
              Button("Save animation") {
                do {
                  try Settings.setAnimation(mode, program: draft, count: count)
                  model.refresh()
                  editing = false
                } catch { model.problem = error.localizedDescription }
              }.keyboardShortcut(.defaultAction)
            }.controlSize(.small)
          }.padding(18).frame(width: 470)
        }
      }
      LightBar(source: editing ? draft : program, count: count, compact: true)
        .accessibilityIdentifier("preview-" + mode.rawValue)
    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.07)))
  }
}

struct ProgramEditor: View {
  @Binding var source: String
  let count: Int
  var initialProgram: String? = nil
  @State private var replay = UUID()
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        LightBar(source: source, count: count, compact: true, initialProgram: initialProgram).id(
          replay)
        Spacer()
        Button {
          replay = UUID()
        } label: {
          Label("Replay", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless).font(.caption)
      }
      TextEditor(text: $source).font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden).padding(6).frame(height: 120)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
        .accessibilityIdentifier("animation-program")
      Text("\(source.utf8.count) / 512 bytes").font(.caption2).monospacedDigit()
        .foregroundStyle(source.utf8.count > 512 ? .red : .secondary)
    }
  }
}

private struct DevicePreviewMenu: View {
  @EnvironmentObject var model: Dashboard
  let source: String
  var body: some View {
    Menu("Show on device") {
      ForEach(model.devices) { device in
        Button(device.name) {
          do {
            _ = try LEDPreview(program: source, count: device.count)
            model.change { settings in
              var rows = settings["devices"] as? [JSONObject] ?? []
              var row = rows.first { $0["id"] as? String == device.id } ?? ["id": device.id]
              row["led_display"] = "custom"
              row["manual_program"] = source
              rows.removeAll { $0["id"] as? String == device.id }
              rows.append(row)
              settings["devices"] = rows
            }
            try device.write(source)
          } catch { model.problem = error.localizedDescription }
        }
      }
    }.disabled(model.devices.isEmpty || (model.legacy && !Jobs.running(Jobs.prefix + "service")))
  }
}
