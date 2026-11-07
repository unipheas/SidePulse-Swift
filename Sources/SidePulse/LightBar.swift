import AppKit
import PulseCore
import SwiftUI

struct LightBar: View {
  var source: String
  var count: Int
  var compact = false
  var initialProgram: String? = nil
  @State private var simulator: LEDPreview?
  @State private var start = Date()
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading) {
      TimelineView(.animation(minimumInterval: compact ? 1 / 12 : 1 / 20)) { time in
        let rgb =
          simulator?.frame(milliseconds: Int(time.date.timeIntervalSince(start) * 1000)) ?? []
        HStack(spacing: compact ? 4 : 6) {
          ForEach(0..<count, id: \.self) { index in
            let i = index * 3
            let color =
              rgb.count > i + 2
              ? Color(
                red: Double(rgb[i]) / 255, green: Double(rgb[i + 1]) / 255,
                blue: Double(rgb[i + 2]) / 255) : Color.black
            RoundedRectangle(cornerRadius: compact ? 3 : 5).fill(color)
              .overlay(
                RoundedRectangle(cornerRadius: compact ? 3 : 5).stroke(
                  .white.opacity(0.15), lineWidth: 1)
              )
              .shadow(color: color.opacity(0.55), radius: compact ? 3 : 5)
              .frame(width: compact ? 15 : 28, height: compact ? 11 : 19)
          }
        }.padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 8 : 12).background(
          Color(red: 0.055, green: 0.073, blue: 0.085),
          in: RoundedRectangle(cornerRadius: compact ? 7 : 10))
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.task(id: "\(count):\(source)") {
      do {
        simulator = try LEDPreview(program: source, count: count, initialProgram: initialProgram)
        start = Date()
        error = nil
      } catch {
        simulator = nil
        self.error = error.localizedDescription
      }
    }.accessibilityLabel("LED animation preview")
  }
}
