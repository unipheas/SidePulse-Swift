import AppKit
import PulseCore
import SwiftUI

struct SessionList: View {
  @EnvironmentObject var model: Dashboard
  var body: some View {
    if model.sessions.isEmpty {
      ContentUnavailableView(
        "Waiting for agent activity", systemImage: "terminal",
        description: Text("Configure agent hooks in Settings or use your existing SidePulse hooks.")
      )
    } else {
      List(model.sessions.prefix(100)) { item in
        HStack {
          VStack(alignment: .leading) {
            Text(item.name).font(.headline)
            Text(item.provider.capitalized + " · " + item.event).font(.caption).foregroundStyle(
              .secondary)
          }
          Spacer()
          VStack(alignment: .trailing) {
            Text(item.mode.label)
            Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
          }
          let actions = item.actions(
            preferences: model.settings["session_open_preferences"] as? [String: String] ?? [:])
          if let first = actions.first {
            Menu {
              ForEach(actions, id: \.self) { action in
                Button(action.label) { open(item.target(for: action), session: item) }
              }
            } label: {
              Image(systemName: "arrow.up.forward.app")
            } primaryAction: {
              open(item.target(for: first), session: item)
            }
            .accessibilityLabel("Open " + item.name).fixedSize()
          }
        }.padding(.vertical, 4)
      }
    }
  }
  private func open(_ target: SessionTarget?, session: Session) {
    switch target {
    case .link(let url):
      if !NSWorkspace.shared.open(url) {
        model.problem = "Install the application that opens this session."
      }
    case .terminal(let command):
      do {
        try Terminal.open(command, settings: model.settings, session: session)
      } catch { model.problem = error.localizedDescription }
    case nil: break
    }
  }

}
