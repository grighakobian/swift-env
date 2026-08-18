import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Implements `@Env("KEY")`, turning a stored property into a read of the
/// enclosing type's environment reader.
///
/// The generated getter is non-throwing because `@EnvConfig`'s initializer has
/// already validated every key. The `catch` is therefore unreachable in a
/// correctly initialized value, and exists only so the getter has a total
/// definition.
public struct EnvMacro: AccessorMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard
      let info = EnvPropertyInfo.extract(attribute: node, from: declaration, in: context)
    else {
      return []
    }

    let literalKey = StringLiteralExprSyntax(content: info.key)

    if info.isOptional {
      // Absence is representable in the type, so nothing can fail.
      return [
        """
        get {
            _envReader.optional(\(literalKey), as: \(info.valueType).self)
        }
        """,
      ]
    }

    let read: ExprSyntax =
      if let defaultExpression = info.defaultExpression {
        "try _envReader.value(\(literalKey), default: \(defaultExpression))"
      } else {
        "try _envReader.require(\(literalKey), as: \(info.valueType).self)"
      }

    return [
      """
      get {
          do {
              return \(read)
          } catch {
              EnvKit.envConfigurationFailure(error, key: \(literalKey))
          }
      }
      """,
    ]
  }
}
