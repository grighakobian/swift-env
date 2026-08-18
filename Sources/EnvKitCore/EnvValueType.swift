/// The Swift type a configuration key decodes to.
///
/// Inferred from the example value in `.env.example`, or stated explicitly with
/// an `# env: type=...` directive.
public enum EnvValueType: String, Sendable, Hashable, CaseIterable {
    case string
    case int
    case double
    case bool
    case url
    case data
    case stringArray
    case intArray

    /// The spelling accepted in an `# env: type=...` directive.
    public var directiveName: String {
        switch self {
        case .string: "String"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .url: "URL"
        case .data: "Data"
        case .stringArray: "[String]"
        case .intArray: "[Int]"
        }
    }

    /// The type as written in generated Swift source.
    public var swiftTypeName: String { directiveName }

    public init?(directiveName: String) {
        let normalized = directiveName.trimmingASCIIWhitespace()
        guard
            let match = Self.allCases.first(where: {
                $0.directiveName.lowercased() == normalized.lowercased()
            })
        else { return nil }
        self = match
    }
}

/// Metadata attached to a key by `# env:` comments in `.env.example`.
///
/// Directives are read from comment lines immediately above an assignment:
/// ```
/// # The upstream API endpoint.
/// # env: type=URL, secret
/// API_URL=https://example.com
/// ```
public struct EnvDirectives: Sendable, Hashable {
    /// An explicit type, overriding inference from the example value.
    public var type: EnvValueType?

    /// Marks the value as sensitive: it is redacted in descriptions and
    /// diagnostics, and codegen warns when baking it into a binary.
    public var isSecret: Bool

    /// Allows the key to be absent without failing validation. The generated
    /// property becomes optional.
    public var isOptional: Bool

    /// Overrides the generated Swift property name.
    public var swiftName: String?

    /// A value used when no file or environment variable supplies the key.
    ///
    /// Unlike the illustrative value on the assignment itself, this *is*
    /// substituted, so a key with a default is never reported as missing.
    public var defaultValue: String?

    public init(
        type: EnvValueType? = nil,
        isSecret: Bool = false,
        isOptional: Bool = false,
        swiftName: String? = nil,
        defaultValue: String? = nil
    ) {
        self.type = type
        self.isSecret = isSecret
        self.isOptional = isOptional
        self.swiftName = swiftName
        self.defaultValue = defaultValue
    }

    public var isEmpty: Bool {
        type == nil && !isSecret && !isOptional && swiftName == nil && defaultValue == nil
    }

    /// Parses the body of an `# env:` comment, e.g. `type=URL, secret`.
    ///
    /// Unrecognized fields are collected into `unknownFields` rather than
    /// rejected, so a newer directive vocabulary does not break older tooling.
    public static func parse(
        _ body: String,
        unknownFields: inout [String]
    ) -> EnvDirectives {
        var directives = EnvDirectives()

        // `default=` takes the rest of the line verbatim, so a default value may
        // itself contain commas. It therefore has to sit on its own comment
        // line, which is also the clearest way to write it.
        let trimmedBody = body.trimmingASCIIWhitespace()
        if trimmedBody.lowercased().hasPrefix("default=") {
            directives.defaultValue = String(trimmedBody.dropFirst("default=".count))
            return directives
        }

        for rawField in body.split(separator: ",") {
            let field = String(rawField).trimmingASCIIWhitespace()
            guard !field.isEmpty else { continue }

            let parts = field.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingASCIIWhitespace()
            }
            let name = parts[0].lowercased()
            let argument = parts.count > 1 ? parts[1] : nil

            switch (name, argument) {
            case let ("type", value?):
                if let type = EnvValueType(directiveName: value) {
                    directives.type = type
                } else {
                    unknownFields.append(field)
                }
            case let ("name", value?):
                directives.swiftName = value
            case let ("default", value?):
                directives.defaultValue = value
            case ("secret", nil), ("sensitive", nil):
                directives.isSecret = true
            case ("optional", nil):
                directives.isOptional = true
            default:
                unknownFields.append(field)
            }
        }
        return directives
    }
}
