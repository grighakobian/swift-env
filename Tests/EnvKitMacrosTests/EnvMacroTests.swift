import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import EnvKitMacrosPlugin

private let macros: [String: any Macro.Type] = [
    "EnvConfig": EnvConfigMacro.self,
    "Env": EnvMacro.self,
]

final class EnvMacroTests: XCTestCase {
    // MARK: - Expansion

    func testExpandsRequiredOptionalAndDefaultedProperties() {
        assertMacroExpansion(
            """
            @EnvConfig
            struct Config {
                @Env("API_KEY") var apiKey: String
                @Env("PORT", default: 8080) var port: Int
                @Env("SENTRY_DSN") var sentryDSN: String?
            }
            """,
            expandedSource: """
            struct Config {
                var apiKey: String {
                    get {
                        do {
                            return try _envReader.require("API_KEY", as: String.self)
                        } catch {
                            EnvKit.envConfigurationFailure(error, key: "API_KEY")
                        }
                    }
                }
                var port: Int {
                    get {
                        do {
                            return try _envReader.value("PORT", default: 8080)
                        } catch {
                            EnvKit.envConfigurationFailure(error, key: "PORT")
                        }
                    }
                }
                var sentryDSN: String? {
                    get {
                        _envReader.optional("SENTRY_DSN", as: String.self)
                    }
                }

                /// The reader backing this type's `@Env` properties.
                private let _envReader: EnvKit.EnvReader

                /// Every key this type reads, in declaration order.
                static var envRequirements: [EnvKit.EnvRequirement] {
                    [
                        .init(key: "API_KEY", type: String.envValueType, isOptional: false, hasDefault: false),
                        .init(key: "PORT", type: Int.envValueType, isOptional: false, hasDefault: true),
                        .init(key: "SENTRY_DSN", type: String.envValueType, isOptional: true, hasDefault: false)
                    ]
                }

                /// Validates every declared key up front, so a misconfigured
                /// process fails here rather than at the first property access.
                init(_ reader: EnvKit.EnvReader = .shared) throws {
                    self._envReader = reader
                    try reader.validate(Self.envRequirements)
                }
            }
            """,
            macros: macros
        )
    }

    /// A `public` type must get a `public` initializer, or it is unusable from
    /// another module.
    func testPropagatesAccessLevelToGeneratedMembers() {
        assertMacroExpansion(
            """
            @EnvConfig
            public struct Config {
                @Env("A") var a: String
            }
            """,
            expandedSource: """
            public struct Config {
                var a: String {
                    get {
                        do {
                            return try _envReader.require("A", as: String.self)
                        } catch {
                            EnvKit.envConfigurationFailure(error, key: "A")
                        }
                    }
                }

                /// The reader backing this type's `@Env` properties.
                private let _envReader: EnvKit.EnvReader

                /// Every key this type reads, in declaration order.
                public static var envRequirements: [EnvKit.EnvRequirement] {
                    [
                        .init(key: "A", type: String.envValueType, isOptional: false, hasDefault: false)
                    ]
                }

                /// Validates every declared key up front, so a misconfigured
                /// process fails here rather than at the first property access.
                public init(_ reader: EnvKit.EnvReader = .shared) throws {
                    self._envReader = reader
                    try reader.validate(Self.envRequirements)
                }
            }
            """,
            macros: macros
        )
    }

    /// `Optional<T>` spelled out longhand must behave like `T?`.
    func testTreatsLonghandOptionalAsOptional() {
        assertMacroExpansion(
            """
            @EnvConfig
            struct Config {
                @Env("A") var a: Optional<Int>
            }
            """,
            expandedSource: """
            struct Config {
                var a: Optional<Int> {
                    get {
                        _envReader.optional("A", as: Int.self)
                    }
                }

                /// The reader backing this type's `@Env` properties.
                private let _envReader: EnvKit.EnvReader

                /// Every key this type reads, in declaration order.
                static var envRequirements: [EnvKit.EnvRequirement] {
                    [
                        .init(key: "A", type: Int.envValueType, isOptional: true, hasDefault: false)
                    ]
                }

                /// Validates every declared key up front, so a misconfigured
                /// process fails here rather than at the first property access.
                init(_ reader: EnvKit.EnvReader = .shared) throws {
                    self._envReader = reader
                    try reader.validate(Self.envRequirements)
                }
            }
            """,
            macros: macros
        )
    }

    /// Properties without `@Env` are left untouched, so a config type can hold
    /// derived values.
    func testLeavesUnannotatedMembersAlone() {
        assertMacroExpansion(
            """
            @EnvConfig
            struct Config {
                @Env("A") var a: String
                var derived: String { a.uppercased() }
                let constant = 1
            }
            """,
            expandedSource: """
            struct Config {
                var a: String {
                    get {
                        do {
                            return try _envReader.require("A", as: String.self)
                        } catch {
                            EnvKit.envConfigurationFailure(error, key: "A")
                        }
                    }
                }
                var derived: String { a.uppercased() }
                let constant = 1

                /// The reader backing this type's `@Env` properties.
                private let _envReader: EnvKit.EnvReader

                /// Every key this type reads, in declaration order.
                static var envRequirements: [EnvKit.EnvRequirement] {
                    [
                        .init(key: "A", type: String.envValueType, isOptional: false, hasDefault: false)
                    ]
                }

                /// Validates every declared key up front, so a misconfigured
                /// process fails here rather than at the first property access.
                init(_ reader: EnvKit.EnvReader = .shared) throws {
                    self._envReader = reader
                    try reader.validate(Self.envRequirements)
                }
            }
            """,
            macros: macros
        )
    }

    // MARK: - Diagnostics

    func testRejectsEnvOnLet() {
        assertMacroExpansion(
            """
            @EnvConfig
            struct Config {
                @Env("A") let a: String
            }
            """,
            expandedSource: """
            struct Config {
                let a: String

                /// The reader backing this type's `@Env` properties.
                private let _envReader: EnvKit.EnvReader

                /// Every key this type reads, in declaration order.
                static var envRequirements: [EnvKit.EnvRequirement] {
                    []
                }

                /// Validates every declared key up front, so a misconfigured
                /// process fails here rather than at the first property access.
                init(_ reader: EnvKit.EnvReader = .shared) throws {
                    self._envReader = reader
                    try reader.validate(Self.envRequirements)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                    "'@Env' requires 'var' because the value is read through the environment reader",
                    line: 3,
                    column: 15
                ),
                DiagnosticSpec(
                    message: "'@EnvConfig' type declares no '@Env' properties",
                    line: 1,
                    column: 1,
                    severity: .warning
                ),
            ],
            macros: macros
        )
    }

    func testRejectsInitialValueAndSuggestsDefaultArgument() {
        assertMacroExpansion(
            """
            struct Config {
                @Env("PORT") var port: Int = 8080
            }
            """,
            expandedSource: """
            struct Config {
                var port: Int = 8080
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        '@Env' property cannot have an initial value; \
                        supply a fallback with '@Env("KEY", default:)' instead
                        """,
                    line: 2,
                    column: 32,
                    fixIts: [FixItSpec(message: "remove the initial value")]
                ),
            ],
            macros: macros
        )
    }

    func testRequiresTypeAnnotation() {
        assertMacroExpansion(
            """
            struct Config {
                @Env("A") var a
            }
            """,
            expandedSource: """
            struct Config {
                var a
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                    "'@Env' requires an explicit type annotation, which determines how the value is decoded",
                    line: 2,
                    column: 19
                ),
            ],
            macros: macros
        )
    }

    func testRequiresStringLiteralKey() {
        assertMacroExpansion(
            """
            let name = "A"
            struct Config {
                @Env(name) var a: String
            }
            """,
            expandedSource: """
            let name = "A"
            struct Config {
                var a: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                    "'@Env' requires a string literal key so it can be validated at build time",
                    line: 3,
                    column: 5
                ),
            ],
            macros: macros
        )
    }

    func testRejectsEnvConfigOnEnum() {
        assertMacroExpansion(
            """
            @EnvConfig
            enum Config {
                case a
            }
            """,
            expandedSource: """
            enum Config {
                case a
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'@EnvConfig' can only be applied to a struct, class, or actor",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }
}
