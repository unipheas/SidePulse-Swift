import AppKit
import PulseCore
import SwiftUI

@main struct SidePulseApp: App {
  @StateObject private var model = Dashboard()
  var body: some Scene {
    Window("SidePulse", id: "main") {
      DashboardView().environmentObject(model)
        .task { model.prepareInstallation() }
        .onOpenURL { url in
          if url.host == "updates" { AppUpdates.shared.check() }
        }
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
      .commands {
        CommandGroup(after: .appInfo) { CheckUpdatesButton() }
      }
    Window("Virtual SidePulse", id: "leds") {
      LightBar(
        source: Programs.preview {
          try Programs.program(model.mode, count: 8, settings: model.settings)
        },
        count: 8
      )
      .frame(minWidth: 280, minHeight: 80).padding(8)
    }.defaultSize(width: 420, height: 100).windowResizability(.contentSize)
    MenuBarExtra(
      "SidePulse · \(model.mode.label)",
      systemImage: model.mode == .idle ? "waveform" : "waveform.circle.fill",
      isInserted: model.menuBarInsertion
    ) {
      MenuPanel().environmentObject(model)
    }
  }
}
