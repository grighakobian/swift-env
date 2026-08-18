/// The set of keys an application requires, declared by `.env.example`.
///
/// Treating `.env.example` as a contract rather than a value source is what
/// keeps it from drifting: it drives the generated API surface, and resolution
/// fails when a key it declares has no value.
///
/// Values in `.env.example` are **illustrations, not defaults**. They are used
/// to infer types and to document the shape of a key, never substituted at
/// runtime — otherwise a placeholder like `API_KEY=your-key-here` could ship.
/// Real defaults belong in the committed `.env`.
public struct EnvContract: Sendable, Hashable {
    public var declarations: [EnvKeyDeclaration]
    public var path: String?

    public init(declarations: [EnvKeyDeclaration] = [], path: String? = nil) {
        self.declarations = declarations
        self.path = path
    }

    public subscript(key: String) -> EnvKeyDeclaration? {
        declarations.first { $0.key == key }
    }

    /// Keys that must be supplied: neither optional nor carrying a default.
    public var requiredKeys: [String] {
        declarations.lazy.filter { !$0.isOptional && $0.defaultValue == nil }.map(\.key)
    }

    /// Defaults declared by the contract, applied below every file.
    public var defaults: [String: String] {
        declarations.reduce(into: [:]) { result, declaration in
            if let defaultValue = declaration.defaultValue {
                result[declaration.key] = defaultValue
            }
        }
    }

    /// Builds a contract from a parsed `.env.example`.
    ///
    /// - Throws: ``EnvContractError`` when two keys would generate the same
    ///   Swift property name.
    public static func inferred(from document: EnvDocument) throws -> EnvContract {
        var declarations: [EnvKeyDeclaration] = []
        var namesInUse: [String: String] = [:] // swiftName -> key

        for entry in document.entries {
            let declaration = EnvKeyDeclaration(entry: entry)

            if let existing = namesInUse[declaration.swiftName], existing != entry.key {
                throw EnvContractError.duplicateSwiftName(
                    name: declaration.swiftName,
                    keys: [existing, entry.key],
                    path: document.path,
                    line: entry.line
                )
            }
            namesInUse[declaration.swiftName] = entry.key

            // A repeated key in the contract just refines the earlier one.
            if let index = declarations.firstIndex(where: { $0.key == entry.key }) {
                declarations[index] = declaration
            } else {
                declarations.append(declaration)
            }
        }

        return EnvContract(declarations: declarations, path: document.path)
    }
}

public enum EnvContractError: Error, Sendable, Hashable, CustomStringConvertible {
    case duplicateSwiftName(name: String, keys: [String], path: String?, line: Int)

    public var description: String {
        switch self {
        case let .duplicateSwiftName(name, keys, path, line):
            let location = "\(path ?? "<contract>"):\(line):1"
            return """
            \(location): error: keys \(keys.map { "'\($0)'" }.joined(separator: " and ")) \
            both generate the property name '\(name)'; \
            disambiguate one with an '# env: name=...' directive
            """
        }
    }
}

/// One declared key, with the type and metadata codegen needs.
public struct EnvKeyDeclaration: Sendable, Hashable {
    public var key: String
    public var type: EnvValueType
    public var isSecret: Bool
    public var isOptional: Bool

    /// The generated Swift property name.
    public var swiftName: String

    /// Comment lines above the key in `.env.example`, emitted as doc comments.
    public var documentation: [String]

    /// The illustrative value from `.env.example`. Never used as a default.
    public var exampleValue: String

    /// A value substituted when nothing else supplies the key, declared with
    /// `# env: default=...`.
    public var defaultValue: String?

    public var line: Int

    public init(entry: EnvEntry) {
        key = entry.key
        // Infer from the illustrative value, falling back to the declared
        // default when the illustration is blank.
        let inferenceSource =
            entry.value.isEmpty ? (entry.directives.defaultValue ?? "") : entry.value
        type =
            entry.directives.type
                ?? EnvValueType.inferred(from: inferenceSource, quoting: entry.quoting)
        isSecret = entry.directives.isSecret
        isOptional = entry.directives.isOptional
        swiftName = entry.directives.swiftName ?? EnvNaming.swiftPropertyName(for: entry.key)
        documentation = entry.leadingComments
        exampleValue = entry.value
        defaultValue = entry.directives.defaultValue
        line = entry.line
    }
}

public extension EnvValueType {
    /// Guesses a type from an illustrative value.
    ///
    /// Explicit quoting forces ``string``, giving a one-character escape hatch
    /// when a placeholder would otherwise be misread — `PORT="8080"` stays a
    /// string, while `PORT=8080` becomes an `Int`.
    static func inferred(from value: String, quoting: EnvQuoting = .none) -> EnvValueType {
        if quoting == .single || quoting == .double { return .string }

        let trimmed = value.trimmingASCIIWhitespace()
        guard !trimmed.isEmpty else { return .string }

        switch trimmed.lowercased() {
        case "true", "false", "yes", "no", "on", "off": return .bool
        default: break
        }

        if Int(trimmed) != nil { return .int }
        if Double(trimmed) != nil { return .double }
        if trimmed.contains("://") { return .url }

        if trimmed.contains(",") {
            let components = trimmed.split(separator: ",").map {
                String($0).trimmingASCIIWhitespace()
            }
            if components.allSatisfy({ Int($0) != nil }) { return .intArray }
            return .stringArray
        }

        return .string
    }
}

/// Converts environment variable names into idiomatic Swift identifiers.
public enum EnvNaming {
    /// Initialisms kept fully uppercase when they are not the first word, so
    /// `DATABASE_URL` becomes `databaseURL` rather than `databaseUrl`.
    /// Extend by spelling the property out with `# env: name=...` when a key
    /// needs a convention this set does not cover.
    static let initialisms: Set<String> = [
        "API", "ARN", "CDN", "CPU", "CSS", "DB", "DNS", "DSN", "FTP", "GPU",
        "GRPC", "HTML", "HTTP", "HTTPS", "ID", "IMAP", "IP", "JSON", "JWT",
        "MIME", "OS", "PEM", "PID", "RPC", "SDK", "SHA", "SMTP", "SQL", "SSH",
        "SSL", "TCP", "TLS", "TTL", "UDP", "UI", "UID", "URI", "URL", "UUID",
        "XML",
    ]

    /// Maps `API_BASE_URL` to `apiBaseURL`.
    ///
    /// Leading digits are prefixed with an underscore, and reserved words are
    /// left alone — codegen escapes those with backticks.
    public static func swiftPropertyName(for key: String) -> String {
        let words =
            key
                .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." })
                .map(String.init)
                .filter { !$0.isEmpty }

        guard let first = words.first else { return "_" }

        var name = first.lowercased()
        for word in words.dropFirst() {
            let upper = word.uppercased()
            if initialisms.contains(upper) {
                name += upper
            } else {
                name += word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
        }

        if let leading = name.first, leading.isNumber {
            name = "_" + name
        }
        return name
    }

    /// Swift keywords that must be wrapped in backticks when used as a member
    /// name. Not exhaustive for all positions, but complete for properties.
    static let reservedWords: Set<String> = [
        "as", "associatedtype", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "let", "nil",
        "operator", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "where", "while",
    ]

    /// Wraps `name` in backticks when it collides with a Swift keyword.
    public static func escaped(_ name: String) -> String {
        reservedWords.contains(name) ? "`\(name)`" : name
    }
}
