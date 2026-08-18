import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct EnvKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        EnvConfigMacro.self,
        EnvMacro.self,
    ]
}
