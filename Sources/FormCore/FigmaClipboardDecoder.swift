import CFormFigmaCompression
import CoreFoundation
import Foundation

/// Reads the ordinary Figma Copy HTML envelope locally. No URLs, HTML, schema
/// names, or payload fields are executed or fetched.
public enum FigmaClipboardDecoder {
  public static func decode(html: String, limits: FigmaClipboardLimits = .init()) throws -> FigmaClipboardDocument {
    let budget = try FigmaDecodeBudget(limits)
    guard html.utf8.count <= limits.inputBytes else { throw FigmaClipboardError.limit("HTML byte") }
    try budget.check()
    let bytes = Array(html.utf8)
    let payload = try marker("figma", in: bytes, maximum: limits.compressedBytes, budget: budget)
    let meta = try marker("figmeta", in: bytes, maximum: limits.metadataBytes, budget: budget)
    // JSONSerialization is bounded by the separate, small metadata byte cap.
    // Metadata is informational; scene identifiers come from lossless Kiwi values.
    let rawMetadata: Any
    do { rawMetadata = try JSONSerialization.jsonObject(with: meta, options: [.fragmentsAllowed]) }
    catch { throw FigmaClipboardError.invalid("metadata JSON") }
    let metadata = try jsonValue(rawMetadata, depth: 0, budget: budget)
    guard metadata.objectValue != nil else { throw FigmaClipboardError.invalid("metadata object") }
    return try decodeContainer(payload, metadata: metadata, budget: budget)
  }

  public static func decode(container: Data, metadata: FigmaValue? = nil,
    limits: FigmaClipboardLimits = .init()) throws -> FigmaClipboardDocument {
    try decodeContainer(container, metadata: metadata, budget: FigmaDecodeBudget(limits))
  }

  private static func decodeContainer(_ container: Data, metadata: FigmaValue?, budget: FigmaDecodeBudget) throws -> FigmaClipboardDocument {
    let limits = budget.limits
    guard container.count <= limits.compressedBytes else { throw FigmaClipboardError.limit("compressed byte") }
    var input = FigmaByteReader(container, budget: budget)
    guard try input.bytes(8) == Data("fig-kiwi".utf8) else { throw FigmaClipboardError.unsupported("container signature") }
    let version = try input.fixedUInt32()
    guard version > 0 else { throw FigmaClipboardError.invalid("container version") }
    var chunks: [Data] = []
    while !input.isAtEnd {
      try budget.spend()
      guard chunks.count < limits.chunks else { throw FigmaClipboardError.limit("chunk count") }
      let length = Int(try input.fixedUInt32())
      guard length > 0 else { throw FigmaClipboardError.invalid("empty compressed chunk") }
      chunks.append(try input.bytes(length))
    }
    guard chunks.count >= 2 else { throw FigmaClipboardError.invalid("missing schema or scene chunk") }
    let schemaData = try inflate(chunks[0], maximum: limits.schemaBytes, budget: budget)
    let schema = try FigmaKiwiSchema(schemaData, budget: budget)
    let messageData = try inflate(chunks[1], maximum: limits.decodedBytes, budget: budget)
    let message = try schema.decode(messageData, budget: budget)
    return FigmaClipboardDocument(message: message, metadata: metadata, version: version)
  }

  private static func marker(_ name: String, in html: [UInt8], maximum: Int, budget: FigmaDecodeBudget) throws -> Data {
    let start = Array(("(" + name + ")").utf8), end = Array(("(/" + name + ")").utf8)
    func find(_ needle: [UInt8], from: Int) throws -> Int? {
      guard from <= html.count, needle.count <= html.count - from else { return nil }
      for index in from...(html.count - needle.count) {
        if index & 4095 == 0 { try budget.check() }
        if html[index] == needle[0], html[index..<(index + needle.count)].elementsEqual(needle) { return index }
      }
      return nil
    }
    guard let begin = try find(start, from: 0), let finish = try find(end, from: begin + start.count) else {
      throw FigmaClipboardError.invalid("missing \(name) envelope")
    }
    let first = begin + start.count, count = finish - first
    guard count > 0, count <= ((maximum + 2) / 3) * 4 else { throw FigmaClipboardError.limit("\(name) Base64 byte") }
    guard try find(start, from: finish + end.count) == nil else { throw FigmaClipboardError.invalid("duplicate \(name) envelope") }
    let encoded = Data(html[first..<finish])
    guard let decoded = Data(base64Encoded: encoded), decoded.count <= maximum else {
      throw FigmaClipboardError.invalid("\(name) Base64")
    }
    try budget.check()
    return decoded
  }

  private static func jsonValue(_ value: Any, depth: Int, budget: FigmaDecodeBudget) throws -> FigmaValue {
    try budget.value(depth: depth)
    if value is NSNull { return .null }
    if let string = value as? String { try budget.string(string.utf8.count); return .string(string) }
    if let array = value as? [Any] {
      guard array.count <= budget.limits.arrayElements else { throw FigmaClipboardError.limit("metadata array") }
      return .array(try array.map { try jsonValue($0, depth: depth + 1, budget: budget) })
    }
    if let object = value as? [String: Any] {
      guard object.count <= budget.limits.fields else { throw FigmaClipboardError.limit("metadata field") }
      var result: [String: FigmaValue] = [:]
      for (key, child) in object { try budget.string(key.utf8.count); result[key] = try jsonValue(child, depth: depth + 1, budget: budget) }
      return .object(result)
    }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      let type = String(cString: number.objCType)
      if ["Q", "L", "I", "S", "C"].contains(type) { return .uint(number.uint64Value) }
      if ["q", "l", "i", "s", "c"].contains(type) { return .int(number.int64Value) }
      guard number.doubleValue.isFinite else { throw FigmaClipboardError.invalid("non-finite metadata number") }
      return .double(number.doubleValue)
    }
    throw FigmaClipboardError.invalid("metadata value")
  }

  private static func inflate(_ compressed: Data, maximum: Int, budget: FigmaDecodeBudget) throws -> Data {
    try budget.check()
    let zstd = compressed.starts(with: [0x28, 0xB5, 0x2F, 0xFD])
    guard let state = form_figma_inflater_create(zstd ? 1 : 0, maximum) else {
      throw FigmaClipboardError.invalid("compression allocation")
    }
    defer { form_figma_inflater_destroy(state) }
    var result = Data(), offset = 0
    var buffer = [UInt8](repeating: 0, count: min(65536, maximum + 1))
    while true {
      try budget.spend()
      let available = min(65536, compressed.count - offset)
      var inputUsed = 0, outputUsed = 0
      let status = compressed.withUnsafeBytes { input in
        buffer.withUnsafeMutableBytes { output in
          form_figma_inflater_step(state, input.baseAddress?.assumingMemoryBound(to: UInt8.self).advanced(by: offset),
            available, &inputUsed, output.baseAddress?.assumingMemoryBound(to: UInt8.self), output.count, &outputUsed)
        }
      }
      guard status >= 0, inputUsed <= available, outputUsed <= buffer.count else {
        throw FigmaClipboardError.invalid(zstd ? "Zstandard stream" : "raw Deflate stream")
      }
      guard outputUsed <= maximum - result.count else { throw FigmaClipboardError.limit("decompressed byte") }
      result.append(contentsOf: buffer.prefix(outputUsed)); offset += inputUsed
      if status == 1 {
        guard offset == compressed.count else { throw FigmaClipboardError.invalid("trailing compressed data") }
        return result
      }
      guard inputUsed > 0 || outputUsed > 0 else { throw FigmaClipboardError.invalid("truncated compressed stream") }
    }
  }
}

final class FigmaDecodeBudget {
  let limits: FigmaClipboardLimits
  private var remainingWork: Int, remainingValues: Int, remainingStrings: Int
  init(_ limits: FigmaClipboardLimits) throws {
    let counts = [limits.inputBytes, limits.compressedBytes, limits.schemaBytes, limits.decodedBytes,
      limits.metadataBytes, limits.stringBytes, limits.totalStringBytes, limits.definitions, limits.fields,
      limits.arrayElements, limits.values, limits.depth, limits.work, limits.chunks]
    guard counts.allSatisfy({ $0 > 0 && $0 <= 256 * 1024 * 1024 }), limits.depth <= 256 else {
      throw FigmaClipboardError.invalid("decoder limits")
    }
    self.limits = limits; remainingWork = limits.work; remainingValues = limits.values; remainingStrings = limits.totalStringBytes
    try check()
  }
  func check() throws { try Task.checkCancellation() }
  func spend(_ count: Int = 1) throws {
    guard count >= 0, count <= remainingWork else { throw FigmaClipboardError.limit("decode work") }
    remainingWork -= count; try check()
  }
  func value(depth: Int) throws {
    try spend()
    guard depth <= limits.depth else { throw FigmaClipboardError.limit("value depth") }
    guard remainingValues > 0 else { throw FigmaClipboardError.limit("value count") }
    remainingValues -= 1
  }
  func array(_ count: Int) throws {
    guard count >= 0, count <= limits.arrayElements, count <= remainingValues, count <= remainingWork else {
      throw FigmaClipboardError.limit("array element")
    }
  }
  func string(_ count: Int) throws {
    guard count <= limits.stringBytes, count <= remainingStrings else { throw FigmaClipboardError.limit("string byte") }
    remainingStrings -= count
  }
}
