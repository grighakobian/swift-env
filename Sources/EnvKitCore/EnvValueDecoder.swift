import Foundation

/// Converts raw `.env` strings into the declared Swift types.
///
/// Shared by the runtime reader and the codegen tool so that a value which
/// validates at build time decodes identically at runtime.
public struct EnvValueDecoder: Sendable {
    /// Separator for `[String]` and `[Int]` values.
    public var arraySeparator: Character

    /// Strings accepted as `true` and `false`, compared case-insensitively.
    public var trueValues: Set<String>
    public var falseValues: Set<String>

    public init(
        arraySeparator: Character = ",",
        trueValues: Set<String> = ["true", "yes", "on", "1"],
        falseValues: Set<String> = ["false", "no", "off", "0"]
    ) {
        self.arraySeparator = arraySeparator
        self.trueValues = trueValues
        self.falseValues = falseValues
    }

    public static var `default`: EnvValueDecoder { EnvValueDecoder() }

    public struct TypeMismatchError: Error, Sendable, Hashable, CustomStringConvertible {
        public var key: String
        public var expected: EnvValueType
        /// Omitted when the key is marked secret, so values never reach logs.
        public var value: String?

        public var description: String {
            if let value {
                "value '\(value)' for key '\(key)' is not a valid \(expected.swiftTypeName)"
            } else {
                "value for key '\(key)' is not a valid \(expected.swiftTypeName)"
            }
        }
    }

    // MARK: - Typed decoding

    public func string(_ raw: String) -> String { raw }

    public func int(_ raw: String) -> Int? {
        Int(raw.trimmingASCIIWhitespace())
    }

    public func double(_ raw: String) -> Double? {
        Double(raw.trimmingASCIIWhitespace())
    }

    public func bool(_ raw: String) -> Bool? {
        let normalized = raw.trimmingASCIIWhitespace().lowercased()
        if trueValues.contains(normalized) { return true }
        if falseValues.contains(normalized) { return false }
        return nil
    }

    /// Requires an absolute URL, since a scheme-less string like `not a url`
    /// would otherwise be accepted as a relative `URL`.
    public func url(_ raw: String) -> URL? {
        let trimmed = raw.trimmingASCIIWhitespace()
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    public func data(_ raw: String) -> Data? {
        Data(base64Encoded: raw.trimmingASCIIWhitespace())
    }

    public func stringArray(_ raw: String) -> [String] {
        let trimmed = raw.trimmingASCIIWhitespace()
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: arraySeparator).map {
            String($0).trimmingASCIIWhitespace()
        }
    }

    public func intArray(_ raw: String) -> [Int]? {
        let components = stringArray(raw)
        let values = components.compactMap { Int($0) }
        return values.count == components.count ? values : nil
    }

    // MARK: - Validation

    /// Reports whether `raw` decodes as `type`, without building the value.
    public func validates(_ raw: String, as type: EnvValueType) -> Bool {
        switch type {
        case .string: true
        case .int: int(raw) != nil
        case .double: double(raw) != nil
        case .bool: bool(raw) != nil
        case .url: url(raw) != nil
        case .data: data(raw) != nil
        case .stringArray: true
        case .intArray: intArray(raw) != nil
        }
    }

    /// Throws when `raw` does not decode as `type`.
    ///
    /// - Parameter isSecret: Withholds the offending value from the error when
    ///   `true`.
    public func validate(
        _ raw: String,
        as type: EnvValueType,
        key: String,
        isSecret: Bool = false
    ) throws {
        guard !validates(raw, as: type) else { return }
        throw TypeMismatchError(key: key, expected: type, value: isSecret ? nil : raw)
    }
}
