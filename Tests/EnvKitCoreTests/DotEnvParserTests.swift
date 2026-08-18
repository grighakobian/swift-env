import Testing

@testable import EnvKitCore

@Suite("DotEnvParser")
struct DotEnvParserTests {
  @Test("parses simple assignments")
  func simpleAssignments() throws {
    let document = try DotEnvParser.parse(
      """
      NAME=swift-env
      PORT=8080
      """
    )
    #expect(document.keys == ["NAME", "PORT"])
    #expect(document["NAME"] == "swift-env")
    #expect(document["PORT"] == "8080")
  }

  @Test("ignores blank lines and full-line comments")
  func commentsAndBlanks() throws {
    let document = try DotEnvParser.parse(
      """
      # a comment

      A=1

      # another
      B=2
      """
    )
    #expect(document.dictionary == ["A": "1", "B": "2"])
  }

  @Test("strips trailing comments only after whitespace")
  func trailingComments() throws {
    let document = try DotEnvParser.parse(
      """
      A=value # trailing
      COLOR=#ff0000
      FRAGMENT=http://host/path#anchor
      """
    )
    #expect(document["A"] == "value")
    #expect(document["COLOR"] == "#ff0000")
    #expect(document["FRAGMENT"] == "http://host/path#anchor")
  }

  @Test("accepts an export prefix")
  func exportPrefix() throws {
    let document = try DotEnvParser.parse(
      """
      export A=1
      exportB=2
      """
    )
    #expect(document["A"] == "1")
    #expect(document["exportB"] == "2")
  }

  @Test("single quotes are literal")
  func singleQuotes() throws {
    let document = try DotEnvParser.parse(#"A='raw ${NOT_EXPANDED} \n #hash'"#)
    #expect(document["A"] == #"raw ${NOT_EXPANDED} \n #hash"#)
    #expect(document.entries[0].quoting == .single)
  }

  @Test("double quotes resolve escapes and defer dollar escapes")
  func doubleQuotes() throws {
    let document = try DotEnvParser.parse(#"A="line1\nline2\ttab \"quoted\" \$literal C:\path""#)
    #expect(document["A"] == "line1\nline2\ttab \"quoted\" \\$literal C:\\path")
  }

  @Test("quoted values span newlines")
  func multilineValues() throws {
    let document = try DotEnvParser.parse(
      """
      KEY="-----BEGIN-----
      body
      -----END-----"
      AFTER=1
      """
    )
    #expect(document["KEY"] == "-----BEGIN-----\nbody\n-----END-----")
    #expect(document["AFTER"] == "1")
  }

  @Test("backslash-newline continues a double-quoted value")
  func lineContinuation() throws {
    let document = try DotEnvParser.parse(
      #"""
      A="one\
      two"
      """#
    )
    #expect(document["A"] == "onetwo")
  }

  @Test("later assignments win")
  func duplicateKeys() throws {
    let document = try DotEnvParser.parse("A=1\nA=2")
    #expect(document["A"] == "2")
    #expect(document.keys == ["A"])
  }

  @Test("values may contain equals signs")
  func equalsInValue() throws {
    let document = try DotEnvParser.parse("TOKEN=abc=def==")
    #expect(document["TOKEN"] == "abc=def==")
  }

  @Test("empty values are permitted")
  func emptyValue() throws {
    let document = try DotEnvParser.parse("A=\nB=2")
    #expect(document["A"] == "")
    #expect(document["B"] == "2")
  }

  @Test("captures leading comments and directives")
  func metadata() throws {
    let document = try DotEnvParser.parse(
      """
      # The upstream endpoint.
      # env: type=URL, secret
      API_URL=https://example.com
      """
    )
    let entry = document.entries[0]
    #expect(entry.leadingComments == ["The upstream endpoint."])
    #expect(entry.directives.type == .url)
    #expect(entry.directives.isSecret)
  }

  @Test("a blank line detaches a comment block")
  func detachedComments() throws {
    let document = try DotEnvParser.parse(
      """
      # unrelated note

      A=1
      """
    )
    #expect(document.entries[0].leadingComments.isEmpty)
  }

  @Test("reports unterminated quotes with a location")
  func unterminatedQuote() throws {
    let error = #expect(throws: EnvParseError.self) {
      try DotEnvParser.parse("A=1\nB=\"oops", path: ".env")
    }
    #expect(error?.kind == .unterminatedQuote(.double))
    #expect(error?.line == 2)
    #expect(error?.description.contains(".env:2:3: error:") == true)
  }

  @Test("rejects invalid keys")
  func invalidKey() throws {
    let error = #expect(throws: EnvParseError.self) {
      try DotEnvParser.parse("9BAD=1")
    }
    #expect(error?.kind == .invalidKey("9BAD"))
  }

  @Test("rejects a missing assignment operator")
  func missingAssignment() throws {
    let error = #expect(throws: EnvParseError.self) {
      try DotEnvParser.parse("JUST_A_KEY")
    }
    #expect(error?.kind == .expectedAssignment(key: "JUST_A_KEY"))
  }

  @Test("handles CRLF line endings")
  func crlf() throws {
    let document = try DotEnvParser.parse("A=1\r\nB=2\r\n")
    #expect(document.dictionary == ["A": "1", "B": "2"])
  }
}
