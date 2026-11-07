import PulseCore
import SwiftUI

struct DeviceManagement: View {
  @EnvironmentObject var model: Dashboard
  @StateObject var firmware = FirmwareUpdate()
  @State private var phones: [Phone] = []
  @State private var token = ""
  @State private var name = ""
  @State private var phoneStatus = ""
  var body: some View {
    Form {
      Section("Connected devices") {
        ForEach(model.devices) { device in
          LabeledContent("SidePulse " + device.model, value: device.firmware)
          DeviceDisplayPreference(id: device.id, title: "Display")
          DeviceBrightnessPreference(id: device.id)
          HStack {
            Button("Check firmware") { Task { await firmware.update(device, dry: true) } }.disabled(
              firmware.busy)
            Button("Update firmware…") {
              firmware.request(device)
            }.disabled(firmware.busy)
          }
        }
        if model.devices.isEmpty {
          Text("Connect a SidePulse Pro or Dot.").foregroundStyle(.secondary)
        }
        if !firmware.status.isEmpty { Text(firmware.status).textSelection(.enabled) }
        if firmware.busy { ProgressView() }
      }
      if !remembered.isEmpty {
        Section("Disconnected devices") {
          ForEach(remembered, id: \.self) { id in
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Text(
                  Settings.device(id, in: model.settings)["name"] as? String
                    ?? URL(fileURLWithPath: id).lastPathComponent
                ).font(.headline)
                Spacer()
                Button("Forget") {
                  model.change { settings in
                    var rows = settings["devices"] as? [JSONObject] ?? []
                    rows.removeAll { $0["id"] as? String == id }
                    settings["devices"] = rows
                  }
                }.accessibilityIdentifier("forget-device-" + id)
              }
              DeviceDisplayPreference(id: id, title: "Display")
              DeviceBrightnessPreference(id: id)
            }
          }
        }
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
          DeviceDisplayPreference(id: phone.deviceID, title: "Display", allowsBattery: false)
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
      .confirmationDialog("Install firmware on this SidePulse?", isPresented: $firmware.confirm) {
        Button("Install firmware") {
          Task { await firmware.install() }
        }
      } message: {
        Text(
          "Keep the device connected throughout the transfer and for at least ten seconds afterward."
        )
      }
  }
  private var remembered: [String] {
    let connected = Set(model.devices.map(\.id))
    return (model.settings["devices"] as? [JSONObject] ?? [])
      .compactMap { $0["id"] as? String }
      .filter { !$0.hasPrefix("virtual:") && !$0.hasPrefix("ios/") && !connected.contains($0) }
      .sorted()
  }
  private func reload() {
    do { phones = try Bridge.phones() } catch { phoneStatus = error.localizedDescription }
  }

}

struct DeviceBrightnessPreference: View {
  @EnvironmentObject var model: Dashboard
  let id: String
  var body: some View {
    Slider(
      value: Binding(
        get: { Double(Settings.device(id, in: model.settings)["brightness"] as? Int ?? 255) },
        set: { value in
          model.change { Settings.editDevice(id, in: &$0, values: ["brightness": Int(value)]) }
        }), in: 0...255, step: 1
    ) { Text("Brightness") }
    .accessibilityIdentifier("device-brightness-" + id)
  }
}
struct DeviceDisplayPreference: View {
  @EnvironmentObject var model: Dashboard
  let id: String
  let title: String
  var allowsBattery = true
  var body: some View {
    Picker(
      title,
      selection: Binding(
        get: { Settings.device(id, in: model.settings)["led_display"] as? String ?? "agent" },
        set: { value in
          model.change { Settings.editDevice(id, in: &$0, values: ["led_display": value]) }
        })
    ) {
      Text("Agent status").tag("agent")
      if allowsBattery { Text("Battery").tag("battery") }
      Text("Manual").tag("custom")
    }.accessibilityIdentifier("device-display-" + id)
  }
}
