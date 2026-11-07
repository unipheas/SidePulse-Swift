// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "SidePulseSwift",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SidePulse", targets: ["SidePulse"]),
    .executable(name: "sidepulse-swift", targets: ["PulseCLI"]),
    .library(name: "PulseCore", targets: ["PulseCore"]),
  ],
  targets: [
    .target(
      name: "USBControl",
      linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("DiskArbitration")]),
    .target(
      name: "PulseCore", dependencies: ["USBControl"],
      resources: [
        .copy("Resources/animations"), .copy("Resources/sdled.wasm"), .copy("Resources/profiles"),
      ]),
    .executableTarget(name: "SidePulse", dependencies: ["PulseCore"]),
    .executableTarget(name: "PulseCLI", dependencies: ["PulseCore"]),
    .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
  ]
)
