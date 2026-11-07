import AppKit
import Charts
import PulseCore
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject var model: Dashboard
  @State private var hours = 24
  @State private var metric = "Agent state"
  var body: some View {
    let changes = History.recent().filter {
      hours == 0 || Date().timeIntervalSince($0.date) <= Double(hours) * 3600
    }
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Picker("Show", selection: $hours) {
          Text("Last hour").tag(1)
          Text("Last 24 hours").tag(24)
          Text("Last week").tag(168)
          Text("All recorded history").tag(0)
        }.frame(width: 240)
        Picker("Metric", selection: $metric) {
          ForEach(
            ["Agent state", "Battery", "Charger and battery power", "Sleep and lid"], id: \.self
          ) { Text($0).tag($0) }
        }.labelsHidden().accessibilityIdentifier("history-metric").frame(width: 170)
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
          switch metric {
          case "Battery":
            if let percent = change.battery {
              LineMark(x: .value("Time", change.date), y: .value("Charge (%)", percent))
                .interpolationMethod(.stepEnd).foregroundStyle(.green)
            }
          case "Charger and battery power":
            if let watts = change.chargerWatts {
              LineMark(x: .value("Time", change.date), y: .value("Watts", watts))
                .foregroundStyle(by: .value("Source", "Charger")).interpolationMethod(.stepEnd)
            }
            if let watts = change.batteryWatts {
              LineMark(x: .value("Time", change.date), y: .value("Watts", watts))
                .foregroundStyle(by: .value("Source", "Battery")).interpolationMethod(.stepEnd)
            }
          case "Sleep and lid":
            if let closed = change.power?.lidClosed {
              PointMark(
                x: .value("Time", change.date),
                y: .value("State", closed ? "Lid closed" : "Lid open")
              )
              .foregroundStyle(by: .value("Source", "Lid"))
            }
            if let awake = change.keepingAwake {
              PointMark(
                x: .value("Time", change.date),
                y: .value("State", awake ? "Keeping awake" : "Awake hold off")
              )
              .foregroundStyle(by: .value("Source", "SidePulse"))
            }
            if let disabled = change.power?.sleepDisabled {
              PointMark(
                x: .value("Time", change.date),
                y: .value("State", disabled ? "Sleep disabled" : "Sleep enabled")
              )
              .foregroundStyle(by: .value("Source", "macOS"))
            }
          default:
            PointMark(x: .value("Time", change.date), y: .value("State", change.mode.label))
              .foregroundStyle(by: .value("State", change.mode.label))
          }
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
      Section("Battery and charger") {
        if let diagnostic = BatteryDiagnostics.read() {
          let values = diagnostic.values
          ForEach(
            [
              ("Health", "health_percent", "%"), ("Cycle count", "cycle_count", ""),
              ("Temperature", "temperature_c", " °C"), ("Charger power", "adapter_power", " W"),
              ("Charge baseline", "full_charge_watts", " W"), ("Condition", "condition", ""),
              ("Adapter", "adapter_name", ""), ("Connection", "adapter_family", ""),
            ], id: \.0
          ) { label, key, unit in
            LabeledContent(
              label, value: values[key].map { String(describing: $0) + unit } ?? "Unavailable")
          }
        } else {
          Text("No internal battery found.")
        }
      }
      Section("Event debug log") {
        HStack {
          Button("Export event CSV…") { exportAudit("csv") }
          Button("Export event HTML…") { exportAudit("html") }
        }
        Text(
          "Includes hook payload previews and session details. Review the file before sharing it."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Recent hook events") {
        ForEach(model.sessions.prefix(20)) { session in
          LabeledContent(session.name, value: session.event + " · " + session.mode.label)
        }
      }
    }.formStyle(.grouped)
  }
  private func exportAudit(_ format: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "SidePulse Events." + format
    if panel.runModal() == .OK, let url = panel.url {
      do { try Audit.export(to: url) } catch { model.problem = error.localizedDescription }
    }
  }
}
