/// How a value was quoted in the source file.
///
/// Quoting is retained after parsing because it changes semantics: single-quoted
/// values are literal, while bare and double-quoted values take part in variable
/// interpolation.
public enum EnvQuoting: Sendable, Hashable {
    case none
    case single
    case double
    case backtick

    /// Whether `${VAR}` references inside the value should be expanded.
    public var allowsInterpolation: Bool {
        switch self {
        case .none, .double: true
        case .single, .backtick: false
        }
    }
}

/// A single `KEY=value` assignment, along with the source metadata that codegen
/// and diagnostics need.
public struct EnvEntry: Sendable, Hashable {
    public var key: String

    /// The value with quotes stripped and escape sequences resolved, but before
    /// variable interpolation.
    public var value: String

    public var quoting: EnvQuoting

    /// 1-based line number of the assignment.
    public var line: Int

    /// Comment lines immediately preceding the assignment, with the leading `#`
    /// and one space removed. Used as documentation in generated code.
    public var leadingComments: [String]

    /// Directives parsed out of preceding `# env:` comments.
    public var directives: EnvDirectives

    public init(
        key: String,
        value: String,
        quoting: EnvQuoting = .none,
        line: Int = 0,
        leadingComments: [String] = [],
        directives: EnvDirectives = .init()
    ) {
        self.key = key
        self.value = value
        self.quoting = quoting
        self.line = line
        self.leadingComments = leadingComments
        self.directives = directives
    }
}

/// A parsed `.env` file: assignments in source order.
public struct EnvDocument: Sendable, Hashable {
    public var entries: [EnvEntry]

    /// The path this document was parsed from, when it came from disk.
    public var path: String?

    public init(entries: [EnvEntry] = [], path: String? = nil) {
        self.entries = entries
        self.path = path
    }

    /// The last value assigned to `key`, matching the shell convention that a
    /// later assignment overrides an earlier one.
    public subscript(key: String) -> String? {
        entries.last { $0.key == key }?.value
    }

    /// Keys in first-appearance order, deduplicated.
    public var keys: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.key).inserted ? $0.key : nil }
    }

    /// Collapses the document to a dictionary, with later assignments winning.
    public var dictionary: [String: String] {
        entries.reduce(into: [:]) { $0[$1.key] = $1.value }
    }
}
