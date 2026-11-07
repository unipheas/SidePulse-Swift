import PulseCore
import SwiftUI

@MainActor final class SleepHelper: ObservableObject {
  @Published private(set) var busy = false
  @Published private(set) var status = ""
  func refresh(using actions: MacActions) {
    status = actions.helperInstalled() ? "Helper installed" : "Helper not installed"
  }
  func perform(_ action: String, using model: Dashboard) async {
    guard !busy else { return }
    busy = true
    defer {
      busy = false
      refresh(using: model.actions)
    }
    do { _ = try await model.actions.helper(action, model.actions.cli()) } catch {
      model.problem = error.localizedDescription
    }
  }
}
