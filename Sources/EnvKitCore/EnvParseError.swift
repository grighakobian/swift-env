/// A syntax error in a `.env` file, carrying enough location detail to emit an
/// Xcode- and GCC-compatible diagnostic.
public struct EnvParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case invalidKey(String)
        case emptyKey
        case expectedAssignment(key: String)
        case unterminatedQuote(EnvQuoting)
        case unexpectedTrailingCharacters(String)

        public var message: String {
            switch self {
            case let .invalidKey(key):
                "invalid key '\(key)': expected a letter or underscore followed by letters, digits, or underscores"
            case .emptyKey:
                "expected a key before '='"
            case let .expectedAssignment(key):
                "expected '=' after key '\(key)'"
            case let .unterminatedQuote(quoting):
                "unterminated \(quoting.errorDescription) value"
            case let .unexpectedTrailingCharacters(text):
                "unexpected text after value: '\(text)'"
            }
        }
    }

    public var kind: Kind
    /// 1-based.
    public var line: Int
    /// 1-based.
    public var column: Int
    public var path: String?

    public init(kind: Kind, line: Int, column: Int, path: String? = nil) {
        self.kind = kind
        self.line = line
        self.column = column
        self.path = path
    }

    /// Formatted as `path:line:column: error: message`, which Xcode and most
    /// editors surface as a navigable diagnostic.
    public var description: String {
        "\(path ?? "<env>"):\(line):\(column): error: \(kind.message)"
    }
}

private extension EnvQuoting {
    var errorDescription: String {
        switch self {
        case .none: "unquoted"
        case .single: "single-quoted"
        case .double: "double-quoted"
        case .backtick: "backtick-quoted"
        }
    }
}
