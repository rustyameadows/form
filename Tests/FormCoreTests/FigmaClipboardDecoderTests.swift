import Foundation
import XCTest
@testable import FormCore

/// Wire fixtures are assembled from the public binary specification, not an
/// encoder shared with production. They contain no copied user/Figma documents.
final class FigmaClipboardDecoderTests: XCTestCase {
  private struct Field {
    var name: String, type: Int32, array: Bool = false, tag: UInt32
  }
  private struct Definition {
    var name: String, kind: UInt8 = 2, fields: [Field]
  }
  private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  private func uint(_ value: UInt32) -> [UInt8] {
    var value = value, result: [UInt8] = []
    repeat { let byte = UInt8(value & 127); value >>= 7; result.append(byte | (value > 0 ? 128 : 0)) } while value > 0
    return result
  }
  private func string(_ value: String) -> [UInt8] { Array(value.utf8) + [0] }
  private func schema(_ definitions: [Definition]) -> Data {
    var bytes = uint(UInt32(definitions.count))
    for definition in definitions {
      bytes += string(definition.name) + [definition.kind] + uint(UInt32(definition.fields.count))
      for field in definition.fields {
        let signed = UInt32(bitPattern: (field.type &<< 1) ^ (field.type >> 31))
        bytes += string(field.name) + uint(signed) + [field.array ? 1 : 0] + uint(field.tag)
      }
    }
    return Data(bytes)
  }
  private var textSchema: Data { schema([.init(name: "Message", fields: [.init(name: "characters", type: -6, tag: 1)])]) }
  private func rawDeflate(_ data: Data) -> Data {
    // Final stored block: BFINAL=1/BTYPE=00, byte alignment, LEN + one's-complement NLEN.
    precondition(data.count <= 65535)
    let count = UInt16(data.count)
    return Data([1, UInt8(truncatingIfNeeded: count), UInt8(count >> 8),
      UInt8(truncatingIfNeeded: ~count), UInt8((~count) >> 8)]) + data
  }
  private func zstdRaw(_ data: Data) -> Data {
    // Single-segment, no dictionary/checksum, one raw block (RFC 8878).
    precondition(data.count <= 255)
    let block = UInt32(data.count) << 3 | 1
    return Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, UInt8(data.count)] + Array(u32(block).prefix(3))) + data
  }
  private func zstdRLE(count: UInt32, value: UInt8) -> Data {
    // Single-segment with a 32-bit content size and one RLE block.
    let block = count << 3 | 3
    return Data([0x28, 0xB5, 0x2F, 0xFD, 0xA0] + u32(count) + Array(u32(block).prefix(3)) + [value])
  }
  private func container(schema schemaData: Data, message: Data, zstd: Bool = false) -> Data {
    let first = rawDeflate(schemaData), second = zstd ? zstdRaw(message) : rawDeflate(message)
    return container(chunks: [first, second])
  }
  private func container(chunks: [Data]) -> Data {
    var result = Data("fig-kiwi".utf8) + Data(u32(101))
    for chunk in chunks { result += Data(u32(UInt32(chunk.count))) + chunk }
    return result
  }
  private func html(_ container: Data, meta: String = "{\"fileKey\":\"synthetic\",\"pasteID\":7,\"dataType\":\"scene\"}") -> String {
    "<meta charset=\"utf-8\"><span data-metadata=\"<!--(figmeta)\(Data(meta.utf8).base64EncodedString())(/figmeta)-->\"></span>"
      + "<span data-buffer=\"<!--(figma)\(container.base64EncodedString())(/figma)-->\"></span>"
  }

  func testOrdinaryHTMLEnvelopeDecodesEmbeddedSchemaAndBothCompressionCodecs() throws {
    let characters = "A😀e\u{301}\nمرحبا"
    for zstd in [false, true] {
      let input = container(schema: textSchema, message: Data([1] + string(characters) + [0]), zstd: zstd)
      let result = try FigmaClipboardDecoder.decode(html: html(input))
      XCTAssertEqual(result.version, 101)
      XCTAssertEqual(result.metadata?["fileKey"]?.stringValue, "synthetic")
      XCTAssertEqual(result.message["characters"]?.stringValue, characters)
      XCTAssertEqual(result.message["characters"]?.stringValue?.utf16.count, characters.utf16.count)
      XCTAssertEqual(Array(try XCTUnwrap(result.message["characters"]?.stringValue).unicodeScalars), Array(characters.unicodeScalars))
    }
  }

  func testIndependentEntropyCodedVectorsAndChecksumValidation() throws {
    // Fixed vectors generated independently using zlib level9/raw and the
    // official Zstandard CLI v1.5.7, level19, default checksum. No compressor is
    // linked into this test or the app. These exercise compressed blocks rather
    // than only the manually constructed raw/RLE/stored-block fixtures below.
    func bytes(_ hex: String) -> Data {
      let characters = Array(hex)
      return Data(stride(from: 0, to: characters.count, by: 2).map {
        UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
      })
    }
    let expected = String(repeating: "Synthetic Kiwi payload 😀 / ", count: 100)
    let deflate = bytes("630caecc2bc9482dc94c56f0ce2ccf542848acccc94f4c51f8307f468382bec2a8eca8eca8eca8eca8eca8eca8eca8eca8eca8eca8ec609065600000")
    let zstd = bytes("28b52ffd046855010014020153796e746865746963204b697769207061796c6f616420f09f9880202f20000001005f2ef8ca09cd7f8af9")
    for compressed in [deflate, zstd] {
      let input = container(chunks: [rawDeflate(textSchema), compressed])
      XCTAssertEqual(try FigmaClipboardDecoder.decode(container: input).message["characters"], .string(expected))
      var limits = FigmaClipboardLimits(); limits.decodedBytes = 1024
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: input, limits: limits))
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(chunks: [rawDeflate(textSchema), Data(compressed.dropLast(2))])))
    }
    var corruptChecksum = zstd; corruptChecksum[corruptChecksum.count - 1] ^= 1
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(chunks: [rawDeflate(textSchema), corruptChecksum])))
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(chunks: [rawDeflate(textSchema), zstd + zstd])))
  }

  func testZstdDictionaryReferencesReservedHeaderAndMalformedSchemaFlagsReject() throws {
    let message = Data([0]), raw = zstdRaw(message)
    var reserved = raw; reserved[4] |= 8
    // Single-segment frame with dictionary-ID flag1, requiring dictionary7.
    let missingDictionary = Data([0x28,0xB5,0x2F,0xFD,0x21,7,1,9,0,0,0])
    for invalid in [reserved, missingDictionary] {
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(chunks: [rawDeflate(textSchema), invalid])))
    }
    let repeatedTag = schema([.init(name: "Message", fields: [.init(name: "a", type: -4, tag: 1), .init(name: "b", type: -4, tag: 1)])])
    var badArrayFlag = textSchema; badArrayFlag[badArrayFlag.count - 2] = 2
    for invalid in [repeatedTag, badArrayFlag] {
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: invalid, message: message)))
    }
    let floats = schema([.init(name: "Message", fields: [.init(name: "value", type: -5, tag: 1)])])
    for bits: [UInt8] in [[255,0,0,0], [255,0,0,128]] { // +infinity and NaN after Kiwi bit rotation
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: floats, message: Data([1] + bits + [0]))))
    }
  }

  func testSchemaDescribedUnknownFieldsSparseTagsEnumsAndStructsRemainAvailable() throws {
    let definitions: [Definition] = [
      .init(name: "Message", fields: [.init(name: "futureThing", type: 2, tag: 912), .init(name: "kind", type: 1, tag: 3)]),
      .init(name: "Kind", kind: 0, fields: [.init(name: "RECTANGLE", type: 0, tag: 7)]),
      .init(name: "Pair", kind: 1, fields: [.init(name: "x", type: -4, tag: 0), .init(name: "y", type: -3, tag: 0)]),
    ]
    let message = Data(uint(912) + [42, 5, 3, 7, 0])
    let result = try FigmaClipboardDecoder.decode(container: container(schema: schema(definitions), message: message))
    XCTAssertEqual(result.message["futureThing"]?["x"], .uint(42))
    XCTAssertEqual(result.message["futureThing"]?["y"], .int(-3))
    XCTAssertEqual(result.message["kind"], .string("RECTANGLE"))
    let unknown = Data([3, 99, 0])
    let other = try FigmaClipboardDecoder.decode(container: container(schema: schema(definitions), message: unknown))
    XCTAssertEqual(other.message["kind"], .uint(99))
  }

  func testFullWidthIntegersKiwiFloatsAndBinaryArraysAreLossless() throws {
    let definitions = [Definition(name: "Message", fields: [
      .init(name: "unsigned", type: -8, tag: 1), .init(name: "signed", type: -7, tag: 2),
      .init(name: "fraction", type: -5, tag: 3), .init(name: "bytes", type: -2, array: true, tag: 4),
    ])]
    // UInt64.max and Int64.min both encode as nine 0xff bytes in Kiwi.
    // 1.5f32 = 0x3fc00000; Kiwi rotates its exponent into the low byte -> 0x8000007f.
    let data = Data([1] + Array(repeating: 255, count: 9) + [2] + Array(repeating: 255, count: 9)
      + [3, 0x7F, 0, 0, 0x80, 4, 4, 0, 127, 128, 255, 0])
    let result = try FigmaClipboardDecoder.decode(container: container(schema: schema(definitions), message: data))
    XCTAssertEqual(result.message["unsigned"], .uint(UInt64.max))
    XCTAssertEqual(result.message["signed"], .int(Int64.min))
    XCTAssertEqual(result.message["fraction"], .double(1.5))
    XCTAssertEqual(result.message["bytes"], .data(Data([0, 127, 128, 255])))
    let encoded = try result.message.encodedJSON()
    XCTAssertEqual(try JSONDecoder().decode(FigmaValue.self, from: encoded), result.message)
    XCTAssertEqual(try result.message.encodedJSON(), encoded)
  }

  func testMalformedEnvelopeBase64AndMetadataAreRejected() throws {
    let valid = container(schema: textSchema, message: Data([0]))
    for text in ["plain text", "(figma)@@@(/figma)(figmeta)e30=(/figmeta)",
      html(valid, meta: "[]"), html(valid, meta: "{broken"), html(valid) + html(valid)] {
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(html: text))
    }
  }

  func testTruncatedContainerChunksAndTrailingBytesAreRejected() throws {
    let valid = container(schema: textSchema, message: Data([0]))
    for length in [0, 7, 8, 11, 12, 15, valid.count - 1] {
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: valid.prefix(length)))
    }
    var enormous = Data("fig-kiwi".utf8) + Data(u32(101)); enormous += Data(u32(UInt32.max)) + Data([0])
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: enormous))
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: valid + Data([0])))
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(chunks: [rawDeflate(textSchema)])))
  }

  func testTruncatedAndTrailingCompressedDataAreRejectedForBothCodecs() throws {
    for compressed in [rawDeflate(Data([0])), zstdRaw(Data([0]))] {
      for invalid in [Data(compressed.dropLast()), compressed + Data([0x7F])] {
        XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(chunks: [rawDeflate(textSchema), invalid])))
      }
    }
  }

  func testDecompressionBudgetStopsTinyZstdExpansionBeforeItBecomesAScene() throws {
    var limits = FigmaClipboardLimits(); limits.decodedBytes = 2048
    let input = container(chunks: [rawDeflate(textSchema), zstdRLE(count: 65536, value: 0)])
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: input, limits: limits))
  }

  func testRawDeflateAndSchemaExpansionBudgetsAreEnforced() throws {
    var limits = FigmaClipboardLimits(); limits.decodedBytes = 8
    let input = container(schema: textSchema, message: Data([1] + string("more than eight") + [0]))
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: input, limits: limits))
    limits = .init(); limits.schemaBytes = textSchema.count - 1
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: input, limits: limits))
  }

  func testInvalidSchemaTypeReferencesDuplicateNamesAndNoMessageRootAreRejected() throws {
    let definitions: [[Definition]] = [
      [.init(name: "Message", fields: [.init(name: "bad", type: 999, tag: 1)])],
      [.init(name: "Message", fields: [.init(name: "bad", type: -9, tag: 1)])],
      [.init(name: "Message", fields: [.init(name: "x", type: -4, tag: 1), .init(name: "x", type: -4, tag: 2)])],
      [.init(name: "Message", fields: [.init(name: "x", type: -4, tag: 0)])],
      [.init(name: "Message", fields: []), .init(name: "Message", fields: [])],
      [.init(name: "Other", fields: [])],
    ]
    for definitions in definitions {
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: schema(definitions), message: Data([0]))))
    }
  }

  func testInvalidMessagesAndUnicodeFailWithoutReturningPartialData() throws {
    for message in [Data([2, 0]), Data([1, 65]), Data([1, 0xC3, 0x28, 0, 0]),
      Data([1, 65, 0, 1, 66, 0, 0]), Data([0, 99])] {
      XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: textSchema, message: message)))
    }
    let intSchema = schema([.init(name: "Message", fields: [.init(name: "x", type: -4, tag: 1)])])
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: intSchema, message: Data([1, 255, 255, 255, 255, 31, 0]))))
  }

  func testRecursiveSchemaAndNestedMessagesRespectDepthLimit() throws {
    let recursive = schema([.init(name: "Message", fields: [.init(name: "child", type: 0, tag: 1)])])
    var limits = FigmaClipboardLimits(); limits.depth = 8
    let message = Data(Array(repeating: UInt8(1), count: 10) + Array(repeating: UInt8(0), count: 11))
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: recursive, message: message), limits: limits))
    // A recursive struct consumes no message tag, so the depth guard must also
    // stop schemas that recurse without advancing their input cursor.
    let structCycle = schema([.init(name: "Message", fields: [.init(name: "cycle", type: 1, tag: 1)]),
      .init(name: "Loop", kind: 1, fields: [.init(name: "again", type: 1, tag: 0)])])
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: container(schema: structCycle, message: Data([1, 0])), limits: limits))
  }

  func testArrayValueWorkStringAndEnvelopeBudgetsAreIndependent() throws {
    let arrays = schema([.init(name: "Message", fields: [.init(name: "items", type: -4, array: true, tag: 1)])])
    let input = container(schema: arrays, message: Data([1] + uint(UInt32.max) + [0]))
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: input))
    let strings = container(schema: textSchema, message: Data([1] + string(String(repeating: "a", count: 80)) + [0]))
    var limits = FigmaClipboardLimits(); limits.stringBytes = 20
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: strings, limits: limits))
    limits = .init(); limits.work = 2
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: strings, limits: limits))
    limits = .init(); limits.values = 1
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(container: strings, limits: limits))
    limits = .init(); limits.inputBytes = 20
    XCTAssertThrowsError(try FigmaClipboardDecoder.decode(html: html(strings), limits: limits))
  }

  func testAlreadyCancelledTaskStopsBeforeDecoding() async throws {
    let input = container(schema: textSchema, message: Data([0]))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try FigmaClipboardDecoder.decode(container: input)
    }
    do { _ = try await task.value; XCTFail("Cancelled decode succeeded") }
    catch is CancellationError {} catch { XCTFail("Wrong cancellation error: \(error)") }
  }
}
