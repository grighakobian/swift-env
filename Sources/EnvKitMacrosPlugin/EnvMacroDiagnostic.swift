import SwiftDiagnostics
import SwiftSyntax

/// Diagnostics emitted by `@EnvConfig` and `@Env`.
enum EnvMacroDiagnostic: String, DiagnosticMessage {
  case requiresNominalType
  case envRequiresVariable
  case envRequiresVar
  case envRequiresTypeAnnotation
  case envRejectsInitializer
  case envRejectsComputedProperty
  case envRequiresStringLiteralKey
  case envRequiresSingleBinding
  case configHasNoKeys

  var severity: DiagnosticSeverity {
    switch self {
    case .configHasNoKeys: .warning
    default: .error
    }
  }

  var message: String {
    switch self {
    case .requiresNominalType:
      "'@EnvConfig' can only be applied to a struct, class, or actor"
    case .envRequiresVariable:
      "'@Env' can only be applied to a property"
    case .envRequiresVar:
      "'@Env' requires 'var' because the value is read through the environment reader"
    case .envRequiresTypeAnnotation:
      "'@Env' requires an explicit type annotation, which determines how the value is decoded"
    case .envRejectsInitializer:
      "'@Env' property cannot have an initial value; supply a fallback with '@Env(\"KEY\", default:)' instead"
    case .envRejectsComputedProperty:
      "'@Env' cannot be applied to a property that already defines accessors"
    case .envRequiresStringLiteralKey:
      "'@Env' requires a string literal key so it can be validated at build time"
    case .envRequiresSingleBinding:
      "'@Env' cannot be applied to a declaration that binds several properties at once"
    case .configHasNoKeys:
      "'@EnvConfig' type declares no '@Env' properties"
    }
  }

  var diagnosticID: MessageID {
    MessageID(domain: "EnvKitMacros", id: rawValue)
  }
}

/// A fix-it that removes an offending initializer clause.
enum EnvMacroFixIt: String, FixItMessage {
  case removeInitializer

  var message: String {
    switch self {
    case .removeInitializer: "remove the initial value"
    }
  }

  var fixItID: MessageID { MessageID(domain: "EnvKitMacros", id: rawValue) }
}
