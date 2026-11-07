import AppKit
import PulseCore
import SwiftUI

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
