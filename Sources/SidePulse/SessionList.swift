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
          SessionOpenMenu(session: item) { Image(systemName: "arrow.up.forward.app") }
            .accessibilityLabel("Open " + item.name).fixedSize()
        }.padding(.vertical, 4)
      }
    }
  }
}

struct SessionOpenMenu<Label: View>: View {
  @EnvironmentObject var model: Dashboard
  let session: Session
  @ViewBuilder var label: () -> Label
  var body: some View {
    let actions = session.actions(
      preferences: model.settings["session_open_preferences"] as? [String: String] ?? [:])
    if let first = actions.first {
      Menu {
        ForEach(actions, id: \.self) { action in
          Button(action.label) { open(action) }
        }
      } label: {
        label()
      } primaryAction: {
        open(first)
      }
    } else {
      label()
    }
  }
  private func open(_ action: SessionAction) {
    do {
      try model.actions.openSession(session.target(for: action), session, model.settings)
    } catch { model.problem = error.localizedDescription }
  }
}

@MainActor enum SessionOpening {
  static func open(
    _ target: SessionTarget?, session: Session, settings: JSONObject,
    link: (URL) -> Bool = { NSWorkspace.shared.open($0) },
    terminal: (String, JSONObject, Session) throws -> Void = {
      try Terminal.open($0, settings: $1, session: $2)
    }
  ) throws {
    switch target {
    case .link(let url):
      guard link(url) else { throw PulseError("Install the application that opens this session.") }
    case .terminal(let command): try terminal(command, settings, session)
    case nil: break
    }
  }
}
