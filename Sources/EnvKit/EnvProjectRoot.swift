import Foundation

/// Locates the directory holding a project's `.env` files.
public enum EnvProjectRoot {
  /// Files that mark a directory as a project root, in priority order.
  ///
  /// `.env`-family markers come first so a nested package inside a monorepo
  /// picks up its own configuration before the repository's.
  public static let markers = [
    ".env.example", ".env", "Package.swift", "*.xcodeproj", ".git",
  ]

  /// Walks up from `start` looking for a project root.
  ///
  /// - Returns: The first ancestor containing a marker, or `nil` when none is
  ///   found before reaching the filesystem root. A `nil` result is normal for
  ///   an installed binary and means the caller should rely on the process
  ///   environment alone.
  public static func discover(
    startingAt start: String? = nil,
    fileManager: FileManager = .default
  ) -> String? {
    var directory = URL(fileURLWithPath: start ?? fileManager.currentDirectoryPath)
      .standardizedFileURL

    // Bounded rather than `while true`, so a symlink loop cannot hang a
    // process at startup.
    for _ in 0 ..< 64 {
      if containsMarker(in: directory, fileManager: fileManager) {
        return directory.path
      }
      let parent = directory.deletingLastPathComponent().standardizedFileURL
      if parent.path == directory.path { break }
      directory = parent
    }
    return nil
  }

  private static func containsMarker(in directory: URL, fileManager: FileManager) -> Bool {
    for marker in markers {
      if marker.hasPrefix("*") {
        let suffix = String(marker.dropFirst())
        let contents =
          (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        if contents.contains(where: { $0.hasSuffix(suffix) }) { return true }
      } else if fileManager.fileExists(
        atPath: directory.appendingPathComponent(marker).path
      ) {
        return true
      }
    }
    return false
  }
}

public extension EnvSchema {
  /// The schema for the running process.
  ///
  /// Resolution order:
  /// 1. `ENV_SCHEMA`, then `APP_ENV`, then `NODE_ENV` — so a deploy platform
  ///    can select a schema without a code change.
  /// 2. Otherwise `debug` for debug builds and `release` for release builds.
  static var current: EnvSchema {
    let environment = ProcessInfo.processInfo.environment
    for variable in ["ENV_SCHEMA", "APP_ENV", "NODE_ENV"] {
      if let name = environment[variable], !name.isEmpty {
        return EnvSchema(name)
      }
    }
    #if DEBUG
      return .debug
    #else
      return .release
    #endif
  }
}
