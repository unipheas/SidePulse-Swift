import Foundation

/// Shared cancellable delay for command polling loops.
enum Polling {
  static func wait(_ seconds: Double) async throws {
    try await Task.sleep(for: .seconds(seconds))
  }
}
