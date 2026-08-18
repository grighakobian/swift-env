import Testing

@testable import EnvKitCore

@Suite("EnvContract")
struct EnvContractTests {
    private func contract(_ source: String) throws -> EnvContract {
        try EnvContract.inferred(from: DotEnvParser.parse(source, path: ".env.example"))
    }

    @Test(
        "infers types from example values",
        arguments: [
            ("PORT=8080", EnvValueType.int),
            ("RATE=0.5", .double),
            ("DEBUG=true", .bool),
            ("VERBOSE=off", .bool),
            ("API_URL=https://example.com", .url),
            ("NAME=swift-env", .string),
            ("EMPTY=", .string),
            ("HOSTS=a.com,b.com", .stringArray),
            ("PORTS=80,443", .intArray),
        ]
    )
    func typeInference(source: String, expected: EnvValueType) throws {
        let contract = try contract(source)
        #expect(contract.declarations[0].type == expected)
    }

    @Test("quoting forces a string, as an escape hatch for inference")
    func quotingForcesString() throws {
        #expect(try contract(#"ZIP="08080""#).declarations[0].type == .string)
        #expect(try contract("ZIP=08080").declarations[0].type == .int)
    }

    @Test("a type directive overrides inference")
    func directiveOverridesInference() throws {
        let contract = try contract(
            """
            # env: type=URL
            ENDPOINT=fill-me-in
            """
        )
        #expect(contract.declarations[0].type == .url)
    }

    @Test("comments become documentation, directives do not")
    func documentation() throws {
        let contract = try contract(
            """
            # The listening port.
            # Defaults to 8080 in development.
            # env: type=Int
            PORT=8080
            """
        )
        #expect(
            contract.declarations[0].documentation == [
                "The listening port.", "Defaults to 8080 in development.",
            ]
        )
    }

    @Test("a repeated key refines the earlier declaration")
    func repeatedKey() throws {
        let contract = try contract("A=1\n# env: type=String\nA=2")
        #expect(contract.declarations.count == 1)
        #expect(contract.declarations[0].type == .string)
    }

    @Test("colliding property names are rejected with guidance")
    func nameCollision() throws {
        let error = #expect(throws: EnvContractError.self) {
            try contract("API_KEY=a\nAPI__KEY=b")
        }
        #expect(error?.description.contains("name=") == true)
    }

    @Test("a name directive resolves a collision")
    func nameDirectiveResolvesCollision() throws {
        let contract = try contract(
            """
            API_KEY=a
            # env: name=legacyAPIKey
            API__KEY=b
            """
        )
        #expect(contract.declarations.map(\.swiftName) == ["apiKey", "legacyAPIKey"])
    }

    @Test("requiredKeys excludes optional declarations")
    func requiredKeys() throws {
        let contract = try contract("A=1\n# env: optional\nB=2\nC=3")
        #expect(contract.requiredKeys == ["A", "C"])
    }
}

@Suite("EnvNaming")
struct EnvNamingTests {
    @Test(
        "converts environment names to idiomatic Swift properties",
        arguments: [
            ("PORT", "port"),
            ("API_KEY", "apiKey"),
            ("DATABASE_URL", "databaseURL"),
            ("API_BASE_URL", "apiBaseURL"),
            ("HTTP_TIMEOUT", "httpTimeout"),
            ("OAUTH_CLIENT_ID", "oauthClientID"),
            ("USE_TLS", "useTLS"),
            ("AWS_S3_BUCKET", "awsS3Bucket"),
            ("MAX_RETRIES", "maxRetries"),
            ("SENTRY_DSN", "sentryDSN"),
            ("SMTP_HOST", "smtpHost"),
            ("A", "a"),
            ("2FA_ENABLED", "_2faEnabled"),
        ]
    )
    func propertyNames(key: String, expected: String) {
        #expect(EnvNaming.swiftPropertyName(for: key) == expected)
    }

    @Test("keywords are escaped for use as members")
    func keywordEscaping() {
        #expect(EnvNaming.escaped("class") == "`class`")
        #expect(EnvNaming.escaped("port") == "port")
    }
}
