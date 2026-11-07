import CryptoKit
import Darwin
import Foundation

public enum Firmware {
  static let limit = 4 * 1024 * 1024
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func checksums(_ data: Data) throws -> [String: String] {
    var result = [String: String]()
    for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true)
      guard parts.count == 2,
        parts[0].range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
        result[String(parts[1])] == nil
      else { throw PulseError("Invalid firmware checksum manifest.") }
      result[String(parts[1])] = parts[0].lowercased()
    }
    return result
  }
  static func fetch(_ string: String) async throws -> Data {
    var request = URLRequest(url: URL(string: string)!)
    request.timeoutInterval = 30
    request.setValue("SidePulse-Swift", forHTTPHeaderField: "User-Agent")
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit
    else { throw PulseError("Firmware download failed.") }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw PulseError("Firmware download is oversized.") }
      data.append(byte)
    }
    return data
  }
  static func verifyZIP(_ file: URL, device: Device) throws -> (version: String, payload: Data) {
    let name = file.deletingPathExtension().lastPathComponent
    let pattern = "^sidepulse-" + device.model.lowercased() + #"-[0-9]+\.[0-9]+\.[0-9]+-ota$"#
    guard name.range(of: pattern, options: .regularExpression) != nil, file.pathExtension == "zip",
      let length = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, length <= limit
    else {
      throw PulseError("Select an official \(device.model) OTA ZIP (up to 4 MiB).")
    }
    let version = String(name.split(separator: "-")[2])
    let required: Set<String> = [
      "FIRMWARE.BIN", "README.txt", "RELEASE_NOTES.txt", "SHA256SUMS.txt",
    ]
    let names = String(
      decoding: try SystemCommand.run("/usr/bin/unzip", ["-Z1", file.path]), as: UTF8.self
    ).split(whereSeparator: \.isNewline).map(String.init)
    let prefix = Set(names) == required ? "" : name + "/"
    guard names.count == required.count, Set(names) == Set(required.map { prefix + $0 }) else {
      throw PulseError("Unexpected archive layout.")
    }
    var contents = [String: Data]()
    var remaining = limit
    for entry in required {
      let data = try SystemCommand.run(
        "/usr/bin/unzip", ["-p", file.path, prefix + entry], limit: remaining)
      remaining -= data.count
      contents[entry] = data
    }
    let hashes = try checksums(contents["SHA256SUMS.txt"]!)
    guard Set(hashes.keys) == required.subtracting(["SHA256SUMS.txt"]),
      hashes.allSatisfy({ digest(contents[$0.key]!) == $0.value }),
      String(decoding: contents["README.txt"]!, as: UTF8.self).split(whereSeparator: \.isNewline)
        .first == "SidePulse \(device.model) firmware update - version \(version)",
      let payload = contents["FIRMWARE.BIN"], !payload.isEmpty
    else { throw PulseError("Invalid checksum, model or firmware version.") }
    return (version, payload)
  }
  public static func upgrade(_ device: Device, version: String?, file: String?, dryRun: Bool)
    async throws -> String
  {
    try await upgrade(device, version: version, file: file, dryRun: dryRun, fetch: fetch)
  }
  static func upgrade(
    _ device: Device, version: String?, file: String?, dryRun: Bool,
    fetch: (String) async throws -> Data
  ) async throws -> String {
    guard file == nil || version == nil else { throw PulseError("Choose a version or a file.") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Paths.directory(temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let url: URL
    if let file {
      url = URL(fileURLWithPath: file)
    } else {
      let valid = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
      let versions: [String]
      if let version {
        guard version.range(of: valid, options: .regularExpression) != nil else {
          throw PulseError("Use X.Y.Z for the version.")
        }
        versions = [version]
      } else {
        let listing = try await fetch(
          "https://api.github.com/repos/inteliwear/sidepulse/contents/firmware?ref=main")
        let entries = try JSONSerialization.jsonObject(with: listing) as? [JSONObject] ?? []
        versions = entries.compactMap { row in
          guard let name = row["name"] as? String, name.hasPrefix("v") else { return nil }
          let v = String(name.dropFirst())
          return v.range(of: valid, options: .regularExpression) != nil ? v : nil
        }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      }
      var selected: URL?
      for release in versions {
        let base =
          "https://raw.githubusercontent.com/inteliwear/sidepulse/main/firmware/v" + release
        let name = "sidepulse-\(device.model.lowercased())-\(release)-ota.zip"
        let hashes = try checksums(await fetch(base + "/SHA256SUMS.txt"))
        guard let expected = hashes[name] else { continue }
        let data = try await fetch(base + "/" + name)
        guard digest(data) == expected else { throw PulseError("Firmware ZIP checksum mismatch.") }
        let path = temporary.appendingPathComponent(name)
        try data.write(to: path)
        selected = path
        break
      }
      guard let selected else { throw PulseError("No compatible firmware release.") }
      url = selected
    }
    let verified = try verifyZIP(url, device: device)
    guard verified.version.compare(device.firmware, options: .numeric) != .orderedAscending else {
      throw PulseError("Firmware downgrade refused.")
    }
    if dryRun {
      return "Verified SidePulse \(device.model) firmware \(verified.version) (dry run)."
    }
    if verified.version == device.firmware {
      return "Firmware \(verified.version) is already installed."
    }
    guard try Device.inspect(device.root) == device else {
      throw PulseError("Device changed during verification.")
    }
    let fd = open(
      device.root.appendingPathComponent("FIRMWARE.BIN").path,
      O_WRONLY | O_TRUNC | O_CREAT | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw PulseError("Cannot open firmware destination.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try handle.write(contentsOf: verified.payload)
    try handle.synchronize()
    try handle.close()
    return
      "Firmware transferred. Leave the device connected for at least ten seconds, reconnect, then check its firmware version."
  }
}
