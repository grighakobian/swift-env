import Foundation

/// Reads configuration values resolved from `.env` files.
///
/// Create one at startup and pass it where it is needed, or rely on
/// ``EnvReader/shared`` for the common case:
///
/// ```swift
/// let reader = try EnvReader.load(schema: .production)
/// let port = try reader.require("PORT", as: Int.self)
/// ```
///
/// Values are resolved once, at load, so reads are cheap and cannot change
/// underneath a running request.
public struct EnvReader: Sendable {
  public let resolution: EnvResolution
  public var decoder: EnvValueDecoder

  public init(resolution: EnvResolution, decoder: EnvValueDecoder = .default) {
    self.resolution = resolution
    self.decoder = decoder
  }

  /// A reader backed only by the given values. Useful in tests.
  public init(values: [String: String], decoder: EnvValueDecoder = .default) {
    self.init(
      resolution: EnvResolution(
        values: values,
        origins: values.mapValues { _ in .processEnvironment },
        quoting: [:],
        loadedFiles: [],
        missingFiles: [],
        contract: nil,
        diagnostics: []
      ),
      decoder: decoder
    )
  }

  // MARK: - Loading

  /// Resolves `.env` files and returns a reader.
  ///
  /// - Parameters:
  ///   - schema: Defaults to ``EnvSchema/current``, which reads `ENV_SCHEMA`
  ///     or `APP_ENV` and otherwise follows the build configuration.
  ///   - directory: Defaults to the nearest ancestor of the working directory
  ///     containing a `.env`, `.env.example`, `Package.swift`, or `.git`.
  ///   - strict: Fails when the resolution produced errors, such as a key
  ///     declared in `.env.example` that nothing supplies.
  public static func load(
    schema: EnvSchema? = .current,
    directory: String? = nil,
    includesLocalOverrides: Bool = true,
    strict: Bool = true,
    options: EnvResolver.Options = .default,
    decoder: EnvValueDecoder = .default
  ) throws -> EnvReader {
    let root = directory ?? EnvProjectRoot.discover() ?? FileManager.default.currentDirectoryPath
    let layout = EnvFileLayout(
      directory: root,
      schema: schema,
      includesLocalOverrides: includesLocalOverrides
    )
    let resolution = try EnvResolver(options: options).resolve(layout)

    if strict, !resolution.errors.isEmpty {
      throw EnvReaderError.resolutionFailed(resolution.errors)
    }
    return EnvReader(resolution: resolution, decoder: decoder)
  }

  /// A process-wide reader loaded on first use.
  ///
  /// Traps on failure rather than returning a degraded reader, because a
  /// misconfigured process should fail at startup instead of at the first
  /// request. Use ``load(schema:directory:includesLocalOverrides:strict:options:decoder:)``
  /// where you want to handle the error.
  public static let shared: EnvReader = {
    do {
      return try load()
    } catch {
      fatalError(
        """
        EnvReader.shared could not load configuration:
        \(error)
        """
      )
    }
  }()

  // MARK: - Reading

  /// Returns the raw string for `key`, before type conversion.
  public func raw(_ key: String) -> String? {
    resolution.values[key]
  }

  public func contains(_ key: String) -> Bool {
    resolution.values[key] != nil
  }

  /// Returns the value for `key`, or `nil` when it is absent or undecodable.
  public func optional<Value: EnvDecodable>(
    _ key: String,
    as _: Value.Type = Value.self
  ) -> Value? {
    guard let raw = resolution.values[key] else { return nil }
    return Value.decodeEnvValue(raw, using: decoder)
  }

  /// Returns the value for `key`, or `fallback` when it is absent.
  ///
  /// A present but undecodable value is a programming or configuration error
  /// rather than an absence, so it throws rather than falling back silently.
  public func value<Value: EnvDecodable>(
    _ key: String,
    default fallback: Value
  ) throws -> Value {
    guard let raw = resolution.values[key], !raw.isEmpty else { return fallback }
    guard let decoded = Value.decodeEnvValue(raw, using: decoder) else {
      throw EnvReaderError.typeMismatch(
        key: key,
        expected: Value.envValueType,
        origin: resolution.origins[key]
      )
    }
    return decoded
  }

  /// Returns the value for `key`, throwing when it is missing or undecodable.
  public func require<Value: EnvDecodable>(
    _ key: String,
    as _: Value.Type = Value.self
  ) throws -> Value {
    guard let raw = resolution.values[key], !raw.isEmpty else {
      throw EnvReaderError.missingKey(key, searchedFiles: resolution.loadedFiles)
    }
    guard let decoded = Value.decodeEnvValue(raw, using: decoder) else {
      throw EnvReaderError.typeMismatch(
        key: key,
        expected: Value.envValueType,
        origin: resolution.origins[key]
      )
    }
    return decoded
  }

  // MARK: - Validation

  /// Checks every requirement up front, so a generated configuration type can
  /// fail once at init rather than at each property access.
  public func validate(_ requirements: [EnvRequirement]) throws {
    var failures: [EnvReaderError] = []

    for requirement in requirements {
      let raw = resolution.values[requirement.key]

      switch raw {
      case nil, .some(""):
        if !requirement.isOptional, !requirement.hasDefault {
          failures.append(
            .missingKey(requirement.key, searchedFiles: resolution.loadedFiles)
          )
        }
      case let value?:
        if !decoder.validates(value, as: requirement.type) {
          failures.append(
            .typeMismatch(
              key: requirement.key,
              expected: requirement.type,
              origin: resolution.origins[requirement.key]
            )
          )
        }
      }
    }

    guard failures.isEmpty else { throw EnvReaderError.multiple(failures) }
  }
}

/// A key a configuration type depends on, emitted by the `@EnvConfig` macro.
public struct EnvRequirement: Sendable, Hashable {
  public var key: String
  public var type: EnvValueType
  public var isOptional: Bool
  public var hasDefault: Bool

  public init(key: String, type: EnvValueType, isOptional: Bool, hasDefault: Bool) {
    self.key = key
    self.type = type
    self.isOptional = isOptional
    self.hasDefault = hasDefault
  }
}

/// A type whose properties are backed by environment values.
///
/// Supplied by the `@EnvConfig` macro; you should not need to conform manually.
public protocol EnvConfiguration {
  /// Every key the type reads, used for up-front validation.
  static var envRequirements: [EnvRequirement] { get }

  init(_ reader: EnvReader) throws
}

public enum EnvReaderError: Error, CustomStringConvertible {
  case missingKey(String, searchedFiles: [String])
  case typeMismatch(key: String, expected: EnvValueType, origin: EnvOrigin?)
  case resolutionFailed([EnvDiagnostic])
  case multiple([EnvReaderError])

  public var description: String {
    switch self {
    case let .missingKey(key, files):
      let searched =
        files.isEmpty
          ? "no .env files were found"
          : "searched \(files.joined(separator: ", "))"
      return "missing required configuration key '\(key)' (\(searched))"

    case let .typeMismatch(key, expected, origin):
      let location = origin.map { " defined at \($0)" } ?? ""
      return "configuration key '\(key)'\(location) is not a valid \(expected.swiftTypeName)"

    case let .resolutionFailed(diagnostics):
      return
        "configuration is invalid:\n"
          + diagnostics.map { "  \($0.kind.message)" }.joined(separator: "\n")

    case let .multiple(errors):
      return
        "configuration is invalid:\n"
          + errors.map { "  \($0.description)" }.joined(separator: "\n")
    }
  }
}
