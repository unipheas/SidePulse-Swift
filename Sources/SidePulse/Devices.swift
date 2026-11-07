import PulseCore
import SwiftUI

struct DeviceManagement: View {
  @EnvironmentObject var model: Dashboard
  @State private var firmwareDevice: Device?
  @State private var firmwareStatus = ""
  @State private var busy = false
  @State private var confirm = false
  @State private var phones: [Phone] = []
  @State private var token = ""
  @State private var name = ""
  @State private var phoneStatus = ""
  var body: some View {
    Form {
      Section("Connected devices") {
        ForEach(model.devices) { device in
          LabeledContent("SidePulse " + device.model, value: device.firmware)
          let config = Settings.device(device.id, in: model.settings)
          Slider(
            value: Binding(
              get: { Double(config["brightness"] as? Int ?? 255) },
              set: { value in
                model.change { settings in
                  Settings.editDevice(device.id, in: &settings, values: ["brightness": Int(value)])
                }
              }), in: 0...255, step: 1
          ) { Text("Brightness") }
          HStack {
            Button("Check firmware") { update(device, dry: true) }.disabled(busy)
            Button("Update firmware…") {
              firmwareDevice = device
              confirm = true
            }.disabled(busy)
          }
        }
        if model.devices.isEmpty {
          Text("Connect a SidePulse Pro or Dot.").foregroundStyle(.secondary)
        }
        if !firmwareStatus.isEmpty { Text(firmwareStatus).textSelection(.enabled) }
        if busy { ProgressView() }
      }
      Section("Linked phones") {
        ForEach(phones, id: \.id) { phone in
          HStack {
            Text(phone.name)
            Spacer()
            Button("Remove") {
              do {
                try Bridge.remove(phone.id)
                reload()
              } catch { phoneStatus = error.localizedDescription }
            }
          }
        }
        TextField("Phone name", text: $name).accessibilityIdentifier("phone-name")
        SecureField("Push token", text: $token).accessibilityIdentifier("phone-token")
        Button("Link phone") {
          do {
            try Bridge.store(token: token, name: name.isEmpty ? "Phone" : name)
            token = ""
            name = ""
            phoneStatus = ""
            reload()
          } catch { phoneStatus = error.localizedDescription }
        }.disabled(token.isEmpty)
        if !phoneStatus.isEmpty { Text(phoneStatus).foregroundStyle(.secondary) }
      }
    }.formStyle(.grouped).onAppear(perform: reload)
      .confirmationDialog("Install firmware on this SidePulse?", isPresented: $confirm) {
        Button("Install firmware") {
          if let device = firmwareDevice { update(device, dry: false) }
        }
      } message: {
        Text(
          "Keep the device connected throughout the transfer and for at least ten seconds afterward."
        )
      }
  }
  private func reload() {
    do { phones = try Bridge.phones() } catch { phoneStatus = error.localizedDescription }
  }
  private func update(_ device: Device, dry: Bool) {
    busy = true
    firmwareStatus = "Checking firmware…"
    Task {
      defer { busy = false }
      do {
        firmwareStatus = try await Firmware.upgrade(device, version: nil, file: nil, dryRun: dry)
      } catch { firmwareStatus = error.localizedDescription }
    }
  }
}
