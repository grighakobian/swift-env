import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A single `@Env`-annotated property, extracted from syntax.
///
/// Shared by ``EnvMacro``, which generates the accessor, and ``EnvConfigMacro``,
/// which collects requirements for up-front validation.
struct EnvPropertyInfo {
  /// The environment variable name, from the macro's first argument.
  var key: String

  /// The declared type with any outer `Optional` stripped, so that
  /// `String?` yields `String`. Used to look up `envValueType`.
  var valueType: TypeSyntax

  /// Whether the declared type was optional, meaning absence is permitted.
  var isOptional: Bool

  /// The `default:` argument's expression, when present.
  var defaultExpression: ExprSyntax?

  var hasDefault: Bool { defaultExpression != nil }
}

extension EnvPropertyInfo {
  /// Extracts the information `@Env` needs, or emits diagnostics and returns
  /// `nil`.
  ///
  /// - Parameter emitDiagnostics: Suppressed when called from `@EnvConfig`,
  ///   so that a malformed property is reported once by `@Env` rather than
  ///   twice.
  static func extract(
    attribute: AttributeSyntax,
    from declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext,
    emitDiagnostics: Bool = true
  ) -> EnvPropertyInfo? {
    func diagnose(_ message: EnvMacroDiagnostic, at node: some SyntaxProtocol) {
      guard emitDiagnostics else { return }
      context.diagnose(Diagnostic(node: Syntax(node), message: message))
    }

    guard let variable = declaration.as(VariableDeclSyntax.self) else {
      diagnose(.envRequiresVariable, at: declaration)
      return nil
    }
    guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
      diagnose(.envRequiresVar, at: variable.bindingSpecifier)
      return nil
    }
    guard variable.bindings.count == 1, let binding = variable.bindings.first else {
      diagnose(.envRequiresSingleBinding, at: variable)
      return nil
    }
    if let initializer = binding.initializer {
      if emitDiagnostics {
        context.diagnose(
          Diagnostic(
            node: Syntax(initializer),
            message: EnvMacroDiagnostic.envRejectsInitializer,
            fixIts: [
              FixIt(
                message: EnvMacroFixIt.removeInitializer,
                changes: [.replace(oldNode: Syntax(initializer), newNode: Syntax("" as ExprSyntax))]
              ),
            ]
          )
        )
      }
      return nil
    }
    if binding.accessorBlock != nil {
      diagnose(.envRejectsComputedProperty, at: binding)
      return nil
    }
    guard let annotation = binding.typeAnnotation?.type else {
      diagnose(.envRequiresTypeAnnotation, at: binding)
      return nil
    }

    guard
      let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
      let keyArgument = arguments.first,
      let key = keyArgument.expression
      .as(StringLiteralExprSyntax.self)?
      .representedLiteralValue
    else {
      diagnose(.envRequiresStringLiteralKey, at: attribute)
      return nil
    }

    let defaultExpression =
      arguments
        .first { $0.label?.text == "default" }?
        .expression

    let (unwrapped, isOptional) = annotation.strippingOptional()

    return EnvPropertyInfo(
      key: key,
      valueType: unwrapped,
      isOptional: isOptional,
      defaultExpression: defaultExpression
    )
  }
}

extension TypeSyntax {
  /// Removes one level of optionality, handling both `T?` and `Optional<T>`.
  func strippingOptional() -> (type: TypeSyntax, wasOptional: Bool) {
    if let optional = self.as(OptionalTypeSyntax.self) {
      return (optional.wrappedType.trimmed, true)
    }
    if let identifier = self.as(IdentifierTypeSyntax.self),
       identifier.name.text == "Optional",
       let argument = identifier.genericArgumentClause?.arguments.first?.argument
       .as(TypeSyntax.self)
    {
      return (argument.trimmed, true)
    }
    return (trimmed, false)
  }
}

extension AttributeSyntax {
  /// The attribute's base name, ignoring any module qualification.
  var attributeBaseName: String? {
    if let identifier = attributeName.as(IdentifierTypeSyntax.self) {
      return identifier.name.text
    }
    if let member = attributeName.as(MemberTypeSyntax.self) {
      return member.name.text
    }
    return nil
  }
}

extension DeclModifierListSyntax {
  /// The access-level modifier to mirror onto generated members, so that a
  /// `public` configuration type gets a `public` initializer.
  ///
  /// `open` is mapped to `public`, since an initializer cannot be `open`.
  var generatedAccessLevel: String? {
    for modifier in self {
      switch modifier.name.tokenKind {
      case .keyword(.public), .keyword(.open): return "public"
      case .keyword(.package): return "package"
      case .keyword(.internal): return "internal"
      case .keyword(.fileprivate): return "fileprivate"
      case .keyword(.private): return "private"
      default: continue
      }
    }
    return nil
  }
}
