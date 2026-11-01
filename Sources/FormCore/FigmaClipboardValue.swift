import Foundation

/// Values decoded from the payload's own Kiwi schema. Integer IDs never pass
/// through floating point; byte arrays stay binary instead of expanding to JSON.
public indirect enum FigmaValue: Equatable, Codable, Sendable {
  case null, bool(Bool), int(Int64), uint(UInt64), double(Double), string(String)
  case array([FigmaValue]), object([String: FigmaValue]), data(Data)

  public subscript(_ key: String) -> FigmaValue? { objectValue?[key] }
  public var objectValue: [String: FigmaValue]? { if case .object(let value) = self { return value }; return nil }
  public var arrayValue: [FigmaValue]? { if case .array(let value) = self { return value }; return nil }
  public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
  public var dataValue: Data? { if case .data(let value) = self { return value }; return nil }
  public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
  public var numberValue: Double? {
    switch self { case .int(let value): return Double(value)
    case .uint(let value): return Double(value)
    case .double(let value): return value
    default: return nil }
  }
  public var integerValue: Int? {
    switch self { case .int(let value): return Int(exactly: value)
    case .uint(let value): return Int(exactly: value)
    case .double(let value): return Int(exactly: value)
    default: return nil }
  }
  /// Codable's tagged cases distinguish binary bytes and full-width signed and
  /// unsigned integers from ordinary objects and floating-point numbers.
  public func encodedJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}

public struct FigmaClipboardDocument: Equatable, Sendable {
  public let message: FigmaValue
  public let metadata: FigmaValue?
  public let version: UInt32
  public init(message: FigmaValue, metadata: FigmaValue? = nil, version: UInt32 = 101) {
    self.message = message; self.metadata = metadata; self.version = version
  }
}

/// Independent caps apply before allocation and throughout interpretation.
/// Conversion applies its own graph and artwork-transfer limits afterwards.
public struct FigmaClipboardLimits: Sendable {
  public var inputBytes = 48 * 1024 * 1024
  public var compressedBytes = 32 * 1024 * 1024
  public var schemaBytes = 4 * 1024 * 1024
  public var decodedBytes = 64 * 1024 * 1024
  public var metadataBytes = 64 * 1024
  public var stringBytes = 8 * 1024 * 1024
  public var totalStringBytes = 16 * 1024 * 1024
  public var definitions = 2048
  public var fields = 32768
  public var arrayElements = 250000
  public var values = 1000000
  public var depth = 128
  public var work = 4000000
  public var chunks = 16
  public init() {}
}

public enum FigmaClipboardError: Error, LocalizedError, Equatable, Sendable {
  case invalid(String), limit(String), unsupported(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let detail): return "Invalid Figma clipboard data: \(detail)"
    case .limit(let detail): return "Figma clipboard data exceeds its \(detail) limit."
    case .unsupported(let detail): return "Unsupported Figma clipboard data: \(detail)"
    }
  }
}
