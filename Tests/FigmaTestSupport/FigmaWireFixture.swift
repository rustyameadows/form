import Foundation

/// Test-only, independent wire writer. No production encoder/decoder is used.
/// Field tags and enum values are a small subset of this pinned primary schema:
/// https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/src/fig/schema/fig.kiwi
public indirect enum FigmaWireValue {
  case uint(UInt32), float(Float), string(String), bool(Bool), object([String: FigmaWireValue]), array([FigmaWireValue]), data(Data)
}

public enum FigmaWireFixture {
  private struct Field {
    let name: String, type: String, tag: UInt32, array: Bool
    init(_ name: String, _ type: String, _ tag: UInt32 = 0, array: Bool = false) {
      self.name = name; self.type = type; self.tag = tag; self.array = array
    }
  }
  private struct Definition {
    let name: String, kind: UInt8, fields: [Field]
    init(_ name: String, _ kind: UInt8, _ fields: [Field]) { self.name = name; self.kind = kind; self.fields = fields }
  }
  private static func enumeration(_ name: String, _ entries: [(String, UInt32)]) -> Definition {
    .init(name, 0, entries.map { .init($0.0, "uint", $0.1) })
  }
  private static let definitions: [Definition] = [
    .init("Message", 2, [.init("type", "MessageType", 1), .init("nodeChanges", "NodeChange", 4, array: true), .init("blobs", "Blob", 6, array: true)]),
    enumeration("MessageType", [("NODE_CHANGES", 1)]),
    .init("NodeChange", 2, [
      .init("guid", "GUID", 1), .init("phase", "NodePhase", 2), .init("parentIndex", "ParentIndex", 3),
      .init("type", "NodeType", 4), .init("name", "string", 5), .init("visible", "bool", 6),
      .init("opacity", "float", 8), .init("blendMode", "BlendMode", 9), .init("size", "Vector", 11), .init("transform", "Matrix", 12),
      .init("mask", "bool", 16), .init("cornerRadius", "float", 20),
      .init("fontSize", "float", 21), .init("paragraphSpacing", "float", 23), .init("strokeWeight", "float", 26), .init("strokeAlign", "StrokeAlign", 29),
      .init("textAlignHorizontal", "TextAlignHorizontal", 32), .init("textAlignVertical", "TextAlignVertical", 33),
      .init("textDecoration", "TextDecoration", 35), .init("fillPaints", "Paint", 38, array: true),
      .init("strokePaints", "Paint", 39, array: true), .init("lineHeight", "Number", 40), .init("fontName", "FontName", 41),
      .init("textData", "TextData", 42), .init("effects", "Effect", 43, array:true), .init("textAutoResize", "TextAutoResize", 46), .init("styleID", "uint", 49),
      .init("fillGeometry", "Path", 51, array: true), .init("symbolData", "SymbolData", 113),
      .init("frameMaskDisabled", "bool", 115), .init("resizeToFit", "bool", 117), .init("internalOnly", "bool", 142),
      .init("letterSpacing", "Number", 165), .init("maskType", "MaskType", 317),
    ]),
    .init("GUID", 1, [.init("sessionID", "uint"), .init("localID", "uint")]),
    .init("ParentIndex", 1, [.init("guid", "GUID"), .init("position", "string")]),
    enumeration("NodeType", [("DOCUMENT", 1), ("CANVAS", 2), ("FRAME", 4), ("VECTOR", 6), ("LINE", 8), ("ELLIPSE", 9), ("RECTANGLE", 10), ("TEXT", 13), ("SYMBOL", 15), ("INSTANCE", 16)]),
    .init("Vector", 1, [.init("x", "float"), .init("y", "float")]),
    .init("Matrix", 1, [.init("m00", "float"), .init("m01", "float"), .init("m02", "float"), .init("m10", "float"), .init("m11", "float"), .init("m12", "float")]),
    .init("Color", 1, [.init("r", "float"), .init("g", "float"), .init("b", "float"), .init("a", "float")]),
    .init("Paint", 2, [.init("type", "PaintType", 1), .init("color", "Color", 2), .init("opacity", "float", 3), .init("visible", "bool", 4),
      .init("blendMode", "BlendMode", 5), .init("stops", "ColorStop", 6, array: true), .init("transform", "Matrix", 7), .init("image", "Image", 8), .init("imageScaleMode", "ImageScaleMode", 10)]),
    enumeration("PaintType", [("SOLID", 0), ("GRADIENT_LINEAR", 1), ("GRADIENT_RADIAL", 2), ("GRADIENT_ANGULAR", 3), ("GRADIENT_DIAMOND", 4), ("IMAGE", 5)]),
    enumeration("BlendMode", [("PASS_THROUGH",0),("NORMAL",1),("MULTIPLY",3),("SCREEN",7)]),
    enumeration("StrokeAlign", [("CENTER",0),("INSIDE",1),("OUTSIDE",2)]),
    enumeration("EffectType", [("INNER_SHADOW",0),("DROP_SHADOW",1),("FOREGROUND_BLUR",2)]),
    .init("Effect",2,[.init("type","EffectType",1),.init("color","Color",2),.init("offset","Vector",3),.init("radius","float",4),
      .init("visible","bool",5),.init("blendMode","BlendMode",6),.init("spread","float",7),.init("showShadowBehindNode","bool",8)]),
    .init("TextData", 2, [.init("characters", "string", 1), .init("characterStyleIDs", "uint", 2, array: true),
      .init("styleOverrideTable", "NodeChange", 3, array: true), .init("lines", "TextLineData", 12, array: true)]),
    .init("FontName", 1, [.init("family", "string"), .init("style", "string"), .init("postscript", "string")]),
    .init("Number", 1, [.init("value", "float"), .init("units", "NumberUnits")]),
    enumeration("NumberUnits", [("RAW", 0), ("PIXELS", 1), ("PERCENT", 2)]),
    enumeration("TextAlignHorizontal", [("LEFT", 0), ("CENTER", 1), ("RIGHT", 2), ("JUSTIFIED", 3)]),
    enumeration("TextAlignVertical", [("TOP", 0), ("CENTER", 1), ("BOTTOM", 2)]),
    enumeration("TextAutoResize", [("NONE", 0), ("WIDTH_AND_HEIGHT", 1), ("HEIGHT", 2)]),
    enumeration("NodePhase", [("CREATED", 0), ("REMOVED", 1)]),
    enumeration("TextDecoration", [("NONE", 0), ("UNDERLINE", 1), ("STRIKETHROUGH", 2)]),
    .init("TextLineData", 2, [.init("lineType", "LineType", 1), .init("styleId", "int", 10), .init("sourceDirectionality", "SourceDirectionality", 9)]),
    enumeration("LineType", [("PLAIN", 0)]),
    enumeration("SourceDirectionality", [("AUTO", 0), ("LTR", 1), ("RTL", 2)]),
    .init("Blob", 1, [.init("bytes", "byte", array: true)]),
    .init("ColorStop", 1, [.init("color", "Color"), .init("position", "float")]),
    .init("Image", 2, [.init("dataBlob", "uint", 3)]),
    enumeration("ImageScaleMode", [("STRETCH", 0), ("FIT", 1), ("FILL", 2)]),
    .init("Path", 2, [.init("windingRule", "WindingRule", 1), .init("commandsBlob", "uint", 2)]),
    enumeration("WindingRule", [("NONZERO", 0), ("ODD", 1)]),
    .init("SymbolData", 2, [.init("symbolID", "GUID", 1)]),
    enumeration("MaskType", [("ALPHA", 0), ("OUTLINE", 1), ("LUMINANCE", 2)]),
  ]
  private static let primitives: [String: Int32] = ["bool": -1, "byte": -2, "int": -3, "uint": -4, "float": -5, "string": -6]
  private static func uint(_ input: UInt32) -> [UInt8] {
    var value = input, result: [UInt8] = []
    repeat { let low = UInt8(value & 127); value >>= 7; result.append(low | (value == 0 ? 0 : 128)) } while value != 0
    return result
  }
  private static func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  private static func text(_ value: String) -> [UInt8] { Array(value.utf8) + [0] }
  private static func encodedSchema() -> Data {
    var result = uint(UInt32(definitions.count))
    for definition in definitions {
      result += text(definition.name) + [definition.kind] + uint(UInt32(definition.fields.count))
      for field in definition.fields {
        let type = primitives[field.type] ?? Int32(definitions.firstIndex { $0.name == field.type }!)
        result += text(field.name) + uint(UInt32(bitPattern: (type &<< 1) ^ (type >> 31)))
          + [field.array ? 1 : 0] + uint(field.tag)
      }
    }
    return Data(result)
  }
  private static func write(_ value: FigmaWireValue, type: String, into result: inout [UInt8]) {
    switch (type, value) {
    case ("uint", .uint(let value)): result += uint(value)
    case ("int", .uint(let value)): result += uint(value << 1)
    case ("float", .float(let value)):
      let bits = value.bitPattern, rotated = bits >> 23 | bits << 9
      result += rotated & 255 == 0 ? [0] : u32(rotated)
    case ("string", .string(let value)): result += text(value)
    case ("bool", .bool(let value)): result.append(value ? 1 : 0)
    default:
      let definition = definitions.first { $0.name == type }!
      if definition.kind == 0 {
        guard case .string(let name) = value else { preconditionFailure("Expected enum") }
        result += uint(definition.fields.first { $0.name == name }!.tag)
      } else {
        guard case .object(let fields) = value else { preconditionFailure("Expected fields") }
        for field in definition.fields {
          guard let value = fields[field.name] else { precondition(definition.kind != 1, "Missing struct field"); continue }
          if definition.kind == 2 { result += uint(field.tag) }
          if field.array {
            if field.type == "byte", case .data(let bytes) = value {
              result += uint(UInt32(bytes.count)); result += bytes; continue
            }
            guard case .array(let values) = value else { preconditionFailure("Expected array") }
            result += uint(UInt32(values.count))
            for value in values { write(value, type: field.type, into: &result) }
          } else { write(value, type: field.type, into: &result) }
        }
        if definition.kind == 2 { result.append(0) }
      }
    }
  }
  private static func storedDeflate(_ data: Data) -> Data {
    let bytes = Array(data); var result = Data(), offset = 0
    repeat {
      let count = min(65535, bytes.count - offset), length = UInt16(count)
      result.append(contentsOf: [offset + count == bytes.count ? 1 : 0,
        UInt8(truncatingIfNeeded: length), UInt8(length >> 8), UInt8(truncatingIfNeeded: ~length), UInt8((~length) >> 8)])
      result.append(contentsOf: bytes[offset..<(offset + count)]); offset += count
    } while offset < bytes.count
    return result
  }
  public static func html(nodes: [[String: FigmaWireValue]], blobs: [Data] = []) -> String {
    var message: [UInt8] = []
    var fields: [String: FigmaWireValue] = ["type": .string("NODE_CHANGES"), "nodeChanges": .array(nodes.map(FigmaWireValue.object))]
    if !blobs.isEmpty { fields["blobs"] = .array(blobs.map { .object(["bytes": .data($0)]) }) }
    write(.object(fields), type: "Message", into: &message)
    let chunks = [storedDeflate(encodedSchema()), storedDeflate(Data(message))]
    var binary = Data("fig-kiwi".utf8) + Data(u32(101))
    for chunk in chunks { binary.append(contentsOf: u32(UInt32(chunk.count))); binary.append(chunk) }
    let meta = Data("{\"fileKey\":\"synthetic-lab-fixture\",\"pasteID\":1,\"dataType\":\"scene\"}".utf8).base64EncodedString()
    return "<meta charset=\"utf-8\"><span data-metadata=\"<!--(figmeta)\(meta)(/figmeta)-->\"></span><span data-buffer=\"<!--(figma)\(binary.base64EncodedString())(/figma)-->\"></span>"
  }

  public static func node(id: UInt32, parent: UInt32?, type: String, name: String,
    x: Float = 0, y: Float = 0, width: Float = 30, height: Float = 20) -> [String: FigmaWireValue] {
    var value: [String: FigmaWireValue] = ["guid": guid(id), "phase": .string("CREATED"), "type": .string(type), "name": .string(name),
      "size": .object(["x": .float(width), "y": .float(height)]), "visible": .bool(true),
      "transform": .object(["m00": .float(1), "m01": .float(0), "m02": .float(x), "m10": .float(0), "m11": .float(1), "m12": .float(y)])]
    if let parent { value["parentIndex"] = .object(["guid": guid(parent), "position": .string(String(format: "%08u", id))]) }
    return value
  }
  public static func guid(_ id: UInt32) -> FigmaWireValue { .object(["sessionID": .uint(7), "localID": .uint(id)]) }
  public static func solid(_ r: Float, _ g: Float, _ b: Float) -> FigmaWireValue {
    .object(["type": .string("SOLID"), "visible": .bool(true), "opacity": .float(1),
      "color": .object(["r": .float(r), "g": .float(g), "b": .float(b), "a": .float(1)])])
  }
  public static func sampleText(id: UInt32, parent: UInt32?, name: String = "Unicode specimen", x: Float = 0, y: Float = 0) -> [String: FigmaWireValue] {
    var value = node(id: id, parent: parent, type: "TEXT", name: name, x: x, y: y, width: 240, height: 72)
    value["fontName"] = .object(["family": .string("Helvetica"), "style": .string("Regular"), "postscript": .string("Helvetica")])
    value["fontSize"] = .float(16); value["lineHeight"] = .object(["value": .float(1.5), "units": .string("RAW")])
    value["letterSpacing"] = .object(["value": .float(10), "units": .string("PERCENT")])
    value["textAutoResize"] = .string("NONE"); value["fillPaints"] = .array([solid(0.1, 0.2, 0.3)])
    value["textData"] = .object(["characters": .string("A😀\nאב"), "characterStyleIDs": .array([.uint(0), .uint(2), .uint(2)]),
      "styleOverrideTable": .array([.object(["styleID": .uint(2), "fontSize": .float(32), "textDecoration": .string("UNDERLINE"), "fillPaints": .array([solid(1, 0, 0)])]),
        .object(["styleID": .uint(9), "paragraphSpacing": .float(12), "textAlignHorizontal": .string("RIGHT")])]),
      "lines": .array([.object(["lineType": .string("PLAIN"), "sourceDirectionality": .string("AUTO")]),
        .object(["lineType": .string("PLAIN"), "styleId": .uint(9), "sourceDirectionality": .string("RTL")])])])
    return value
  }

  /// 25 independently placed frames, each with one nested group, 48 colored
  /// shapes and ten editable labels: exactly 1500 visible source nodes.
  public static func denseNodes(cards: Int = 25) -> [[String: FigmaWireValue]] {
    var nodes = [node(id: 1, parent: nil, type: "DOCUMENT", name: "Synthetic document"),
      node(id: 2, parent: 1, type: "CANVAS", name: "Synthetic page")]
    for card in 0..<cards {
      let first = UInt32(100 + card * 60)
      var frame = node(id: first, parent: 2, type: "FRAME", name: "Card \(card)", x: Float(card % 5) * 340, y: Float(card / 5) * 260, width: 320, height: 240)
      frame["frameMaskDisabled"] = .bool(true); frame["fillPaints"] = .array([solid(0.95, 0.96, 0.98)])
      nodes.append(frame)
      var group = node(id: first + 1, parent: first, type: "FRAME", name: "Contents \(card)", x: 12, y: 24, width: 296, height: 208)
      group["resizeToFit"] = .bool(true); nodes.append(group)
      for index in 0..<48 {
        var shape = node(id: first + 2 + UInt32(index), parent: first + 1,
          type: index % 3 == 0 ? "ELLIPSE" : "RECTANGLE", name: "Tile \(card).\(index)",
          x: Float(index % 8) * 35, y: Float(index / 8) * 24, width: 28, height: 18)
        shape["fillPaints"] = .array([solid(Float(index % 5) / 6 + 0.1, Float(card % 5) / 6 + 0.1, 0.6)])
        nodes.append(shape)
      }
      for index in 0..<10 {
        var text = sampleText(id: first + 50 + UInt32(index), parent: first + 1, name: "Label \(card).\(index)",
          x: Float(index % 5) * 58, y: 150 + Float(index / 5) * 24)
        if card != 0 || index != 0 {
          text["textData"] = .object(["characters": .string("\(card + 1).\(index + 1)")]); text["fontSize"] = .float(12)
          text["size"] = .object(["x": .float(54), "y": .float(20)])
        }
        nodes.append(text)
      }
    }
    return nodes
  }
}
