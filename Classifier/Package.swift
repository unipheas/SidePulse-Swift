// swift-tools-version: 5.10
import PackageDescription

// Keep the optional Metal backend separate so the main app and its tests also build on Intel.
let package = Package(
  name: "SidePulseClassifier",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "sidepulse-classifier", targets: ["ClassifierHelper"])],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.29.3"),
    // Newer Collections releases require Swift 6.4; retain Xcode 16.4 compatibility.
    .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
    .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.5.2"),
  ],
  targets: [
    .target(name: "ClassifierPrompt", dependencies: [.product(name: "Jinja", package: "swift-jinja")]),
    .executableTarget(
      name: "ClassifierHelper",
      dependencies: [
        "ClassifierPrompt",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
      ]),
    .testTarget(name: "ClassifierTests", dependencies: ["ClassifierPrompt"]),
  ]
)
