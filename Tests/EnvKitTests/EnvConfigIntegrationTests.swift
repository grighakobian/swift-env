import Foundation
import Testing

@testable import EnvKit

/// Exercises the macro as a client would: the type below is expanded by the real
/// compiler plugin, so these tests also prove the generated `EnvConfiguration`
/// conformance and initializer compile.
@EnvConfig
struct ServiceConfiguration {
    @Env("API_KEY") var apiKey: String
    @Env("PORT", default: 8080) var port: Int
    @Env("BASE_URL") var baseURL: URL
    @Env("SENTRY_DSN") var sentryDSN: String?
    @Env("ALLOWED_HOSTS") var allowedHosts: [String]
    @Env("VERBOSE", default: false) var verbose: Bool

    /// A derived property, to confirm unannotated members still work.
    var isProduction: Bool { !verbose }
}

@Suite("@EnvConfig integration")
struct EnvConfigIntegrationTests {
    private let complete: [String: String] = [
        "API_KEY": "secret-key",
        "BASE_URL": "https://api.example.com",
        "ALLOWED_HOSTS": "a.com, b.com",
    ]

    @Test("reads required, defaulted, and optional values")
    func readsValues() throws {
        let configuration = try ServiceConfiguration(EnvReader(values: complete))

        #expect(configuration.apiKey == "secret-key")
        #expect(configuration.port == 8080)
        #expect(configuration.baseURL == URL(string: "https://api.example.com"))
        #expect(configuration.sentryDSN == nil)
        #expect(configuration.allowedHosts == ["a.com", "b.com"])
        #expect(configuration.verbose == false)
        #expect(configuration.isProduction)
    }

    @Test("a supplied value overrides a default")
    func overridesDefault() throws {
        var values = complete
        values["PORT"] = "3000"
        values["VERBOSE"] = "yes"

        let configuration = try ServiceConfiguration(EnvReader(values: values))
        #expect(configuration.port == 3000)
        #expect(configuration.verbose)
    }

    @Test("an optional key is read when present")
    func readsOptional() throws {
        var values = complete
        values["SENTRY_DSN"] = "https://sentry.example.com/1"

        let configuration = try ServiceConfiguration(EnvReader(values: values))
        #expect(configuration.sentryDSN == "https://sentry.example.com/1")
    }

    @Test("initialization fails when a required key is missing")
    func failsOnMissingKey() throws {
        var values = complete
        values["API_KEY"] = nil

        #expect(throws: EnvReaderError.self) {
            try ServiceConfiguration(EnvReader(values: values))
        }
    }

    @Test("initialization fails when a value has the wrong type")
    func failsOnTypeMismatch() throws {
        var values = complete
        values["PORT"] = "not-a-port"

        let error = #expect(throws: EnvReaderError.self) {
            try ServiceConfiguration(EnvReader(values: values))
        }
        #expect(error?.description.contains("PORT") == true)
    }

    @Test("validation reports every failure at once, not just the first")
    func reportsAllFailures() throws {
        let error = #expect(throws: EnvReaderError.self) {
            try ServiceConfiguration(EnvReader(values: ["PORT": "bad"]))
        }
        let description = try #require(error?.description)
        #expect(description.contains("API_KEY"))
        #expect(description.contains("BASE_URL"))
        #expect(description.contains("PORT"))
    }

    @Test("an empty value counts as missing for a required key")
    func emptyIsMissing() throws {
        var values = complete
        values["API_KEY"] = ""

        #expect(throws: EnvReaderError.self) {
            try ServiceConfiguration(EnvReader(values: values))
        }
    }

    @Test("the macro publishes requirements in declaration order")
    func requirements() {
        let requirements = ServiceConfiguration.envRequirements
        #expect(requirements.map(\.key) == [
            "API_KEY", "PORT", "BASE_URL", "SENTRY_DSN", "ALLOWED_HOSTS", "VERBOSE",
        ])
        #expect(requirements[0].type == .string)
        #expect(requirements[2].type == .url)
        #expect(requirements[3].isOptional)
        #expect(requirements[4].type == .stringArray)
        #expect(requirements[5].hasDefault)
    }

    /// The generated extension must satisfy `EnvConfiguration`; this only
    /// compiles if the conformance macro fired.
    @Test("conforms to EnvConfiguration")
    func conformance() throws {
        func build<Configuration: EnvConfiguration>(
            _: Configuration.Type,
            reader: EnvReader
        ) throws -> Configuration {
            try Configuration(reader)
        }

        let configuration = try build(ServiceConfiguration.self, reader: EnvReader(values: complete))
        #expect(configuration.apiKey == "secret-key")
    }
}
