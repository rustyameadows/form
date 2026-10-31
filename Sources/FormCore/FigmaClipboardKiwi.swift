import Foundation

/// Independent implementation of the public Kiwi wire specification. The
/// payload's schema is interpreted as data; no generated code is evaluated.
struct FigmaByteReader {
  private let storage: [UInt8]
  private(set) var offset = 0
  let budget: FigmaDecodeBudget
  init(_ data: Data, budget: FigmaDecodeBudget) { storage = Array(data); self.budget = budget }
  var isAtEnd: Bool { offset == storage.count }
  var remaining: Int { storage.count - offset }
  mutating func byte() throws -> UInt8 {
    guard offset < storage.count else { throw FigmaClipboardError.invalid("truncated Kiwi value") }
    defer { offset += 1 }; return storage[offset]
  }
  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, count <= remaining else { throw FigmaClipboardError.invalid("truncated byte range") }
    defer { offset += count }; return Data(storage[offset..<(offset + count)])
  }
  mutating func fixedUInt32() throws -> UInt32 {
    guard remaining >= 4 else { throw FigmaClipboardError.invalid("truncated 32-bit header") }
    let value = UInt32(storage[offset]) | UInt32(storage[offset + 1]) << 8
      | UInt32(storage[offset + 2]) << 16 | UInt32(storage[offset + 3]) << 24
    offset += 4; return value
  }
  mutating func uint() throws -> UInt32 {
    var result: UInt32 = 0
    for index in 0..<5 {
      let next = try byte()
      if index == 4, next > 15 { throw FigmaClipboardError.invalid("32-bit varint overflow") }
      result |= UInt32(next & 127) << (index * 7)
      if next & 128 == 0 { return result }
    }
    throw FigmaClipboardError.invalid("unterminated varint")
  }
  mutating func int() throws -> Int32 {
    let value = try uint()
    return Int32(bitPattern: value >> 1) ^ -Int32(value & 1)
  }
  mutating func uint64() throws -> UInt64 {
    var result: UInt64 = 0
    // Kiwi's ninth byte carries eight data bits, unlike a ten-byte Protobuf uint64.
    for index in 0..<9 {
      let next = try byte()
      if index == 8 { return result | UInt64(next) << 56 }
      result |= UInt64(next & 127) << (index * 7)
      if next & 128 == 0 { return result }
    }
    throw FigmaClipboardError.invalid("64-bit varint")
  }
  mutating func int64() throws -> Int64 {
    let value = try uint64()
    return Int64(bitPattern: value >> 1) ^ -Int64(value & 1)
  }
  mutating func float() throws -> Double {
    let first = try byte()
    if first == 0 { return 0 }
    let bits = UInt32(first) | UInt32(try byte()) << 8 | UInt32(try byte()) << 16 | UInt32(try byte()) << 24
    let value = Float(bitPattern: bits << 23 | bits >> 9)
    guard value.isFinite else { throw FigmaClipboardError.invalid("non-finite Kiwi float") }
    return Double(value)
  }
  mutating func string() throws -> String {
    let start = offset
    while true {
      if (offset - start) & 4095 == 0 { try budget.check() }
      guard offset - start <= budget.limits.stringBytes else { throw FigmaClipboardError.limit("string byte") }
      if try byte() == 0 { break }
    }
    let count = offset - start - 1
    try budget.string(count)
    guard let value = String(bytes: storage[start..<(start + count)], encoding: .utf8) else {
      throw FigmaClipboardError.invalid("UTF-8 string")
    }
    return value
  }
}

struct FigmaKiwiSchema {
  struct Field { let name: String, type: Int; let array: Bool; let id: UInt32 }
  struct Definition { let name: String; let kind: UInt8; let fields: [Field]; let byID: [UInt32: Field] }
  let definitions: [Definition]
  private let root: Int

  init(_ data: Data, budget: FigmaDecodeBudget) throws {
    var reader = FigmaByteReader(data, budget: budget)
    let count = Int(try reader.uint())
    guard count > 0, count <= budget.limits.definitions else { throw FigmaClipboardError.limit("schema definition") }
    var result: [Definition] = [], names = Set<String>(), fieldCount = 0
    for _ in 0..<count {
      try budget.spend()
      let name = try reader.string(), kind = try reader.byte()
      guard !name.isEmpty, name.utf8.count <= 256, names.insert(name).inserted, kind <= 2 else {
        throw FigmaClipboardError.invalid("schema definition name or kind")
      }
      let count = Int(try reader.uint())
      guard count <= budget.limits.fields - fieldCount else { throw FigmaClipboardError.limit("schema field") }
      fieldCount += count
      var fields: [Field] = [], byID: [UInt32: Field] = [:], fieldNames = Set<String>()
      for _ in 0..<count {
        try budget.spend()
        let name = try reader.string(), type = Int(try reader.int()), array = try reader.byte(), id = try reader.uint()
        guard !name.isEmpty, name.utf8.count <= 256, fieldNames.insert(name).inserted, array <= 1,
          (kind != 2 || id != 0), (kind == 1 || byID[id] == nil) else {
          throw FigmaClipboardError.invalid("schema field name, tag, or array flag")
        }
        let field = Field(name: name, type: type, array: array == 1, id: id)
        fields.append(field); byID[id] = field
      }
      result.append(Definition(name: name, kind: kind, fields: fields, byID: byID))
    }
    guard reader.isAtEnd else { throw FigmaClipboardError.invalid("trailing schema bytes") }
    for definition in result where definition.kind != 0 {
      for field in definition.fields {
        try budget.spend()
        guard field.type >= -8, field.type < result.count else { throw FigmaClipboardError.invalid("schema type reference") }
      }
    }
    guard let root = result.firstIndex(where: { $0.name == "Message" && $0.kind == 2 }) else {
      throw FigmaClipboardError.unsupported("schema has no Message root")
    }
    definitions = result; self.root = root
  }

  func decode(_ data: Data, budget: FigmaDecodeBudget) throws -> FigmaValue {
    var reader = FigmaByteReader(data, budget: budget)
    let value = try decodeType(root, reader: &reader, depth: 0)
    guard reader.isAtEnd else { throw FigmaClipboardError.invalid("trailing Message bytes") }
    return value
  }

  private func decodeType(_ type: Int, reader: inout FigmaByteReader, depth: Int) throws -> FigmaValue {
    try reader.budget.value(depth: depth)
    if type < 0 {
      switch type {
      case -1: return .bool(try reader.byte() != 0)
      case -2: return .uint(UInt64(try reader.byte()))
      case -3: return .int(Int64(try reader.int()))
      case -4: return .uint(UInt64(try reader.uint()))
      case -5: return .double(try reader.float())
      case -6: return .string(try reader.string())
      case -7: return .int(try reader.int64())
      case -8: return .uint(try reader.uint64())
      default: throw FigmaClipboardError.invalid("primitive type")
      }
    }
    let definition = definitions[type]
    if definition.kind == 0 {
      let tag = try reader.uint()
      return definition.byID[tag].map { .string($0.name) } ?? .uint(UInt64(tag))
    }
    var result: [String: FigmaValue] = [:]
    if definition.kind == 1 {
      for field in definition.fields { result[field.name] = try decodeField(field, reader: &reader, depth: depth + 1) }
    } else {
      var seen = Set<UInt32>()
      while true {
        try reader.budget.spend()
        let tag = try reader.uint()
        if tag == 0 { break }
        guard let field = definition.byID[tag], seen.insert(tag).inserted else {
          throw FigmaClipboardError.invalid("message field absent from schema or repeated")
        }
        // All schema-described fields are decoded, including those the artwork
        // mapper does not yet understand. Their semantic names remain available.
        result[field.name] = try decodeField(field, reader: &reader, depth: depth + 1)
      }
    }
    return .object(result)
  }

  private func decodeField(_ field: Field, reader: inout FigmaByteReader, depth: Int) throws -> FigmaValue {
    guard field.array else { return try decodeType(field.type, reader: &reader, depth: depth) }
    try reader.budget.value(depth: depth)
    let count = Int(try reader.uint())
    if field.type == -2 { return .data(try reader.bytes(count)) }
    try reader.budget.array(count)
    var result: [FigmaValue] = []; result.reserveCapacity(count)
    for _ in 0..<count { result.append(try decodeType(field.type, reader: &reader, depth: depth + 1)) }
    return .array(result)
  }
}
