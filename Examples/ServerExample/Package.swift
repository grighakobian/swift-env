// swift-tools-version: 6.0

import PackageDescription

/// Demonstrates the runtime path: `.env` files are read on launch, so editing
/// one takes effect on the next run with no rebuild.
let package = Package(
  name: "ServerExample",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "ServerExample",
      dependencies: [.product(name: "EnvKit", package: "swift-env")]
    ),
  ]
)
