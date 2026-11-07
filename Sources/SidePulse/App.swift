import AppKit
import PulseCore
import ServiceManagement
import SwiftUI

@main struct SidePulseApp: App {
  @StateObject private var model = Dashboard()
  var body: some Scene {
    Window("SidePulse", id: "main") {
      DashboardView().environmentObject(model)
        .alert(
          "SidePulse",
          isPresented: Binding(
            get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
          Button("OK") { model.problem = nil }
        } message: {
          Text(model.problem ?? "")
        }
    }.defaultSize(width: 800, height: 535)
    Window("Virtual SidePulse", id: "leds") {
      LightBar(
        source: (try? Programs.program(model.mode, count: 8, settings: model.settings)) ?? "off",
        count: 8
      )
      .frame(minWidth: 280, minHeight: 80).padding(8)
    }.defaultSize(width: 420, height: 100).windowResizability(.contentSize)
    MenuBarExtra(
      "SidePulse · \(model.mode.label)",
      systemImage: model.mode == .idle ? "waveform" : "waveform.circle.fill"
    ) {
      MenuPanel().environmentObject(model)
    }
  }
}
