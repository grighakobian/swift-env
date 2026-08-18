import Testing

@testable import EnvKitCore

@Suite("EnvResolver")
struct EnvResolverTests {
    /// Builds a resolver backed by an in-memory file table, keyed by file name.
    private func resolver(
        files: [String: String],
        environment: [String: String] = [:],
        options: EnvResolver.Options = .default
    ) -> EnvResolver {
        EnvResolver(options: options, environment: environment) { path in
            files[EnvPath.lastComponent(of: path)]
        }
    }

    private func layout(
        schema: EnvSchema? = .debug,
        includesLocalOverrides: Bool = true
    ) -> EnvFileLayout {
        EnvFileLayout(
            directory: "/project",
            schema: schema,
            includesLocalOverrides: includesLocalOverrides
        )
    }

    // MARK: - Precedence

    @Test("layers files from .env up to .env.<schema>.local")
    func precedenceOrder() throws {
        let resolution = try resolver(
            files: [
                ".env": "A=base\nB=base\nC=base\nD=base",
                ".env.local": "B=local",
                ".env.debug": "C=debug",
                ".env.debug.local": "D=debug-local",
            ]
        ).resolve(layout())

        #expect(resolution.values["A"] == "base")
        #expect(resolution.values["B"] == "local")
        #expect(resolution.values["C"] == "debug")
        #expect(resolution.values["D"] == "debug-local")
    }

    @Test("the process environment outranks every file")
    func processEnvironmentWins() throws {
        let resolution = try resolver(
            files: [".env": "A=from-file"],
            environment: ["A": "from-environment"]
        ).resolve(layout())

        #expect(resolution.values["A"] == "from-environment")
        #expect(resolution.origins["A"] == .processEnvironment)
    }

    @Test("unrelated environment variables do not leak in")
    func environmentIsScoped() throws {
        let resolution = try resolver(
            files: [".env": "A=1"],
            environment: ["A": "2", "PATH": "/usr/bin", "HOME": "/Users/x"]
        ).resolve(layout())

        #expect(resolution.values.keys.sorted() == ["A"])
    }

    @Test("an environment variable can supply a declared key with no file value")
    func environmentSuppliesDeclaredKey() throws {
        let resolution = try resolver(
            files: [".env.example": "TOKEN="],
            environment: ["TOKEN": "abc"]
        ).resolve(layout())

        #expect(resolution.values["TOKEN"] == "abc")
        #expect(resolution.errors.isEmpty)
    }

    @Test("local overrides can be excluded, as for a test schema")
    func excludingLocalOverrides() throws {
        let resolution = try resolver(
            files: [".env": "A=base", ".env.local": "A=local"]
        ).resolve(layout(schema: .test, includesLocalOverrides: false))

        #expect(resolution.values["A"] == "base")
        #expect(resolution.loadedFiles.contains { $0.hasSuffix(".env.local") } == false)
    }

    @Test("absent files are recorded, not fatal")
    func missingFilesAreTolerated() throws {
        let resolution = try resolver(files: [".env": "A=1"]).resolve(layout())

        #expect(resolution.loadedFiles == ["/project/.env"])
        #expect(resolution.missingFiles.count == 3)
    }

    @Test("the example file never supplies values")
    func contractIsNotAValueSource() throws {
        let resolution = try resolver(
            files: [".env.example": "API_KEY=your-key-here"]
        ).resolve(layout())

        #expect(resolution.values["API_KEY"] == nil)
        #expect(resolution.contract?.declarations.count == 1)
    }

    // MARK: - Interpolation across layers

    @Test("a high-precedence file can reference a low-precedence value")
    func crossFileInterpolation() throws {
        let resolution = try resolver(
            files: [
                ".env": "HOST=localhost",
                ".env.debug": "BASE_URL=http://${HOST}:${PORT:-8080}",
            ]
        ).resolve(layout())

        #expect(resolution.values["BASE_URL"] == "http://localhost:8080")
    }

    @Test("single-quoted values are never interpolated")
    func literalValues() throws {
        let resolution = try resolver(
            files: [".env": "HOST=localhost\nRAW='${HOST}'"]
        ).resolve(layout())

        #expect(resolution.values["RAW"] == "${HOST}")
    }

    @Test("references may resolve against the process environment")
    func interpolationFromEnvironment() throws {
        let resolution = try resolver(
            files: [".env": "GREETING=hello ${WHO}"],
            environment: ["WHO": "world"]
        ).resolve(layout())

        #expect(resolution.values["GREETING"] == "hello world")
    }

    // MARK: - Contract validation

    @Test("a declared key with no value is an error")
    func missingRequiredKey() throws {
        let resolution = try resolver(
            files: [".env.example": "API_KEY=\nPORT=8080", ".env": "PORT=3000"]
        ).resolve(layout())

        #expect(resolution.errors.count == 1)
        #expect(resolution.errors[0].kind == .missingRequiredKey("API_KEY"))
    }

    @Test("an optional directive suppresses the missing-key error")
    func optionalKey() throws {
        let resolution = try resolver(
            files: [".env.example": "# env: optional\nSENTRY_DSN="]
        ).resolve(layout())

        #expect(resolution.errors.isEmpty)
        #expect(resolution.contract?["SENTRY_DSN"]?.isOptional == true)
    }

    @Test("an empty value for a required key is an error")
    func emptyRequiredValue() throws {
        let resolution = try resolver(
            files: [".env.example": "API_KEY=abc", ".env": "API_KEY="]
        ).resolve(layout())

        #expect(resolution.errors.contains { $0.kind == .emptyRequiredValue("API_KEY") })
    }

    @Test("a value that cannot decode as its declared type is an error")
    func typeMismatch() throws {
        let resolution = try resolver(
            files: [".env.example": "PORT=8080", ".env": "PORT=not-a-number"]
        ).resolve(layout())

        #expect(
            resolution.errors.contains {
                $0.kind == .typeMismatch(key: "PORT", expected: .int, value: "not-a-number")
            }
        )
    }

    @Test("a secret's value is withheld from diagnostics")
    func secretsAreRedacted() throws {
        let resolution = try resolver(
            files: [
                ".env.example": "# env: type=Int, secret\nSECRET_PORT=1",
                ".env": "SECRET_PORT=nope",
            ]
        ).resolve(layout())

        let message = resolution.errors.map(\.description).joined()
        #expect(message.contains("nope") == false)
        #expect(message.contains("SECRET_PORT"))
    }

    @Test("a value still equal to the placeholder is a warning")
    func placeholderWarning() throws {
        let resolution = try resolver(
            files: [".env.example": "API_KEY=your-key-here", ".env": "API_KEY=your-key-here"]
        ).resolve(layout())

        #expect(resolution.warnings.contains { $0.kind == .valueMatchesExample("API_KEY") })
        #expect(resolution.errors.isEmpty)
    }

    @Test("a key absent from the contract is a warning")
    func undeclaredKeyWarning() throws {
        let resolution = try resolver(
            files: [".env.example": "A=1", ".env": "A=1\nSTRAY=2"]
        ).resolve(layout())

        #expect(resolution.warnings.contains { $0.kind == .undeclaredKey("STRAY") })
    }

    @Test("a required contract file must exist")
    func requiredContract() throws {
        var options = EnvResolver.Options.default
        options.requiresContract = true

        #expect(throws: EnvResolver.ResolverError.self) {
            try resolver(files: [".env": "A=1"], options: options).resolve(layout())
        }
    }

    @Test("diagnostics point at the file that supplied the value")
    func diagnosticLocation() throws {
        let resolution = try resolver(
            files: [".env.example": "PORT=8080", ".env.debug": "A=1\nPORT=bad"]
        ).resolve(layout())

        let error = try #require(resolution.errors.first)
        #expect(error.path == "/project/.env.debug")
        #expect(error.line == 2)
    }

    @Test("origins record where each value came from")
    func origins() throws {
        let resolution = try resolver(
            files: [".env": "A=1", ".env.debug": "B=2"]
        ).resolve(layout())

        #expect(resolution.origins["A"] == .file(path: "/project/.env", line: 1))
        #expect(resolution.origins["B"] == .file(path: "/project/.env.debug", line: 1))
    }
}

@Suite("EnvResolver contract defaults")
struct EnvResolverDefaultTests {
    private func resolve(
        files: [String: String],
        environment: [String: String] = [:]
    ) throws -> EnvResolution {
        let resolver = EnvResolver(environment: environment) { path in
            files[EnvPath.lastComponent(of: path)]
        }
        return try resolver.resolve(EnvFileLayout(directory: "/project", schema: .debug))
    }

    @Test("a declared default supplies a key no file provides")
    func defaultSuppliesValue() throws {
        let resolution = try resolve(
            files: [".env.example": "# env: default=8080\nPORT=8080"]
        )

        #expect(resolution.values["PORT"] == "8080")
        #expect(resolution.errors.isEmpty)
        #expect(resolution.origins["PORT"] == .contractDefault(path: "/project/.env.example", line: 2))
    }

    @Test("a file value overrides a declared default")
    func fileOverridesDefault() throws {
        let resolution = try resolve(
            files: [
                ".env.example": "# env: default=8080\nPORT=8080",
                ".env.debug": "PORT=3000",
            ]
        )

        #expect(resolution.values["PORT"] == "3000")
        #expect(resolution.origins["PORT"] == .file(path: "/project/.env.debug", line: 1))
    }

    @Test("the process environment still outranks a declared default")
    func environmentOverridesDefault() throws {
        let resolution = try resolve(
            files: [".env.example": "# env: default=8080\nPORT=8080"],
            environment: ["PORT": "9999"]
        )
        #expect(resolution.values["PORT"] == "9999")
    }

    @Test("a key with a default is not reported as required")
    func defaultSatisfiesRequirement() throws {
        let contract = try EnvContract.inferred(
            from: DotEnvParser.parse("A=1\n# env: default=2\nB=2\nC=3")
        )
        #expect(contract.requiredKeys == ["A", "C"])
    }

    @Test("a default value may contain commas")
    func defaultWithCommas() throws {
        let resolution = try resolve(
            files: [".env.example": "# env: type=[String]\n# env: default=a.com,b.com\nHOSTS="]
        )
        #expect(resolution.values["HOSTS"] == "a.com,b.com")
        #expect(resolution.contract?["HOSTS"]?.type == .stringArray)
    }

    @Test("a default participates in interpolation")
    func defaultIsInterpolated() throws {
        let resolution = try resolve(
            files: [
                ".env.example": "# env: default=http://${HOST}:8080\nBASE_URL=",
                ".env": "HOST=localhost",
            ]
        )
        #expect(resolution.values["BASE_URL"] == "http://localhost:8080")
    }

    @Test("a type is inferred from the default when the illustration is blank")
    func inferenceFromDefault() throws {
        let contract = try EnvContract.inferred(
            from: DotEnvParser.parse("# env: default=8080\nPORT=")
        )
        #expect(contract.declarations[0].type == .int)
    }

    /// A default that equals the illustrative value is not a forgotten
    /// placeholder, so it must not warn.
    @Test("a value from a default never warns about placeholders")
    func defaultDoesNotWarnAsPlaceholder() throws {
        let resolution = try resolve(
            files: [".env.example": "# env: default=8080\nPORT=8080"]
        )
        #expect(resolution.warnings.isEmpty)
    }

    /// But a *file* that copies the placeholder verbatim still warns.
    @Test("a file value equal to the placeholder still warns")
    func fileCopyOfPlaceholderStillWarns() throws {
        let resolution = try resolve(
            files: [
                ".env.example": "API_KEY=replace-me",
                ".env": "API_KEY=replace-me",
            ]
        )
        #expect(resolution.warnings.contains { $0.kind == .valueMatchesExample("API_KEY") })
    }
}
