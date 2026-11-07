import Combine
import Foundation
import Sparkle
import SwiftUI

/// Sparkle owns download verification, installation, rollback, and relaunch.
@MainActor final class AppUpdates: ObservableObject {
  static let shared = AppUpdates()
  @Published private(set) var canCheck = false
  private let controller: SPUStandardUpdaterController
  init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
      controller.startUpdater()
    }
  }
  func check() { controller.checkForUpdates(nil) }
}

struct CheckUpdatesButton: View {
  @ObservedObject private var updates = AppUpdates.shared
  var body: some View {
    Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
  }
}
