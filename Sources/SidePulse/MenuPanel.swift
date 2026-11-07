import AppKit
import PulseCore
import SwiftUI

struct MenuPanel: View {
  @EnvironmentObject var model: Dashboard
  @Environment(\.openWindow) var openWindow
  var body: some View {
    Text(model.mode.label)
    ForEach(model.sessions.prefix(5)) { item in
      SessionOpenMenu(session: item) { Text("\(item.name) · \(item.mode.label)") }
    }
    Divider()
    Button("Open SidePulse") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }
    Button("Open virtual LEDs") { openWindow(id: "leds") }
    Toggle(
      "Show notch lights",
      isOn: Binding(
        get: { model.settings["virtual_status_device_enabled"] as? Bool ?? false },
        set: { enabled in model.change { $0["virtual_status_device_enabled"] = enabled } }
      ))
    CheckUpdatesButton()
    Button("Quit SidePulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}
