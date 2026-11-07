import AppKit
import PulseCore
import ServiceManagement
import SwiftUI

enum SectionName: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case sessions = "Sessions"
  case animations = "Animations"
  case history = "History"
  case diagnostics = "Diagnostics"
  case devices = "Devices"
  case settings = "Settings"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: return "dot.radiowaves.left.and.right"
    case .sessions: return "clock.arrow.circlepath"
    case .animations: return "light.beacon.max"
    case .history: return "chart.bar.xaxis"
    case .diagnostics: return "stethoscope"
    case .devices: return "externaldrive"
    case .settings: return "slider.horizontal.3"
    }
  }
}
struct DashboardView: View {
  @EnvironmentObject var model: Dashboard
  @State private var selection: SectionName? = .overview
  var body: some View {
    NavigationSplitView {
      List(SectionName.allCases, selection: $selection) { item in
        Label(item.rawValue, systemImage: item.symbol).tag(item)
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 205)
    } detail: {
      Group {
        switch selection ?? .overview {
        case .overview: Overview()
        case .sessions: SessionList()
        case .animations: Animations()
        case .history: HistoryView()
        case .diagnostics: DiagnosticsView()
        case .devices: DeviceManagement()
        case .settings: Preferences()
        }
      }.navigationTitle((selection ?? .overview).rawValue)
    }.frame(minWidth: 675, minHeight: 460)
  }
}
