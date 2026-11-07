import SwiftUI

/// Hide Form's automatic label when a row already supplies its own label.
struct SettingField: View {
  let label: String
  @Binding var text: String
  var unit: String = "seconds"
  var identifier: String = ""
  var body: some View {
    HStack(spacing: 8) {
      TextField(label, text: $text)
        .labelsHidden().textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing).monospacedDigit()
        .frame(width: 82).accessibilityLabel(label).accessibilityIdentifier(identifier)
      Text(unit).foregroundStyle(.secondary).fixedSize()
    }.fixedSize(horizontal: true, vertical: false)
  }
}
