import Foundation
import PackagePlugin

/// Generates a Swift source file from a target's `.env` files at build time.
///
/// Attach it to any target that cannot read `.env` at runtime:
///
/// ```swift
/// .target(
///     name: "MyApp",
///     plugins: [.plugin(name: "EnvCodegenPlugin", package: "swift-env")]
/// )
/// ```
///
/// ### Why a build plugin rather than a macro
///
/// A macro that read `.env` during expansion would produce stale builds: the
/// build system tracks a macro's inputs as the source file and the plugin
/// binary, so editing `.env` would not trigger re-expansion and the previous
/// values would silently persist. A plugin runs inside the build graph, where
/// that dependency can be expressed.
///
/// ### How the dependency is expressed
///
/// Every `.env` file that exists is declared as an input, so the build system
/// tracks its modification time and editing one regenerates. The package
/// directory is declared too, because a directory's modification time is the only
/// signal available when a file is added or removed.
///
/// Only existing files may be declared: the build system refuses to run a command
/// whose declared inputs are missing.
///
/// ### Known limitation
///
/// Editing and creating `.env` files both regenerate correctly. **Deleting** one
/// that was present on the previous build fails every subsequent build with
///
/// ```
/// error: couldn't build ... because of missing inputs: .../.env.debug.local
/// ```
///
/// until the plugin is re-evaluated, which `touch Package.swift` or
/// `swift package clean` forces. The previous build's command list is reused and
/// still references the removed path, and a plugin cannot declare an input that
/// does not exist, so this cannot be fixed from here.
///
/// The alternative — declaring only the committed files — trades this loud,
/// one-command-to-fix error for silently stale values when a developer edits their
/// own `.env.local`, which is a worse failure. A prebuild command would avoid both
/// by running unconditionally, but SwiftPM forbids prebuild commands from using an
/// executable built from source, which this tool is.
@main
struct EnvCodegenPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        try [
            command(
                tool: context.tool(named: "env-codegen"),
                projectDirectory: context.package.directoryURL,
                workDirectory: context.pluginWorkDirectoryURL,
                targetName: target.name
            ),
        ]
    }

    private func command(
        tool: PluginContext.Tool,
        projectDirectory: URL,
        workDirectory: URL,
        targetName: String
    ) -> Command {
        let schema = Self.resolvedSchema()
        let output = workDirectory.appending(path: "EnvGenerated.swift")

        var candidates = [".env.example", ".env", ".env.local"]
        if let schema {
            candidates.append(".env.\(schema)")
            candidates.append(".env.\(schema).local")
        }

        var arguments = [
            "--directory", projectDirectory.path(),
            "--output", output.path(),
        ]
        if let schema {
            arguments += ["--schema", schema]
        }
        if let typeName = Self.environment["ENV_TYPE_NAME"] {
            arguments += ["--type-name", typeName]
        }
        if Self.environment["ENV_LENIENT"] == "1" {
            arguments.append("--lenient")
        }
        if Self.environment["ENV_NO_OBFUSCATE"] == "1" {
            arguments.append("--no-obfuscate")
        }

        // The directory covers creation and deletion, whose effect on a
        // directory's modification time is the only signal available; the files
        // cover edits.
        let inputs =
            [projectDirectory]
            + candidates
                .map { projectDirectory.appending(path: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path()) }

        return .buildCommand(
            displayName:
            "Generating configuration for \(targetName) (schema: \(schema ?? "none"))",
            executable: tool.url,
            arguments: arguments,
            inputFiles: inputs,
            outputFiles: [output]
        )
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// Chooses a schema from the build environment.
    ///
    /// In priority order: `ENV_SCHEMA`, then Xcode's `CONFIGURATION` build
    /// setting lowercased, then `debug`.
    private static func resolvedSchema() -> String? {
        if let explicit = environment["ENV_SCHEMA"], !explicit.isEmpty {
            return explicit
        }
        // Xcode exports the active build configuration to build phases, which is
        // how `Debug`/`Release` reach a plugin. SwiftPM does not, so
        // `swift build -c release` needs `ENV_SCHEMA` set explicitly.
        if let configuration = environment["CONFIGURATION"], !configuration.isEmpty {
            return configuration.lowercased()
        }
        return "debug"
    }
}

#if canImport(XcodeProjectPlugin)
    import XcodeProjectPlugin

    extension EnvCodegenPlugin: XcodeBuildToolPlugin {
        func createBuildCommands(
            context: XcodePluginContext,
            target: XcodeTarget
        ) throws -> [Command] {
            try [
                command(
                    tool: context.tool(named: "env-codegen"),
                    projectDirectory: context.xcodeProject.directoryURL,
                    workDirectory: context.pluginWorkDirectoryURL,
                    targetName: target.displayName
                ),
            ]
        }
    }
#endif
