import EnvKit
import Foundation

/// The whole configuration surface of this service, in one place.
///
/// The macro expands each property into a read against the reader, and the
/// generated initializer validates every key before returning — so a
/// misconfigured deployment fails here, at launch, rather than on the first
/// request that happens to touch a bad value.
@EnvConfig
struct Configuration {
  /// Base URL of the upstream API.
  @Env("API_URL") var apiURL: URL

  /// Port to listen on.
  @Env("PORT", default: 8080) var port: Int

  /// Log verbosity.
  @Env("VERBOSE", default: false) var verbose: Bool

  /// Hosts permitted to call this service.
  @Env("ALLOWED_HOSTS") var allowedHosts: [String]

  /// Credential for the upstream API.
  @Env("API_KEY") var apiKey: String

  /// Error reporting endpoint, absent in local development.
  @Env("SENTRY_DSN") var sentryDSN: String?
}

// The reader resolves `.env` files from the project root, layered by schema.
// `EnvSchema.current` reads ENV_SCHEMA / APP_ENV, falling back to the build
// configuration.
let reader = try EnvReader.load(schema: .current)
let configuration = try Configuration(reader)

print("schema:        \(EnvSchema.current)")
print("loaded files:  \(reader.resolution.loadedFiles.map { ($0 as NSString).lastPathComponent })")
print("")
print("apiURL:        \(configuration.apiURL)")
print("port:          \(configuration.port)")
print("verbose:       \(configuration.verbose)")
print("allowedHosts:  \(configuration.allowedHosts)")
print("apiKey:        \(String(repeating: "*", count: configuration.apiKey.count))")
print("sentryDSN:     \(configuration.sentryDSN ?? "not configured")")
print("")
print("provenance:")
for key in Configuration.envRequirements.map(\.key) {
  let origin = reader.resolution.origins[key]?.description ?? "unset"
  let relative = origin.replacingOccurrences(
    of: reader.resolution.loadedFiles.first.map { ($0 as NSString).deletingLastPathComponent + "/" } ?? "",
    with: ""
  )
  print("  \(key.padding(toLength: 16, withPad: " ", startingAt: 0)) \(relative)")
}

// Warnings are advisory: an undeclared key, or a value still set to the
// contract's placeholder. `strict: true` only refuses to load on errors.
if !reader.resolution.warnings.isEmpty {
  print("")
  print("warnings:")
  for warning in reader.resolution.warnings {
    print("  \(warning.kind.message)")
  }
}
