import Testing

@testable import EnvKitCore

@Suite("EnvInterpolator")
struct EnvInterpolatorTests {
    private func expand(
        _ value: String,
        _ table: [String: String] = [:],
        behavior: EnvInterpolator.UnresolvedReferenceBehavior = .substituteEmpty
    ) throws -> String {
        try EnvInterpolator(behavior: behavior).expand(value) { table[$0] }
    }

    @Test("expands braced and bare references")
    func basicExpansion() throws {
        #expect(try expand("http://${HOST}:${PORT}", ["HOST": "localhost", "PORT": "80"]) == "http://localhost:80")
        #expect(try expand("$HOST/path", ["HOST": "example.com"]) == "example.com/path")
    }

    @Test("colon-dash falls back for unset and empty values")
    func colonDashFallback() throws {
        #expect(try expand("${PORT:-8080}", [:]) == "8080")
        #expect(try expand("${PORT:-8080}", ["PORT": ""]) == "8080")
        #expect(try expand("${PORT:-8080}", ["PORT": "3000"]) == "3000")
    }

    @Test("plain dash falls back only for unset values")
    func dashFallback() throws {
        #expect(try expand("${PORT-8080}", [:]) == "8080")
        #expect(try expand("${PORT-8080}", ["PORT": ""]) == "")
    }

    @Test("fallbacks may themselves contain references")
    func nestedFallback() throws {
        #expect(try expand("${A:-${B}}", ["B": "from-b"]) == "from-b")
    }

    @Test("substituted values are expanded recursively")
    func recursiveExpansion() throws {
        #expect(try expand("${A}", ["A": "${B}", "B": "deep"]) == "deep")
    }

    @Test("a backslash escapes the dollar sign")
    func escapedDollar() throws {
        #expect(try expand(#"cost is \$5"#, [:]) == "cost is $5")
        #expect(try expand(#"\${NOT_A_REF}"#, ["NOT_A_REF": "x"]) == "${NOT_A_REF}")
    }

    @Test("a lone dollar sign is preserved")
    func loneDollar() throws {
        #expect(try expand("100$", [:]) == "100$")
        #expect(try expand("a $ b", [:]) == "a $ b")
    }

    @Test("unresolved references honor the configured behavior")
    func unresolvedBehavior() throws {
        #expect(try expand("[${MISSING}]", [:], behavior: .substituteEmpty) == "[]")
        #expect(try expand("[${MISSING}]", [:], behavior: .keepLiteral) == "[${MISSING}]")
        #expect(throws: EnvInterpolator.UnresolvedReferenceError.self) {
            try expand("${MISSING}", [:], behavior: .reportError)
        }
    }

    @Test("reference cycles terminate instead of hanging")
    func cycleTerminates() throws {
        let table = ["A": "${B}", "B": "${A}"]
        // The result is unimportant; not hanging is the point.
        _ = try EnvInterpolator(maximumDepth: 8).expand("${A}") { table[$0] }
    }

    @Test("values without a dollar sign pass through untouched")
    func passthrough() throws {
        #expect(try expand("plain value", [:]) == "plain value")
    }
}
