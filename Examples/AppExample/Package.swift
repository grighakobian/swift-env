// swift-tools-version: 6.0

import PackageDescription

/// Demonstrates the build-time path: values are baked into a generated Swift
/// file, because an app bundle has no `.env` to read at runtime.
let package = Package(
  name: "AppExample",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "AppExample",
      plugins: [.plugin(name: "EnvCodegenPlugin", package: "swift-env")]
    ),
  ]
)
