# swift-env

Type-safe `.env` configuration for Swift, with schema layering.

Two ways to consume the same `.env` files, because server-side and app targets
have genuinely different constraints:

| | Runtime (`EnvKit`) | Build time (`EnvCodegenPlugin`) |
| --- | --- | --- |
| For | servers, CLI tools, scripts | iOS/macOS apps |
| Values read | at launch, from disk | baked into a generated Swift file |
| Editing `.env` | takes effect next run | takes effect next build |
| Secrets | stay out of the binary | recoverable from the binary |
| API | `@EnvConfig` / `@Env` macros | generated `enum Env` |

Requires Swift 6.0. Deployment targets: macOS 10.15+, iOS 13+, tvOS 13+,
watchOS 6+ — the parser is written here rather than taken from
[apple/swift-configuration](https://github.com/apple/swift-configuration), whose
availability floor is macOS 15 / iOS 18.

## Installation

```swift
.package(url: "https://github.com/grighakobian/swift-env", from: "1.0.0")
```

```swift
// Server or CLI target:
.target(name: "MyServer", dependencies: [.product(name: "EnvKit", package: "swift-env")])

// App target:
.target(name: "MyApp", plugins: [.plugin(name: "EnvCodegenPlugin", package: "swift-env")])
```

## The file layout

Precedence runs from lowest to highest. A later source overrides an earlier one.

| Source | Committed | Purpose |
| --- | --- | --- |
| `.env.example` | yes | **contract only** — declares keys and types, never supplies values |
| `.env` | yes | shared defaults |
| `.env.local` | no | personal overrides, all schemas |
| `.env.<schema>` | yes | schema defaults, e.g. `.env.debug` |
| `.env.<schema>.local` | no | personal overrides, one schema |
| process environment | — | CI and deployment platforms |

`.env.example` is the piece that keeps this from drifting. It is not a stale copy
of `.env`; it is the contract:

- it declares which keys exist, so a typo is a **compile error**, not a runtime
  `nil`
- it declares each key's type, so `PORT=abc` **fails the build**
- a key it declares that nothing supplies **fails the build**
- its values are illustrations used for type inference, and are *never*
  substituted — so a placeholder like `API_KEY=your-key-here` cannot ship by
  accident

### Selecting a schema

`ENV_SCHEMA`, then `APP_ENV`, then `NODE_ENV`; otherwise `debug` for debug builds
and `release` for release builds.

```
ENV_SCHEMA=production swift run MyServer
```

For the build plugin, Xcode's `CONFIGURATION` setting is also consulted, so a
Debug scheme resolves `.env.debug` with no extra setup. `swift build -c release`
needs `ENV_SCHEMA` set explicitly, because SwiftPM does not export the
configuration to plugins.

## Runtime use

`.env.example`:

```
# Base URL of the upstream API.
API_URL=https://api.example.com

# Port to listen on.
# env: default=8080
PORT=8080

# Credential for the upstream API.
# env: secret
API_KEY=replace-me

# Absent in local development.
# env: optional
SENTRY_DSN=
```

```swift
import EnvKit

@EnvConfig
struct Configuration {
    @Env("API_URL") var apiURL: URL
    @Env("PORT", default: 8080) var port: Int
    @Env("API_KEY") var apiKey: String
    @Env("SENTRY_DSN") var sentryDSN: String?
}

let configuration = try Configuration(EnvReader.load(schema: .current))
print(configuration.port)   // Int, not String
```

The property's declared type drives decoding: `Int` parses an integer, `URL`
requires an absolute URL, `[String]` splits on commas, and an optional type makes
the key optional.

The generated initializer validates **every** key before returning, and reports
all failures at once rather than the first:

```
configuration is invalid:
  missing required configuration key 'API_KEY' (searched /app/.env, /app/.env.production)
  configuration key 'PORT' defined at /app/.env:4 is not a valid Int
```

That up-front validation is what lets the generated getters be non-throwing: by
the time you hold a `Configuration`, every key is known to be present and
decodable.

### Directives

Written in a comment directly above a key in `.env.example`:

| Directive | Effect |
| --- | --- |
| `# env: type=Int` | Overrides inference. Also `Double`, `Bool`, `String`, `URL`, `Data`, `[String]`, `[Int]` |
| `# env: optional` | Key may be absent; the generated property becomes optional |
| `# env: default=8080` | Value used when nothing supplies the key. Own comment line; takes the rest of the line, so it may contain commas |
| `# env: secret` | Redacted from diagnostics; warns when baked into a binary |
| `# env: name=legacyKey` | Overrides the generated Swift property name |

Types are otherwise inferred from the illustrative value. Quoting forces
`String`, which is the escape hatch when inference guesses wrong:
`ZIP="08080"` stays a string, `ZIP=08080` becomes an `Int`.

### Naming

`API_BASE_URL` becomes `apiBaseURL`, `SENTRY_DSN` becomes `sentryDSN`, `PORT`
becomes `port` — common initialisms are kept uppercase. Two keys that would
collide is an error, resolved with `# env: name=`.

## Build-time use

Attach the plugin and a `enum Env` appears, generated from the same files:

```swift
print(Env.apiURL)          // URL
print(Env.port)            // Int
print(Env.sentryDSN)       // String?
print(Env.schema)          // "debug"
```

No `import` is needed — it is generated into the target. Doc comments from
`.env.example` come along, so the values are self-documenting at the call site.

Configure via the build environment: `ENV_SCHEMA`, `ENV_TYPE_NAME`,
`ENV_LENIENT=1` (report resolution errors as warnings, useful for a first build in
a fresh checkout), `ENV_NO_OBFUSCATE=1`.

### Secrets in app targets, honestly

A value baked into an app binary is recoverable by anyone who can run it. Keys
marked `# env: secret` are XOR-scrambled so they do not show up in `strings`
output, and the build logs a warning naming them. **That is obfuscation, not
protection.** A credential that must stay secret belongs behind a server you
control, not in a shipped app.

The runtime path does not have this problem: `.env` is read from disk and nothing
is baked in.

## Why the macro does not read `.env`

The obvious design is a macro that reads `.env` during expansion and inlines the
values. It does not work, and the reason is worth stating because it is not
obvious:

**The build system does not know the macro read the file.** A macro expansion's
tracked inputs are the source file and the plugin binary. Edit `.env`, rebuild,
and no `.swift` file has changed — so no re-expansion happens and the previous
values are silently linked in. Newer toolchains cache expansions, which makes it
worse. There is no way to declare that dependency from inside a macro.

Two smaller problems: macro plugins run sandboxed, and a macro has no notion of
"project root" — it would have to take `context.location(of:)` and walk upward
hunting for `Package.swift`, which breaks under remote caching and differing
checkout layouts.

So the macros here expand to *runtime lookups* against a reader — which is safe,
cannot go stale, and keeps secrets out of the binary — and the build plugin covers
targets that cannot read a file at runtime. A build command declares its inputs
explicitly, which is the guarantee a macro cannot offer.

### Plugin limitation

Editing and creating `.env` files regenerate correctly. **Deleting** one that was
present on the previous build fails every subsequent build with

```
error: couldn't build ... because of missing inputs: .../.env.debug.local
```

until the plugin is re-evaluated. `touch Package.swift` or `swift package clean`
fixes it. A plugin cannot declare an input that does not exist, and the previous
build's command list is reused, so this cannot be fixed from inside the plugin.
The alternative — declaring only committed files — would trade this loud error for
silently stale values when someone edits their own `.env.local`.

## The parser

A character scanner rather than a line splitter, so quoted values may span lines:

```
PRIVATE_KEY="-----BEGIN KEY-----
abc123
-----END KEY-----"
```

Supported: `export ` prefixes, single/double/backtick quoting, escapes
(`\n`, `\t`, `\r`, `\\`, `\"`, `\'`) in double-quoted values, full-line and
trailing comments, repeated keys (last wins), and values containing `=`.

`COLOR=#ff0000` keeps its value — a `#` starts a comment only when preceded by
whitespace.

### Interpolation

```
HOST=localhost
BASE_URL=http://${HOST}:${PORT:-8080}
```

`$VAR`, `${VAR}`, `${VAR:-fallback}` (unset *or* empty), `${VAR-fallback}`
(unset only), and `\$` for a literal dollar sign. Expansion happens after files
are layered, so a high-precedence file can reference a value from a lower one.
Single-quoted values are never interpolated. Reference cycles terminate at a depth
limit instead of hanging the build.

## Diagnostics

Emitted as `path:line:column: severity: message`, which Xcode renders as
navigable errors and warnings.

Errors: a required key nothing supplies; a required key present but empty; a value
that does not decode as its declared type; a `.env` syntax error.

Warnings: a key in a `.env` file but absent from the contract (it will not appear
in generated code); a value still equal to the contract's placeholder — which
catches the "forgot to fill it in" case that otherwise reaches production.

Every value's origin is recorded, so you can ask where a value came from:

```swift
reader.resolution.origins["PORT"]   // /app/.env.debug:4
```

## CLI

```
swift run env-codegen --directory . --schema production --output Generated/Env.swift
swift run env-codegen --list-inputs
```

## Examples

`Examples/ServerExample` — runtime path, showing schema layering, interpolation,
and value provenance. `Examples/AppExample` — build plugin path, showing baked
values and secret obfuscation.

```
cd Examples/ServerExample && swift run
ENV_SCHEMA=production swift run
```

## Layout

```
Sources/
  EnvKitCore/          parser, interpolator, schema resolver, contract, codegen
  EnvKit/              runtime reader, @EnvConfig / @Env declarations
  EnvKitMacrosPlugin/  macro implementations
  env-codegen/         CLI front end for codegen
Plugins/
  EnvCodegenPlugin/    SwiftPM build tool plugin
```

`EnvKitCore` has no dependencies, so the parser and resolver are shared by the
runtime library and the build-time tool — a value that validates at build time
decodes identically at runtime.
