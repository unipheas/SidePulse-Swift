import AppKit
import Charts
import PulseCore
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject var model: Dashboard
  @State private var hours = 24
  var body: some View {
    let changes = History.recent().filter {
      Date().timeIntervalSince($0.date) <= Double(hours) * 3600
    }
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Picker("Show", selection: $hours) {
          Text("Last hour").tag(1)
          Text("Last 24 hours").tag(24)
          Text("Last week").tag(168)
        }.frame(width: 240)
        Spacer()
        Menu("Export…") {
          Button("CSV") { export("csv") }
          Button("HTML") { export("html") }
        }
      }
      if changes.isEmpty {
        ContentUnavailableView(
          "No recorded activity", systemImage: "clock",
          description: Text("Agent status changes appear here as you work."))
      } else {
        Chart(changes) { change in
          PointMark(x: .value("Time", change.date), y: .value("State", change.mode.label))
            .foregroundStyle(by: .value("State", change.mode.label))
        }.frame(height: 180).chartLegend(.hidden)
        List(changes.reversed()) { change in
          HStack {
            Text(change.mode.label)
            Spacer()
            if let percent = change.battery { Text("\(percent)%").foregroundStyle(.secondary) }
            Text(change.date, style: .time).monospacedDigit()
          }
        }
      }
    }.padding(20)
  }
  private func export(_ format: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "SidePulse History." + format
    if panel.runModal() == .OK, let url = panel.url {
      do { try History.export(to: url) } catch { model.problem = error.localizedDescription }
    }
  }
}
struct DiagnosticsView: View {
  @EnvironmentObject var model: Dashboard
  var body: some View {
    Form {
      Section("Agent hooks") {
        ForEach(Hooks.diagnostics(), id: \.self) { report in
          VStack(alignment: .leading) {
            LabeledContent(report["provider"]?.capitalized ?? "", value: report["status"] ?? "")
            Text(report["path"] ?? "").font(.caption).textSelection(.enabled).foregroundStyle(
              .secondary)
          }
        }
      }
      Section("Background services") {
        LabeledContent(
          "Native service", value: Jobs.running(Jobs.prefix + "service") ? "Running" : "Stopped")
        LabeledContent(
          "Eject protection",
          value: Jobs.running(Jobs.prefix + "sdejectguard") ? "Running" : "Stopped")
        Text(Settings.url.path).font(.caption).textSelection(.enabled)
        Button("Show settings folder") { NSWorkspace.shared.open(Paths.support) }
      }
      Section("Recent hook events") {
        ForEach(model.sessions.prefix(20)) { session in
          LabeledContent(session.name, value: session.event + " · " + session.mode.label)
        }
      }
    }.formStyle(.grouped)
  }
}
