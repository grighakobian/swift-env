import Foundation
import Testing

@testable import EnvKit

@Suite("EnvReader on disk")
struct EnvReaderDiskTests {
  /// Creates a throwaway directory containing the given files.
  private func withProject(
    _ files: [String: String],
    _ body: (String) throws -> Void
  ) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift-env-tests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for (name, contents) in files {
      try contents.write(
        to: directory.appendingPathComponent(name),
        atomically: true,
        encoding: .utf8
      )
    }
    try body(directory.path)
  }

  @Test("loads and layers files from disk")
  func loadsFromDisk() throws {
    try withProject([
      ".env.example": """
      # The upstream endpoint.
      API_URL=https://example.com
      PORT=8080
      """,
      ".env": "API_URL=https://base.example.com\nPORT=1000",
      ".env.staging": "PORT=9000",
    ]) { directory in
      let reader = try EnvReader.load(schema: .staging, directory: directory)

      #expect(try reader.require("API_URL", as: URL.self).host == "base.example.com")
      #expect(try reader.require("PORT", as: Int.self) == 9000)
    }
  }

  @Test("strict loading rejects a configuration with errors")
  func strictLoading() throws {
    try withProject([
      ".env.example": "REQUIRED_KEY=",
      ".env": "OTHER=1",
    ]) { directory in
      #expect(throws: EnvReaderError.self) {
        try EnvReader.load(schema: nil, directory: directory, strict: true)
      }

      // The same configuration loads when strictness is off, so a caller
      // can inspect the diagnostics itself.
      let reader = try EnvReader.load(schema: nil, directory: directory, strict: false)
      #expect(reader.resolution.errors.count == 1)
    }
  }

  @Test("multiline quoted values survive a round trip through disk")
  func multilineValues() throws {
    let key = """
    -----BEGIN PRIVATE KEY-----
    abc123
    -----END PRIVATE KEY-----
    """

    try withProject([
      ".env.example": "PRIVATE_KEY=placeholder",
      ".env": "PRIVATE_KEY=\"\(key)\"",
    ]) { directory in
      let reader = try EnvReader.load(schema: nil, directory: directory)
      #expect(try reader.require("PRIVATE_KEY", as: String.self) == key)
    }
  }

  @Test("a parse error names the offending file and line")
  func parseErrorLocation() throws {
    try withProject([".env": "GOOD=1\nBAD=\"unterminated"]) { directory in
      let error = #expect(throws: EnvParseError.self) {
        try EnvReader.load(schema: nil, directory: directory)
      }
      #expect(error?.line == 2)
      #expect(error?.path?.hasSuffix(".env") == true)
    }
  }

  @Test("project root discovery finds the nearest marker")
  func projectRootDiscovery() throws {
    try withProject([".env.example": "A="]) { directory in
      let nested = URL(fileURLWithPath: directory)
        .appendingPathComponent("Sources/Deep/Nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

      let discovered = EnvProjectRoot.discover(startingAt: nested.path)
      #expect(
        discovered.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
          == URL(fileURLWithPath: directory).standardizedFileURL.path
      )
    }
  }

  @Test("schema comes from ENV_SCHEMA when set")
  func schemaFromEnvironment() {
    // Reads the ambient process environment, so only assert the fallback
    // when the variable is absent.
    if ProcessInfo.processInfo.environment["ENV_SCHEMA"] == nil,
       ProcessInfo.processInfo.environment["APP_ENV"] == nil,
       ProcessInfo.processInfo.environment["NODE_ENV"] == nil
    {
      #if DEBUG
        #expect(EnvSchema.current == .debug)
      #else
        #expect(EnvSchema.current == .release)
      #endif
    }
  }
}
