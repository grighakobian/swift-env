/// A named configuration schema, such as `debug`, `staging`, or `production`.
///
/// The schema selects which `.env.<schema>` files participate in resolution; it
/// does not by itself supply values.
public struct EnvSchema: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { name }

    public static let debug = EnvSchema("debug")
    public static let release = EnvSchema("release")
    public static let development = EnvSchema("development")
    public static let staging = EnvSchema("staging")
    public static let production = EnvSchema("production")
    public static let test = EnvSchema("test")
}

/// Describes which files take part in resolution, and in what order.
///
/// Precedence follows the widely-used `dotenv-flow` convention, listed here from
/// lowest to highest:
///
/// | File | Committed | Purpose |
/// | --- | --- | --- |
/// | `.env` | yes | shared defaults |
/// | `.env.local` | no | personal overrides, every schema |
/// | `.env.<schema>` | yes | schema defaults, e.g. `.env.debug` |
/// | `.env.<schema>.local` | no | personal overrides, one schema |
///
/// Process environment variables sit above all of these by default, so CI and
/// deployment platforms can override without editing files.
///
/// `.env.example` is deliberately absent: it declares the *contract* and is
/// never a source of values. See ``EnvContract``.
public struct EnvFileLayout: Sendable, Hashable {
    /// Directory holding the `.env` files, normally the package or project root.
    public var directory: String

    /// The active schema, or `nil` to consult only the schema-agnostic files.
    public var schema: EnvSchema?

    /// Includes the gitignored `.env*.local` files.
    ///
    /// Conventionally disabled for the `test` schema so that a personal machine
    /// cannot change test outcomes.
    public var includesLocalOverrides: Bool

    /// Base name of the files, exposed mainly so a project can rename the set.
    public var baseName: String

    public init(
        directory: String,
        schema: EnvSchema? = nil,
        includesLocalOverrides: Bool = true,
        baseName: String = ".env"
    ) {
        self.directory = directory
        self.schema = schema
        self.includesLocalOverrides = includesLocalOverrides
        self.baseName = baseName
    }

    /// File names in ascending precedence: later files override earlier ones.
    public var fileNames: [String] {
        var names = [baseName]
        if includesLocalOverrides {
            names.append("\(baseName).local")
        }
        if let schema {
            names.append("\(baseName).\(schema.name)")
            if includesLocalOverrides {
                names.append("\(baseName).\(schema.name).local")
            }
        }
        return names
    }

    /// Absolute-ish paths in ascending precedence, formed by joining
    /// ``directory`` with each entry of ``fileNames``.
    public var filePaths: [String] {
        fileNames.map { EnvPath.join(directory, $0) }
    }

    /// Path of the contract file, `.env.example`.
    public var contractPath: String {
        EnvPath.join(directory, "\(baseName).example")
    }
}

/// Minimal path joining, kept here so this target needs no Foundation import.
public enum EnvPath {
    public static func join(_ directory: String, _ component: String) -> String {
        guard !directory.isEmpty else { return component }
        return directory.hasSuffix("/") ? directory + component : directory + "/" + component
    }

    public static func lastComponent(of path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}
