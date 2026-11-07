import AppKit
import PulseCore
import SwiftUI

struct MenuPanel: View {
  @EnvironmentObject var model: Dashboard
  @Environment(\.openWindow) var openWindow
  var body: some View {
    Text(model.mode.label)
    ForEach(model.sessions.prefix(5)) { item in Text("\(item.name) · \(item.mode.label)") }
    Divider()
    Button("Open SidePulse") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }
    Button("Open virtual LEDs") { openWindow(id: "leds") }
    Link(
      "Check for updates…",
      destination: URL(string: "https://github.com/unipheas/SidePulse-Swift/releases")!)
    Button("Quit SidePulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}
