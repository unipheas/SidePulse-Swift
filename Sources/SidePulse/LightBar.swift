import AppKit
import PulseCore
import SwiftUI

struct LightBar: View {
  var source: String
  var count: Int
  @State private var simulator: LEDPreview?
  @State private var start = Date()
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading) {
      TimelineView(.animation(minimumInterval: 1 / 20)) { time in
        let rgb =
          simulator?.frame(milliseconds: Int(time.date.timeIntervalSince(start) * 1000)) ?? []
        HStack(spacing: 10) {
          ForEach(0..<count, id: \.self) { index in
            let i = index * 3
            let color =
              rgb.count > i + 2
              ? Color(
                red: Double(rgb[i]) / 255, green: Double(rgb[i + 1]) / 255,
                blue: Double(rgb[i + 2]) / 255) : Color.black
            RoundedRectangle(cornerRadius: 8).fill(color)
              .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 1))
              .shadow(color: color.opacity(0.55), radius: 7)
              .frame(maxWidth: 54).frame(height: 35)
          }
        }.padding(26).frame(maxWidth: .infinity).background(
          Color(red: 0.055, green: 0.073, blue: 0.085), in: RoundedRectangle(cornerRadius: 15))
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.task(id: "\(count):\(source)") {
      do {
        simulator = try LEDPreview(program: source, count: count)
        start = Date()
        error = nil
      } catch {
        simulator = nil
        self.error = error.localizedDescription
      }
    }.accessibilityLabel("LED animation preview")
  }
}
