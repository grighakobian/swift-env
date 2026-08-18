import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Implements `@EnvConfig`, which wires a type's `@Env` properties to a reader
/// and validates them all at initialization.
public enum EnvConfigMacro {
    /// Collects the `@Env` properties of a type in declaration order.
    ///
    /// Malformed properties are skipped silently here; `@Env` reports them, so
    /// reporting again would double up every diagnostic.
    static func properties(
        of declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [EnvPropertyInfo] {
        declaration.memberBlock.members.compactMap { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { return nil }
            guard
                let attribute = variable.attributes
                .compactMap({ $0.as(AttributeSyntax.self) })
                .first(where: { $0.attributeBaseName == "Env" })
            else { return nil }

            return EnvPropertyInfo.extract(
                attribute: attribute,
                from: variable,
                in: context,
                emitDiagnostics: false
            )
        }
    }
}

extension EnvConfigMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.isSupportedNominalType else {
            context.diagnose(
                Diagnostic(node: Syntax(node), message: EnvMacroDiagnostic.requiresNominalType)
            )
            return []
        }

        let properties = properties(of: declaration, in: context)
        if properties.isEmpty {
            context.diagnose(
                Diagnostic(node: Syntax(node), message: EnvMacroDiagnostic.configHasNoKeys)
            )
        }

        let access = declaration.modifiers.generatedAccessLevel.map { "\($0) " } ?? ""

        // Built line by line rather than through string interpolation, because
        // interpolating a multi-line string into a `DeclSyntax` literal does not
        // re-indent its continuation lines.
        var requirementLines = ["/// Every key this type reads, in declaration order."]
        requirementLines.append("\(access)static var envRequirements: [EnvKit.EnvRequirement] {")
        if properties.isEmpty {
            requirementLines.append("    []")
        } else {
            requirementLines.append("    [")
            for (offset, property) in properties.enumerated() {
                let comma = offset == properties.count - 1 ? "" : ","
                requirementLines.append(
                    """
                            .init(\
                    key: \"\(property.key)\", \
                    type: \(property.valueType).envValueType, \
                    isOptional: \(property.isOptional), \
                    hasDefault: \(property.hasDefault))\(comma)
                    """
                )
            }
            requirementLines.append("    ]")
        }
        requirementLines.append("}")

        return [
            """
            /// The reader backing this type's `@Env` properties.
            private let _envReader: EnvKit.EnvReader
            """,

            DeclSyntax(stringLiteral: requirementLines.joined(separator: "\n")),

            """
            /// Validates every declared key up front, so a misconfigured
            /// process fails here rather than at the first property access.
            \(raw: access)init(_ reader: EnvKit.EnvReader = .shared) throws {
                self._envReader = reader
                try reader.validate(Self.envRequirements)
            }
            """,
        ]
    }
}

extension EnvConfigMacro: ExtensionMacro {
    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Empty when the user already wrote the conformance, which the compiler
        // reports through `protocols`.
        guard !protocols.isEmpty, declaration.isSupportedNominalType else { return [] }

        return try [
            ExtensionDeclSyntax("extension \(type.trimmed): EnvKit.EnvConfiguration {}"),
        ]
    }
}

extension DeclGroupSyntax {
    /// Whether `@EnvConfig` can be applied: it needs stored-property storage and
    /// an initializer, which enums and protocols cannot provide.
    var isSupportedNominalType: Bool {
        self.is(StructDeclSyntax.self) || self.is(ClassDeclSyntax.self)
            || self.is(ActorDeclSyntax.self)
    }
}
