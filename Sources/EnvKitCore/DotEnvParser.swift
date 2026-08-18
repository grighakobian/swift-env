/// A scanner-based parser for `.env` files.
///
/// Works on characters rather than lines so that quoted values can span
/// newlines, which the line-splitting parsers commonly found in this space
/// cannot represent:
///
/// ```
/// PRIVATE_KEY="-----BEGIN KEY-----
/// abc123
/// -----END KEY-----"
/// ```
///
/// ### Supported syntax
/// - `KEY=value`, with an optional `export ` prefix
/// - single-, double-, and backtick-quoted values, which may span lines
/// - escape sequences in double-quoted values: `\n`, `\r`, `\t`, `\\`, `\"`, `\'`
/// - full-line comments, and trailing comments after whitespace
/// - repeated keys, where the last assignment wins
///
/// `${VAR}` references are *not* expanded here; the parser records quoting so
/// that ``EnvInterpolator`` can expand them once files have been layered.
public struct DotEnvParser: Sendable {
  public struct Options: Sendable {
    /// Accepts a leading `export ` on assignments, so a `.env` file can
    /// double as something you `source` from a shell.
    public var allowsExportPrefix: Bool

    /// Rejects keys that are not valid POSIX environment variable names.
    /// When disabled, such keys are kept as-is.
    public var validatesKeys: Bool

    public init(allowsExportPrefix: Bool = true, validatesKeys: Bool = true) {
      self.allowsExportPrefix = allowsExportPrefix
      self.validatesKeys = validatesKeys
    }

    public static var `default`: Options { Options() }
  }

  private let characters: [Character]
  private let path: String?
  private let options: Options

  private var index: Int = 0
  private var line: Int = 1
  private var lineStartIndex: Int = 0

  private init(contents: String, path: String?, options: Options) {
    characters = Array(contents)
    self.path = path
    self.options = options
  }

  /// Parses `contents` into a document of assignments in source order.
  ///
  /// - Parameter path: Used only to label diagnostics.
  public static func parse(
    _ contents: String,
    path: String? = nil,
    options: Options = .default
  ) throws -> EnvDocument {
    var parser = DotEnvParser(contents: contents, path: path, options: options)
    return try parser.parseDocument()
  }

  // MARK: - Document

  private mutating func parseDocument() throws -> EnvDocument {
    var entries: [EnvEntry] = []
    var pendingComments: [String] = []
    var pendingDirectives = EnvDirectives()

    while !isAtEnd {
      skipInlineWhitespace()

      guard let character = peek() else { break }

      if character.isNewline {
        // Comments and assignments consume their own line terminator,
        // so reaching one here means the line was genuinely blank. A
        // blank line detaches a comment block, keeping comments bound
        // to the assignment they actually sit above.
        consumeNewline()
        pendingComments = []
        pendingDirectives = EnvDirectives()
        continue
      }

      if character == "#" {
        let comment = readComment()
        if let directiveBody = Self.directiveBody(in: comment) {
          var unknownFields: [String] = []
          let parsed = EnvDirectives.parse(directiveBody, unknownFields: &unknownFields)
          pendingDirectives.merge(parsed)
        } else {
          pendingComments.append(comment)
        }
        continue
      }

      var entry = try readAssignment()
      entry.leadingComments = pendingComments
      entry.directives = pendingDirectives
      entries.append(entry)

      pendingComments = []
      pendingDirectives = EnvDirectives()
    }

    return EnvDocument(entries: entries, path: path)
  }

  /// Returns the body of an `# env:` / `# swift-env:` directive comment.
  private static func directiveBody(in comment: String) -> String? {
    let trimmed = comment.trimmingASCIIWhitespace()
    for prefix in ["swift-env:", "env:"] {
      if trimmed.count > prefix.count,
         trimmed.prefix(prefix.count).lowercased() == prefix
      {
        return String(trimmed.dropFirst(prefix.count))
      }
    }
    return nil
  }

  // MARK: - Assignments

  private mutating func readAssignment() throws -> EnvEntry {
    let entryLine = line

    if options.allowsExportPrefix { consumeExportPrefixIfPresent() }

    let keyColumn = column
    let key = readKey()

    if key.isEmpty {
      throw error(.emptyKey, column: keyColumn)
    }
    if options.validatesKeys, !Self.isValidKey(key) {
      throw error(.invalidKey(key), column: keyColumn)
    }

    skipInlineWhitespace()
    guard peek() == "=" else {
      throw error(.expectedAssignment(key: key), column: column)
    }
    advance()
    let isSeparatedFromValue = skipInlineWhitespace()

    let (value, quoting) = try readValue(precededByWhitespace: isSeparatedFromValue)

    // A quoted value may be followed by whitespace and a trailing comment;
    // anything else is a mistake worth reporting rather than silently
    // folding into the value.
    skipInlineWhitespace()
    if peek() == "#" {
      _ = readComment() // also consumes the line terminator
    } else if let character = peek(), !character.isNewline {
      let trailingColumn = column
      let trailing = readToEndOfLine().trimmingASCIIWhitespace()
      throw error(.unexpectedTrailingCharacters(trailing), column: trailingColumn)
    } else if peek() != nil {
      consumeNewline()
    }

    return EnvEntry(key: key, value: value, quoting: quoting, line: entryLine)
  }

  private mutating func consumeExportPrefixIfPresent() {
    let savedIndex = index
    var word = ""
    while let character = peek(), character.isLetter {
      word.append(character)
      advance()
    }
    // Require whitespace after `export`, otherwise `exportKEY=1` would lose
    // its prefix.
    if word == "export", let next = peek(), next == " " || next == "\t" {
      skipInlineWhitespace()
    } else {
      index = savedIndex
    }
  }

  private mutating func readKey() -> String {
    var key = ""
    while let character = peek(), Self.isKeyCharacter(character) {
      key.append(character)
      advance()
    }
    return key
  }

  private static func isKeyCharacter(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
  }

  private static func isValidKey(_ key: String) -> Bool {
    guard let first = key.first, first == "_" || first.isLetter else { return false }
    return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  // MARK: - Values

  /// - Parameter precededByWhitespace: Whether whitespace separated `=` from
  ///   the value. This decides how a leading `#` is read: `COLOR=#ff0000` is a
  ///   value, while `COLOR= #ff0000` is an empty value plus a comment.
  private mutating func readValue(
    precededByWhitespace: Bool
  ) throws -> (value: String, quoting: EnvQuoting) {
    guard let character = peek(), !character.isNewline else {
      return ("", .none)
    }

    switch character {
    case "'": return try (readQuoted(terminator: "'", quoting: .single), .single)
    case "`": return try (readQuoted(terminator: "`", quoting: .backtick), .backtick)
    case "\"": return try (readDoubleQuoted(), .double)
    default:
      return (readBareValue(startsAfterWhitespace: precededByWhitespace), .none)
    }
  }

  /// Reads a literal quoted value. No escape processing, so the content is
  /// exactly what appears between the delimiters.
  private mutating func readQuoted(
    terminator: Character,
    quoting: EnvQuoting
  ) throws -> String {
    let openLine = line
    let openColumn = column
    advance() // opening delimiter

    var value = ""
    while let character = peek() {
      if character == terminator {
        advance()
        return value
      }
      if character.isNewline {
        value.append("\n")
        consumeNewline()
        continue
      }
      value.append(character)
      advance()
    }

    throw EnvParseError(
      kind: .unterminatedQuote(quoting),
      line: openLine,
      column: openColumn,
      path: path
    )
  }

  /// Reads a double-quoted value, resolving escape sequences.
  ///
  /// `\$` is deliberately preserved as `\$` so that interpolation, which runs
  /// later, can tell an escaped dollar sign from a live reference.
  private mutating func readDoubleQuoted() throws -> String {
    let openLine = line
    let openColumn = column
    advance() // opening quote

    var value = ""
    while let character = peek() {
      if character == "\"" {
        advance()
        return value
      }

      if character == "\\" {
        advance()
        guard let escaped = peek() else { break }
        if escaped.isNewline {
          // A backslash-newline continues the value without inserting
          // a line break, matching shell behavior.
          consumeNewline()
          continue
        }
        advance()
        switch escaped {
        case "n": value.append("\n")
        case "r": value.append("\r")
        case "t": value.append("\t")
        case "0": value.append("\0")
        case "\\": value.append("\\")
        case "\"": value.append("\"")
        case "'": value.append("'")
        case "$": value.append("\\$") // deferred to interpolation
        default:
          // Unknown escapes are preserved verbatim rather than
          // rejected, so Windows paths and regexes survive.
          value.append("\\")
          value.append(escaped)
        }
        continue
      }

      if character.isNewline {
        value.append("\n")
        consumeNewline()
        continue
      }

      value.append(character)
      advance()
    }

    throw EnvParseError(
      kind: .unterminatedQuote(.double),
      line: openLine,
      column: openColumn,
      path: path
    )
  }

  /// Reads an unquoted value up to end of line, stopping at a `#` that begins
  /// a trailing comment.
  ///
  /// A `#` only starts a comment when preceded by whitespace, so
  /// `COLOR=#ff0000` keeps its value.
  private mutating func readBareValue(startsAfterWhitespace: Bool) -> String {
    var value = ""
    var previousWasWhitespace = startsAfterWhitespace

    while let character = peek(), !character.isNewline {
      if character == "#", previousWasWhitespace { break }
      value.append(character)
      previousWasWhitespace = (character == " " || character == "\t")
      advance()
    }

    return value.trimmingASCIIWhitespace()
  }

  // MARK: - Comments

  /// Consumes `# ...` through end of line and returns the comment text.
  private mutating func readComment() -> String {
    advance() // '#'
    var comment = readToEndOfLine()
    if comment.first == " " { comment.removeFirst() }
    if peek() != nil { consumeNewline() }
    return comment
  }

  private mutating func readToEndOfLine() -> String {
    var text = ""
    while let character = peek(), !character.isNewline {
      text.append(character)
      advance()
    }
    return text
  }

  // MARK: - Cursor

  private var isAtEnd: Bool { index >= characters.count }

  /// 1-based column of the cursor within the current line.
  private var column: Int { index - lineStartIndex + 1 }

  private func peek() -> Character? {
    index < characters.count ? characters[index] : nil
  }

  private mutating func advance() { index += 1 }

  /// Consumes a line break, treating CRLF as one.
  private mutating func consumeNewline() {
    if peek() == "\r" {
      advance()
      if peek() == "\n" { advance() }
    } else {
      advance()
    }
    line += 1
    lineStartIndex = index
  }

  /// - Returns: Whether any whitespace was consumed.
  @discardableResult
  private mutating func skipInlineWhitespace() -> Bool {
    let start = index
    while let character = peek(), character == " " || character == "\t" {
      advance()
    }
    return index > start
  }

  private func error(_ kind: EnvParseError.Kind, column: Int) -> EnvParseError {
    EnvParseError(kind: kind, line: line, column: column, path: path)
  }
}

private extension EnvDirectives {
  /// Layers `other` on top of self, used to accumulate multiple directive
  /// comment lines above one assignment.
  mutating func merge(_ other: EnvDirectives) {
    if let type = other.type { self.type = type }
    if let swiftName = other.swiftName { self.swiftName = swiftName }
    if let defaultValue = other.defaultValue { self.defaultValue = defaultValue }
    isSecret = isSecret || other.isSecret
    isOptional = isOptional || other.isOptional
  }
}
