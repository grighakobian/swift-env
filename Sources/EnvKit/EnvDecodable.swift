import Foundation

@_exported import EnvKitCore

/// A type that can be built from a raw `.env` string.
///
/// Conformances are provided for the types ``EnvValueType`` covers. Adding your
/// own lets `@Env` project a domain type directly.
public protocol EnvDecodable: Sendable {
  /// The declared type used for build-time validation and diagnostics.
  static var envValueType: EnvValueType { get }

  /// Returns `nil` when `raw` is not a valid representation.
  static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> Self?
}

extension String: EnvDecodable {
  public static var envValueType: EnvValueType { .string }
  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> String? {
    decoder.string(raw)
  }
}

extension Int: EnvDecodable {
  public static var envValueType: EnvValueType { .int }
  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> Int? {
    decoder.int(raw)
  }
}

extension Double: EnvDecodable {
  public static var envValueType: EnvValueType { .double }
  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> Double? {
    decoder.double(raw)
  }
}

extension Bool: EnvDecodable {
  public static var envValueType: EnvValueType { .bool }
  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> Bool? {
    decoder.bool(raw)
  }
}

extension URL: EnvDecodable {
  public static var envValueType: EnvValueType { .url }
  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> URL? {
    decoder.url(raw)
  }
}

extension Data: EnvDecodable {
  public static var envValueType: EnvValueType { .data }
  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> Data? {
    decoder.data(raw)
  }
}

extension Array: EnvDecodable where Element: EnvDecodable {
  public static var envValueType: EnvValueType {
    Element.envValueType == .int ? .intArray : .stringArray
  }

  public static func decodeEnvValue(_ raw: String, using decoder: EnvValueDecoder) -> [Element]? {
    let components = decoder.stringArray(raw)
    let decoded = components.compactMap { Element.decodeEnvValue($0, using: decoder) }
    return decoded.count == components.count ? decoded : nil
  }
}
