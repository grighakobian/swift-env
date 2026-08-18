// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-env",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        // Runtime library: parses and resolves `.env` files on disk.
        // Use this for server-side and CLI targets.
        .library(name: "EnvKit", targets: ["EnvKit"]),

        // Build-time codegen: bakes resolved values into a generated Swift
        // source file. Use this for app targets, where no `.env` exists at
        // runtime.
        .plugin(name: "EnvCodegenPlugin", targets: ["EnvCodegenPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0" ..< "605.0.0"),
    ],
    targets: [
        // The parser and schema resolver. Deliberately Foundation-light and
        // dependency-free so both the runtime library and the codegen
        // executable can share it.
        .target(name: "EnvKitCore"),

        // Declares the macros alongside the runtime they expand into, so one
        // `import EnvKit` brings both.
        .target(name: "EnvKit", dependencies: ["EnvKitCore", "EnvKitMacrosPlugin"]),

        .macro(
            name: "EnvKitMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        .executableTarget(name: "env-codegen", dependencies: ["EnvKitCore"]),

        .plugin(
            name: "EnvCodegenPlugin",
            capability: .buildTool(),
            dependencies: ["env-codegen"]
        ),

        .testTarget(name: "EnvKitCoreTests", dependencies: ["EnvKitCore"]),
        .testTarget(name: "EnvKitTests", dependencies: ["EnvKit"]),
        .testTarget(
            name: "EnvKitMacrosTests",
            dependencies: [
                "EnvKitMacrosPlugin",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
