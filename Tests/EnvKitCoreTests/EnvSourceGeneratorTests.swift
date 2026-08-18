import Testing

@testable import EnvKitCore

@Suite("EnvSourceGenerator")
struct EnvSourceGeneratorTests {
  private func generate(
    example: String,
    env: String,
    options: EnvSourceGenerator.Options = .default,
    schema: EnvSchema? = .debug
  ) throws -> String {
    let files = [".env.example": example, ".env": env]
    let resolver = EnvResolver(environment: [:]) { path in
      files[EnvPath.lastComponent(of: path)]
    }
    let resolution = try resolver.resolve(
      EnvFileLayout(directory: "/project", schema: schema)
    )
    return try EnvSourceGenerator(options: options).generate(from: resolution, schema: schema)
  }

  @Test("emits a typed constant per declared key")
  func typedConstants() throws {
    let source = try generate(
      example: """
      API_URL=https://example.com
      PORT=8080
      RATE=0.25
      VERBOSE=false
      HOSTS=a.com,b.com
      PORTS=80,443
      NAME=app
      """,
      env: """
      API_URL=https://api.example.com
      PORT=3000
      RATE=0.5
      VERBOSE=yes
      HOSTS=x.com, y.com
      PORTS=8080, 8443
      NAME=service
      """
    )

    #expect(source.contains(#"static let apiURL: URL = URL(string: "https://api.example.com")!"#))
    #expect(source.contains("static let port: Int = 3000"))
    #expect(source.contains("static let rate: Double = 0.5"))
    #expect(source.contains("static let verbose: Bool = true"))
    #expect(source.contains(#"static let hosts: [String] = ["x.com", "y.com"]"#))
    #expect(source.contains("static let ports: [Int] = [8080, 8443]"))
    #expect(source.contains(#"static let name: String = "service""#))
  }

  @Test("carries documentation comments into the generated source")
  func documentation() throws {
    let source = try generate(
      example: """
      # The listening port.
      PORT=8080
      """,
      env: "PORT=3000"
    )
    #expect(source.contains("/// The listening port."))
    #expect(source.contains("/// Environment key: `PORT`"))
  }

  @Test("an optional key with no value becomes nil")
  func optionalKey() throws {
    let source = try generate(
      example: "# env: optional\nSENTRY_DSN=",
      env: "OTHER=1"
    )
    #expect(source.contains("static let sentryDSN: String? = nil"))
  }

  @Test("a missing required key fails generation")
  func missingRequiredKey() throws {
    #expect(throws: EnvSourceGenerator.GeneratorError.self) {
      try generate(example: "REQUIRED=x", env: "OTHER=1")
    }
  }

  @Test("generation requires a contract")
  func contractRequired() throws {
    let resolution = EnvResolution(values: ["A": "1"])
    #expect(throws: EnvSourceGenerator.GeneratorError.self) {
      try EnvSourceGenerator().generate(from: resolution, schema: nil)
    }
  }

  @Test("secret values are scrambled and warned about")
  func secretObfuscation() throws {
    let source = try generate(
      example: "# env: secret\nAPI_KEY=placeholder",
      env: "API_KEY=super-secret-value"
    )

    // The plaintext must not survive into the source.
    #expect(source.contains("super-secret-value") == false)
    #expect(source.contains("_deobfuscate("))
    #expect(source.contains("- Warning: Marked secret"))
  }

  @Test("obfuscation can be turned off")
  func plainSecrets() throws {
    var options = EnvSourceGenerator.Options.default
    options.obfuscatesSecrets = false

    let source = try generate(
      example: "# env: secret\nAPI_KEY=placeholder",
      env: "API_KEY=super-secret-value",
      options: options
    )
    #expect(source.contains(#""super-secret-value""#))
    #expect(source.contains("_deobfuscate(") == false)
  }

  @Test("obfuscation round-trips")
  func obfuscationRoundTrip() {
    let value = "a-secret-with-üñïçødé-and-symbols-!@#$%"
    let bytes = EnvSourceGenerator.obfuscate(value, salt: "API_KEY")

    let key = Array("API_KEY".utf8)
    let restored = String(
      decoding: bytes.enumerated().map { $1 ^ key[$0 % key.count] },
      as: UTF8.self
    )
    #expect(restored == value)
  }

  @Test("obfuscation is deterministic, so builds stay cacheable")
  func obfuscationIsDeterministic() {
    #expect(
      EnvSourceGenerator.obfuscate("value", salt: "KEY")
        == EnvSourceGenerator.obfuscate("value", salt: "KEY")
    )
  }

  @Test("keyword property names are escaped")
  func keywordEscaping() throws {
    let source = try generate(example: "CLASS=a", env: "CLASS=b")
    #expect(source.contains("static let `class`: String"))
  }

  @Test("string literals escape special characters")
  func literalEscaping() throws {
    let source = try generate(
      example: "MESSAGE=x",
      env: #"MESSAGE="line\nquote\"backslash\\tab\t""#
    )
    #expect(source.contains(#"= "line\nquote\"backslash\\tab\t""#))
  }

  @Test("respects the configured type name and access level")
  func typeNameAndAccess() throws {
    var options = EnvSourceGenerator.Options.default
    options.typeName = "AppConfig"
    options.accessLevel = "internal"

    let source = try generate(example: "A=1", env: "A=2", options: options)
    #expect(source.contains("internal enum AppConfig {"))
    #expect(source.contains("internal static let a: Int = 2"))
  }

  @Test("includes schema and key metadata")
  func metadata() throws {
    let source = try generate(example: "A=1\nB=2", env: "A=1\nB=2")
    #expect(source.contains(#"static let schema: String = "debug""#))
    #expect(source.contains(#""A", "B""#))
  }

  @Test("records which files contributed")
  func provenance() throws {
    let source = try generate(example: "A=1", env: "A=2")
    #expect(source.contains("/// - `.env`"))
    #expect(source.contains("/// Schema: `debug`"))
  }
}
