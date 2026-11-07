import PulseCore
import SwiftUI

struct LidAnimationEditor: View {
  @EnvironmentObject var model: Dashboard
  let state: String
  @State private var source = ""
  @State private var duration = 1.3
  var body: some View {
    DisclosureGroup(state == "lid_open" ? "Lid opened" : "Lid closed") {
      TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(height: 90)
      TextField("Duration in seconds", value: $duration, format: .number)
      Button("Save lid animation") {
        do {
          try Settings.setLidAnimation(state, program: source, duration: duration)
          model.refresh()
        } catch { model.problem = error.localizedDescription }
      }
    }.onAppear {
      let animation = model.settings[state + "_animation"] as? JSONObject ?? [:]
      source =
        animation["program"] as? String
        ?? (try? Programs.preset(state.replacingOccurrences(of: "_", with: "-"), count: 8)) ?? "off"
      duration = animation["duration_seconds"] as? Double ?? 1.3
    }
  }
}
