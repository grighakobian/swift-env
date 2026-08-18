/// Expands `${VAR}` references inside `.env` values.
///
/// Runs after files have been layered, so a reference can resolve against a
/// value defined in a lower-precedence file:
///
/// ```
/// # .env
/// HOST=localhost
/// # .env.debug
/// BASE_URL=http://${HOST}:${PORT:-8080}
/// ```
///
/// ### Supported forms
/// - `$VAR` and `${VAR}`
/// - `${VAR:-fallback}` — uses `fallback` when `VAR` is unset *or* empty
/// - `${VAR-fallback}` — uses `fallback` only when `VAR` is unset
/// - `\$` — a literal dollar sign
public struct EnvInterpolator: Sendable {
    /// What to do with a reference that cannot be resolved and has no fallback.
    public enum UnresolvedReferenceBehavior: Sendable, Hashable {
        /// Substitute an empty string, as a POSIX shell does.
        case substituteEmpty
        /// Leave the reference text in place, so the problem stays visible.
        case keepLiteral
        /// Fail, surfacing the unresolved name.
        case reportError
    }

    public struct UnresolvedReferenceError: Error, Sendable, Hashable, CustomStringConvertible {
        public var name: String
        public var key: String?

        public var description: String {
            if let key {
                "unresolved reference '${\(name)}' while expanding '\(key)'"
            } else {
                "unresolved reference '${\(name)}'"
            }
        }
    }

    public var behavior: UnresolvedReferenceBehavior

    /// Caps how deep a chain of references may nest, so that a cycle such as
    /// `A=${B}` / `B=${A}` terminates instead of hanging the build.
    public var maximumDepth: Int

    public init(
        behavior: UnresolvedReferenceBehavior = .substituteEmpty,
        maximumDepth: Int = 16
    ) {
        self.behavior = behavior
        self.maximumDepth = maximumDepth
    }

    /// Expands references in `value`, resolving names through `lookup`.
    ///
    /// - Parameter key: The key being expanded, used only in error messages.
    public func expand(
        _ value: String,
        key: String? = nil,
        lookup: (String) -> String?
    ) throws -> String {
        try expand(value, key: key, depth: 0, lookup: lookup)
    }

    private func expand(
        _ value: String,
        key: String?,
        depth: Int,
        lookup: (String) -> String?
    ) throws -> String {
        guard depth < maximumDepth, value.contains("$") else { return value }

        var result = ""
        let characters = Array(value)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\\", index + 1 < characters.count, characters[index + 1] == "$" {
                result.append("$")
                index += 2
                continue
            }

            guard character == "$" else {
                result.append(character)
                index += 1
                continue
            }

            index += 1
            guard index < characters.count else {
                result.append("$")
                break
            }

            let reference: Reference?
            if characters[index] == "{" {
                reference = Self.readBracedReference(characters, from: &index)
            } else {
                reference = Self.readBareReference(characters, from: &index)
            }

            guard let reference else {
                // Not actually a reference (`$` followed by punctuation, say).
                result.append("$")
                continue
            }

            let resolved = lookup(reference.name)
            let substitution: String

            switch (resolved, reference.fallback) {
            case let (existing?, fallback?) where existing.isEmpty && reference.treatsEmptyAsUnset:
                substitution = try expand(fallback, key: key, depth: depth + 1, lookup: lookup)
            case let (existing?, _):
                substitution = try expand(existing, key: key, depth: depth + 1, lookup: lookup)
            case (nil, let fallback?):
                substitution = try expand(fallback, key: key, depth: depth + 1, lookup: lookup)
            case (nil, nil):
                switch behavior {
                case .substituteEmpty:
                    substitution = ""
                case .keepLiteral:
                    substitution = reference.literalText
                case .reportError:
                    throw UnresolvedReferenceError(name: reference.name, key: key)
                }
            }

            result.append(contentsOf: substitution)
        }

        return result
    }

    // MARK: - Reference scanning

    private struct Reference {
        var name: String
        var fallback: String?
        /// True for `:-`, which also replaces empty values.
        var treatsEmptyAsUnset: Bool
        var literalText: String
    }

    /// Parses `{NAME}`, `{NAME:-fallback}`, or `{NAME-fallback}` starting at the
    /// opening brace. Leaves `index` past the closing brace.
    private static func readBracedReference(
        _ characters: [Character],
        from index: inout Int
    ) -> Reference? {
        let start = index
        index += 1 // '{'

        guard index < characters.count, isNameStartCharacter(characters[index]) else {
            index = start
            return nil
        }

        var name = ""
        while index < characters.count, isNameCharacter(characters[index]) {
            name.append(characters[index])
            index += 1
        }

        guard index < characters.count else {
            index = start
            return nil
        }

        var fallback: String?
        var treatsEmptyAsUnset = false

        if characters[index] == ":" || characters[index] == "-" {
            if characters[index] == ":" {
                treatsEmptyAsUnset = true
                index += 1
                guard index < characters.count, characters[index] == "-" else {
                    index = start
                    return nil
                }
            }
            index += 1 // '-'

            // Take everything up to the matching brace, allowing nested `${}`.
            var text = ""
            var nesting = 0
            while index < characters.count {
                let character = characters[index]
                if character == "{" { nesting += 1 }
                if character == "}" {
                    if nesting == 0 { break }
                    nesting -= 1
                }
                text.append(character)
                index += 1
            }
            fallback = text
        }

        guard index < characters.count, characters[index] == "}" else {
            index = start
            return nil
        }
        index += 1 // '}'

        return Reference(
            name: name,
            fallback: fallback,
            treatsEmptyAsUnset: treatsEmptyAsUnset,
            literalText: String(characters[start - 1 ..< index])
        )
    }

    /// Parses a bare `$NAME`. Leaves `index` past the name.
    private static func readBareReference(
        _ characters: [Character],
        from index: inout Int
    ) -> Reference? {
        guard index < characters.count, isNameStartCharacter(characters[index]) else {
            return nil
        }

        var name = ""
        while index < characters.count, isNameCharacter(characters[index]) {
            name.append(characters[index])
            index += 1
        }
        return Reference(
            name: name,
            fallback: nil,
            treatsEmptyAsUnset: false,
            literalText: "$" + name
        )
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// Reference names follow identifier rules, so `$5` and `100$` stay literal.
    private static func isNameStartCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }
}
