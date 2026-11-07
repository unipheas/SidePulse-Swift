// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "SidePulseSwift",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SidePulse", targets: ["SidePulse"]),
    .executable(name: "sidepulsectl", targets: ["PulseCLI"]),
    .library(name: "PulseCore", targets: ["PulseCore"]),
  ],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
  targets: [
    .target(
      name: "USBControl",
      linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("DiskArbitration")]),
    .target(
      name: "PulseCore", dependencies: ["USBControl"],
      resources: [
        .copy("Resources/animations"), .copy("Resources/sdled.wasm"), .copy("Resources/profiles"),
      ]),
    .executableTarget(
      name: "SidePulse",
      dependencies: ["PulseCore", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .executableTarget(name: "PulseCLI", dependencies: ["PulseCore"]),
    .target(
      name: "USBTestSupport", dependencies: ["USBControl"], path: "Tests/USBTestSupport",
      publicHeadersPath: "include"),
    .testTarget(
      name: "PulseCoreTests",
      dependencies: ["PulseCore", "SidePulse", "PulseCLI", "USBTestSupport"],
      resources: [.copy("Fixtures")]),
  ]
)
