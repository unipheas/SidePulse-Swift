import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case auto, light, dark
  var id: Self { self }
  var label: String { rawValue.capitalized }
  var symbol: String {
    switch self {
    case .auto: return "circle.lefthalf.filled"
    case .light: return "sun.max"
    case .dark: return "moon"
    }
  }
  var native: NSAppearance? {
    switch self {
    case .auto: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

struct AppearanceMenu: View {
  @EnvironmentObject var model: Dashboard
  var body: some View {
    Menu {
      Picker(
        "Appearance",
        selection: Binding(
          get: { model.appearance },
          set: { choice in model.change { $0["appearance"] = choice.rawValue } }
        )
      ) {
        ForEach(AppAppearance.allCases) { choice in
          Label(choice.label, systemImage: choice.symbol).tag(choice)
        }
      }.pickerStyle(.inline)
    } label: {
      Label("Appearance", systemImage: model.appearance.symbol)
    }
    .labelStyle(.iconOnly)
    .help("Appearance: " + model.appearance.label)
    .accessibilityLabel("Appearance")
    .accessibilityIdentifier("appearance-menu")
  }
}
