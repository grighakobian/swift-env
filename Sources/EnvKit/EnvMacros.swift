/// Wires a type's `@Env` properties to an ``EnvReader``.
///
/// Generates a private reader, an ``EnvConfiguration`` conformance, and a
/// throwing initializer that validates every declared key before returning:
///
/// ```swift
/// @EnvConfig
/// struct AppConfiguration {
///     @Env("API_KEY") var apiKey: String
///     @Env("PORT", default: 8080) var port: Int
///     @Env("BASE_URL") var baseURL: URL
///     @Env("SENTRY_DSN") var sentryDSN: String?
/// }
///
/// let configuration = try AppConfiguration()
/// ```
///
/// Validating in the initializer is what lets the generated property getters be
/// non-throwing: by the time you hold a value, every key is known to be present
/// and decodable.
///
/// The macro reads no files at build time. It expands to runtime lookups, so
/// editing a `.env` file takes effect on the next run without recompiling — and
/// no secret is baked into the binary. For targets that cannot read `.env` at
/// runtime, such as an app bundle, use the `EnvCodegenPlugin` build plugin
/// instead.
@attached(member, names: named(_envReader), named(envRequirements), named(init(_:)))
@attached(extension, conformances: EnvConfiguration)
public macro EnvConfig() =
  #externalMacro(module: "EnvKitMacrosPlugin", type: "EnvConfigMacro")

/// Reads `key` from the enclosing ``EnvConfig`` type's reader.
///
/// The property's declared type selects the decoding: `Int` parses an integer,
/// `URL` requires an absolute URL, `[String]` splits on commas. An optional type
/// makes the key optional.
///
/// - Parameter key: The environment variable name. Must be a string literal so
///   that it can be validated when the type is initialized.
@attached(accessor)
public macro Env(_ key: String) =
  #externalMacro(module: "EnvKitMacrosPlugin", type: "EnvMacro")

/// Reads `key`, falling back to `default` when it is absent or empty.
///
/// A key that is *present but undecodable* is treated as a configuration error
/// rather than an absence, so a typo in `.env` surfaces instead of silently
/// resolving to the fallback.
@attached(accessor)
public macro Env<Value>(_ key: String, default: Value) =
  #externalMacro(module: "EnvKitMacrosPlugin", type: "EnvMacro")

/// Reports an unreachable configuration failure from a generated getter.
///
/// `@EnvConfig`'s initializer validates every key, so reaching this means the
/// reader was mutated after initialization or a requirement was not covered.
/// Traps rather than returning a placeholder, because silently substituting a
/// wrong configuration value is worse than stopping.
public func envConfigurationFailure(_ error: any Error, key: String) -> Never {
  fatalError(
    """
    Configuration key '\(key)' could not be read after validation succeeded. \
    This indicates an EnvKit bug or a reader replaced post-initialization.
    Underlying error: \(error)
    """
  )
}
