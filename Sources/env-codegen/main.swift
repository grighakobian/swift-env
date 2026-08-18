import EnvKitCore
import Foundation

/// Command-line front end for ``EnvSourceGenerator``.
///
/// Invoked by the `EnvCodegenPlugin` build plugin, and usable directly:
///
/// ```
/// swift run env-codegen --directory . --schema debug --output Generated/Env.swift
/// ```
///
/// Diagnostics are written to stderr in `path:line:column: severity: message`
/// form, which Xcode surfaces as navigable errors and warnings.
struct Arguments {
  var directory = FileManager.default.currentDirectoryPath
  var output: String?
  var schema: EnvSchema?
  var typeName = "Env"
  var accessLevel = "public"
  var includesLocalOverrides = true
  var obfuscatesSecrets = true
  /// Downgrades resolution errors to warnings. Useful for a first build in a
  /// fresh checkout where `.env` has not been filled in yet.
  var lenient = false
  var listInputs = false

  static let usage = """
  usage: env-codegen [options]

    --directory <path>   Directory holding the .env files (default: cwd)
    --output <path>      Swift file to write (default: stdout)
    --schema <name>      Schema to resolve, e.g. debug, staging, production
    --type-name <name>   Name of the generated enum (default: Env)
    --access <level>     Access level of generated members (default: public)
    --no-local           Ignore .env*.local files
    --no-obfuscate       Emit secret values as plain string literals
    --lenient            Report resolution errors as warnings
    --list-inputs        Print the candidate file paths and exit
    --help
  """

  static func parse(_ arguments: [String]) throws -> Arguments {
    var parsed = Arguments()
    var index = 0

    func next(_ flag: String) throws -> String {
      index += 1
      guard index < arguments.count else {
        throw ToolError.missingValue(flag: flag)
      }
      return arguments[index]
    }

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--directory": parsed.directory = try next(argument)
      case "--output": parsed.output = try next(argument)
      case "--schema": parsed.schema = try EnvSchema(next(argument))
      case "--type-name": parsed.typeName = try next(argument)
      case "--access": parsed.accessLevel = try next(argument)
      case "--no-local": parsed.includesLocalOverrides = false
      case "--no-obfuscate": parsed.obfuscatesSecrets = false
      case "--lenient": parsed.lenient = true
      case "--list-inputs": parsed.listInputs = true
      case "--help", "-h": throw ToolError.helpRequested
      default: throw ToolError.unknownArgument(argument)
      }
      index += 1
    }
    return parsed
  }
}

enum ToolError: Error, CustomStringConvertible {
  case missingValue(flag: String)
  case unknownArgument(String)
  case helpRequested
  case resolutionFailed(count: Int)

  var description: String {
    switch self {
    case let .missingValue(flag): "error: '\(flag)' requires a value"
    case let .unknownArgument(argument): "error: unknown argument '\(argument)'"
    case .helpRequested: Arguments.usage
    case let .resolutionFailed(count):
      "error: configuration is invalid (\(count) \(count == 1 ? "error" : "errors"))"
    }
  }
}

func emit(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func run() throws {
  let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))

  let layout = EnvFileLayout(
    directory: arguments.directory,
    schema: arguments.schema,
    includesLocalOverrides: arguments.includesLocalOverrides
  )

  // The plugin uses this to declare build inputs, so that editing any
  // candidate file triggers regeneration.
  if arguments.listInputs {
    for path in [layout.contractPath] + layout.filePaths {
      print(path)
    }
    return
  }

  var options = EnvResolver.Options.default
  options.requiresContract = true

  let resolution = try EnvResolver(options: options).resolve(layout)

  for diagnostic in resolution.diagnostics {
    if arguments.lenient, diagnostic.severity == .error {
      var downgraded = diagnostic
      downgraded.severity = .warning
      emit(downgraded.description)
    } else {
      emit(diagnostic.description)
    }
  }

  if !arguments.lenient, !resolution.errors.isEmpty {
    throw ToolError.resolutionFailed(count: resolution.errors.count)
  }

  // Values marked secret end up recoverable from the binary; say so once per
  // build rather than silently shipping them.
  let secrets = resolution.contract?.declarations.filter(\.isSecret).map(\.key) ?? []
  if !secrets.isEmpty {
    emit(
      "\(layout.contractPath):1:1: warning: baking secret \(secrets.count == 1 ? "key" : "keys") "
        + "\(secrets.joined(separator: ", ")) into generated source; "
        + "values are recoverable from the built binary"
    )
  }

  let generator = EnvSourceGenerator(
    options: .init(
      typeName: arguments.typeName,
      accessLevel: arguments.accessLevel,
      obfuscatesSecrets: arguments.obfuscatesSecrets
    )
  )

  var source: String
  do {
    source = try generator.generate(from: resolution, schema: arguments.schema)
  } catch let error as EnvSourceGenerator.GeneratorError {
    guard arguments.lenient else { throw error }
    emit("\(layout.contractPath):1:1: warning: \(error)")
    source = "// env-codegen: generation skipped (--lenient)\n"
  }

  guard let output = arguments.output else {
    print(source, terminator: "")
    return
  }

  // Skip the write when nothing changed, so downstream compilation is not
  // invalidated on every build.
  let url = URL(fileURLWithPath: output)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  if let existing = try? String(contentsOf: url, encoding: .utf8), existing == source {
    return
  }
  try source.write(to: url, atomically: true, encoding: .utf8)
}

do {
  try run()
} catch ToolError.helpRequested {
  print(Arguments.usage)
} catch {
  emit("\(error)")
  exit(1)
}
