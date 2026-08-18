import Foundation

/// Where a resolved value came from, for diagnostics and for `--explain` style
/// output.
public enum EnvOrigin: Sendable, Hashable, CustomStringConvertible {
  case file(path: String, line: Int)
  case processEnvironment
  /// Supplied by a `# env: default=...` directive in the contract.
  case contractDefault(path: String, line: Int)

  public var description: String {
    switch self {
    case let .file(path, line): "\(path):\(line)"
    case .processEnvironment: "process environment"
    case let .contractDefault(path, line): "\(path):\(line) (default)"
    }
  }
}

/// A non-fatal problem found while resolving.
public struct EnvDiagnostic: Sendable, Hashable, CustomStringConvertible {
  public enum Severity: String, Sendable, Hashable {
    case warning
    case error
  }

  public enum Kind: Sendable, Hashable {
    /// Declared in `.env.example` but no file or environment variable
    /// supplies it.
    case missingRequiredKey(String)
    /// Declared and present, but empty.
    case emptyRequiredValue(String)
    /// Supplied by a file but absent from `.env.example`, so it is invisible
    /// to the generated API.
    case undeclaredKey(String)
    /// Still set to the placeholder from `.env.example`, which usually means
    /// someone forgot to fill it in.
    case valueMatchesExample(String)
    /// Present but not decodable as the declared type.
    case typeMismatch(key: String, expected: EnvValueType, value: String?)

    /// Human-readable description, without location.
    public var message: String {
      switch self {
      case let .missingRequiredKey(key):
        "missing required key '\(key)' declared in the contract"
      case let .emptyRequiredValue(key):
        "required key '\(key)' is present but empty"
      case let .undeclaredKey(key):
        "key '\(key)' is not declared in the contract and will not appear in generated code"
      case let .valueMatchesExample(key):
        "key '\(key)' still holds the placeholder value from the contract"
      case let .typeMismatch(key, expected, value):
        if let value {
          "value '\(value)' for key '\(key)' is not a valid \(expected.swiftTypeName)"
        } else {
          "value for key '\(key)' is not a valid \(expected.swiftTypeName)"
        }
      }
    }
  }

  public var severity: Severity
  public var kind: Kind
  public var path: String?
  public var line: Int

  public init(severity: Severity, kind: Kind, path: String? = nil, line: Int = 1) {
    self.severity = severity
    self.kind = kind
    self.path = path
    self.line = line
  }

  /// Xcode-compatible `path:line:column: severity: message`.
  public var description: String {
    "\(path ?? "<env>"):\(line):1: \(severity.rawValue): \(kind.message)"
  }
}

/// The outcome of layering a set of `.env` files.
public struct EnvResolution: Sendable {
  /// Fully interpolated values, keyed by environment variable name.
  public var values: [String: String]

  /// Where each value came from.
  public var origins: [String: EnvOrigin]

  /// Quoting of the winning assignment, retained so callers can tell a
  /// deliberately literal value from an interpolated one.
  public var quoting: [String: EnvQuoting]

  /// Files that existed and were parsed, in ascending precedence.
  public var loadedFiles: [String]

  /// Files from the layout that were absent. Not an error: a project need not
  /// define every layer.
  public var missingFiles: [String]

  public var contract: EnvContract?
  public var diagnostics: [EnvDiagnostic]

  public init(
    values: [String: String] = [:],
    origins: [String: EnvOrigin] = [:],
    quoting: [String: EnvQuoting] = [:],
    loadedFiles: [String] = [],
    missingFiles: [String] = [],
    contract: EnvContract? = nil,
    diagnostics: [EnvDiagnostic] = []
  ) {
    self.values = values
    self.origins = origins
    self.quoting = quoting
    self.loadedFiles = loadedFiles
    self.missingFiles = missingFiles
    self.contract = contract
    self.diagnostics = diagnostics
  }

  public var errors: [EnvDiagnostic] {
    diagnostics.filter { $0.severity == .error }
  }

  public var warnings: [EnvDiagnostic] {
    diagnostics.filter { $0.severity == .warning }
  }

  public subscript(key: String) -> String? { values[key] }

  /// Values for keys the contract declares, in declaration order. Used by
  /// codegen so generated output is stable rather than dictionary-ordered.
  public func declaredValues() -> [(declaration: EnvKeyDeclaration, value: String?)] {
    guard let contract else { return [] }
    return contract.declarations.map { ($0, values[$0.key]) }
  }
}

/// Loads and layers `.env` files according to an ``EnvFileLayout``.
public struct EnvResolver: Sendable {
  public struct Options: Sendable {
    /// Lets process environment variables override file values, so CI and
    /// deployment platforms win without editing files.
    ///
    /// Only keys already known from a file or the contract are consulted, so
    /// unrelated variables like `PATH` never leak into the resolution.
    public var processEnvironmentOverrides: Bool

    /// Fails when `.env.example` is absent, rather than resolving without a
    /// contract.
    public var requiresContract: Bool

    /// Emits ``EnvDiagnostic/Kind/undeclaredKey(_:)`` warnings.
    public var warnsOnUndeclaredKeys: Bool

    /// Emits ``EnvDiagnostic/Kind/valueMatchesExample(_:)`` warnings.
    public var warnsOnPlaceholderValues: Bool

    /// Treats an empty value for a required key as missing.
    public var treatsEmptyAsMissing: Bool

    public var parser: DotEnvParser.Options
    public var interpolator: EnvInterpolator
    public var decoder: EnvValueDecoder

    public init(
      processEnvironmentOverrides: Bool = true,
      requiresContract: Bool = false,
      warnsOnUndeclaredKeys: Bool = true,
      warnsOnPlaceholderValues: Bool = true,
      treatsEmptyAsMissing: Bool = true,
      parser: DotEnvParser.Options = .default,
      interpolator: EnvInterpolator = EnvInterpolator(),
      decoder: EnvValueDecoder = .default
    ) {
      self.processEnvironmentOverrides = processEnvironmentOverrides
      self.requiresContract = requiresContract
      self.warnsOnUndeclaredKeys = warnsOnUndeclaredKeys
      self.warnsOnPlaceholderValues = warnsOnPlaceholderValues
      self.treatsEmptyAsMissing = treatsEmptyAsMissing
      self.parser = parser
      self.interpolator = interpolator
      self.decoder = decoder
    }

    public static var `default`: Options { Options() }
  }

  public enum ResolverError: Error, Sendable, CustomStringConvertible {
    case contractNotFound(path: String)

    public var description: String {
      switch self {
      case let .contractNotFound(path):
        "error: required contract file not found at \(path)"
      }
    }
  }

  public var options: Options
  private let loadContents: @Sendable (String) throws -> String?
  private let environment: [String: String]

  /// - Parameters:
  ///   - loadContents: Reads a file, returning `nil` when it does not exist.
  ///     Injected so resolution can be tested without touching disk.
  ///   - environment: The process environment to consult for overrides.
  public init(
    options: Options = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    loadContents: (@Sendable (String) throws -> String?)? = nil
  ) {
    self.options = options
    self.environment = environment
    self.loadContents =
      loadContents
        ?? { path in
          guard FileManager.default.fileExists(atPath: path) else { return nil }
          return try String(contentsOfFile: path, encoding: .utf8)
        }
  }

  /// Layers the files described by `layout` and validates the result against
  /// `.env.example`.
  public func resolve(_ layout: EnvFileLayout) throws -> EnvResolution {
    let contract = try loadContract(at: layout.contractPath)

    var raw: [String: String] = [:]
    var quoting: [String: EnvQuoting] = [:]
    var origins: [String: EnvOrigin] = [:]
    var loadedFiles: [String] = []
    var missingFiles: [String] = []
    var fileKeyOrder: [String] = []

    // Contract defaults sit below every file, so any file value overrides
    // them naturally.
    if let contract {
      for declaration in contract.declarations {
        guard let defaultValue = declaration.defaultValue else { continue }
        raw[declaration.key] = defaultValue
        quoting[declaration.key] = EnvQuoting.none
        origins[declaration.key] = .contractDefault(
          path: contract.path ?? layout.contractPath,
          line: declaration.line
        )
      }
    }

    // Ascending precedence: a later file overwrites an earlier one.
    for path in layout.filePaths {
      guard let contents = try loadContents(path) else {
        missingFiles.append(path)
        continue
      }
      loadedFiles.append(path)

      let document = try DotEnvParser.parse(contents, path: path, options: options.parser)
      for entry in document.entries {
        if raw[entry.key] == nil { fileKeyOrder.append(entry.key) }
        raw[entry.key] = entry.value
        quoting[entry.key] = entry.quoting
        origins[entry.key] = .file(path: path, line: entry.line)
      }
    }

    if options.processEnvironmentOverrides {
      // Restrict to known keys so the resolution stays scoped to this
      // project's configuration surface.
      let knownKeys = Set(raw.keys).union(contract?.declarations.map(\.key) ?? [])
      for key in knownKeys {
        guard let value = environment[key] else { continue }
        raw[key] = value
        quoting[key] = EnvQuoting.none
        origins[key] = .processEnvironment
      }
    }

    let values = try expand(raw, quoting: quoting)

    let diagnostics = diagnose(
      values: values,
      origins: origins,
      fileKeyOrder: fileKeyOrder,
      contract: contract
    )

    return EnvResolution(
      values: values,
      origins: origins,
      quoting: quoting,
      loadedFiles: loadedFiles,
      missingFiles: missingFiles,
      contract: contract,
      diagnostics: diagnostics
    )
  }

  // MARK: - Stages

  private func loadContract(at path: String) throws -> EnvContract? {
    guard let contents = try loadContents(path) else {
      if options.requiresContract {
        throw ResolverError.contractNotFound(path: path)
      }
      return nil
    }
    let document = try DotEnvParser.parse(contents, path: path, options: options.parser)
    return try EnvContract.inferred(from: document)
  }

  /// Expands `${...}` references once all files are layered, so a reference in
  /// a high-precedence file can resolve against a lower one.
  private func expand(
    _ raw: [String: String],
    quoting: [String: EnvQuoting]
  ) throws -> [String: String] {
    var expanded: [String: String] = [:]
    expanded.reserveCapacity(raw.count)

    for (key, value) in raw {
      guard quoting[key, default: .none].allowsInterpolation else {
        // Single-quoted values are literal, including any `$`.
        expanded[key] = value
        continue
      }
      expanded[key] = try options.interpolator.expand(value, key: key) { name in
        raw[name] ?? environment[name]
      }
    }
    return expanded
  }

  private func diagnose(
    values: [String: String],
    origins: [String: EnvOrigin],
    fileKeyOrder: [String],
    contract: EnvContract?
  ) -> [EnvDiagnostic] {
    guard let contract else { return [] }
    var diagnostics: [EnvDiagnostic] = []

    for declaration in contract.declarations {
      let value = values[declaration.key]

      switch value {
      case nil:
        if !declaration.isOptional, declaration.defaultValue == nil {
          diagnostics.append(
            EnvDiagnostic(
              severity: .error,
              kind: .missingRequiredKey(declaration.key),
              path: contract.path,
              line: declaration.line
            )
          )
        }
        continue

      case let value? where value.isEmpty:
        if !declaration.isOptional, declaration.defaultValue == nil,
           options.treatsEmptyAsMissing
        {
          diagnostics.append(
            EnvDiagnostic(
              severity: .error,
              kind: .emptyRequiredValue(declaration.key),
              path: origins[declaration.key].flatMap(\.path) ?? contract.path,
              line: origins[declaration.key]?.line ?? declaration.line
            )
          )
        }
        continue

      case let value?:
        // A value that came from the contract's own `default=` is not a
        // forgotten placeholder, even when it matches the illustration.
        let isContractDefault = if case .contractDefault = origins[declaration.key] {
          true
        } else {
          false
        }

        if options.warnsOnPlaceholderValues,
           !isContractDefault,
           !declaration.exampleValue.isEmpty,
           value == declaration.exampleValue
        {
          diagnostics.append(
            EnvDiagnostic(
              severity: .warning,
              kind: .valueMatchesExample(declaration.key),
              path: origins[declaration.key].flatMap(\.path) ?? contract.path,
              line: origins[declaration.key]?.line ?? declaration.line
            )
          )
        }

        if !options.decoder.validates(value, as: declaration.type) {
          diagnostics.append(
            EnvDiagnostic(
              severity: .error,
              kind: .typeMismatch(
                key: declaration.key,
                expected: declaration.type,
                value: declaration.isSecret ? nil : value
              ),
              path: origins[declaration.key].flatMap(\.path) ?? contract.path,
              line: origins[declaration.key]?.line ?? declaration.line
            )
          )
        }
      }
    }

    if options.warnsOnUndeclaredKeys {
      let declared = Set(contract.declarations.map(\.key))
      for key in fileKeyOrder where !declared.contains(key) {
        diagnostics.append(
          EnvDiagnostic(
            severity: .warning,
            kind: .undeclaredKey(key),
            path: origins[key].flatMap(\.path),
            line: origins[key]?.line ?? 1
          )
        )
      }
    }

    return diagnostics
  }
}

extension EnvOrigin {
  var path: String? {
    switch self {
    case let .file(path, _), let .contractDefault(path, _): path
    case .processEnvironment: nil
    }
  }

  var line: Int {
    switch self {
    case let .file(_, line), let .contractDefault(_, line): line
    case .processEnvironment: 1
    }
  }
}
