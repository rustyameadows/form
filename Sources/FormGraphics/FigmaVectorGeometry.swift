import FormCore
import Foundation

/// Native command/network blobs are little-endian structures, independent of
/// Kiwi's wire number representation. Every read checks its own byte boundary.
struct FigmaGeometryReader {
  let bytes: [UInt8]
  var offset = 0
  init(_ data: Data) { bytes = Array(data) }
  mutating func byte() throws -> UInt8 {
    guard offset < bytes.count else { throw FigmaClipboardError.invalid("Truncated vector blob.") }
    defer { offset += 1 }; return bytes[offset]
  }
  mutating func word() throws -> UInt32 {
    guard offset <= bytes.count - 4 else { throw FigmaClipboardError.invalid("Truncated vector word.") }
    let value = UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
    offset += 4; return value
  }
  mutating func scalar() throws -> Double {
    let value = Double(Float(bitPattern: try word()))
    guard value.isFinite, abs(value) <= 1e8 else { throw FigmaClipboardError.invalid("Invalid vector coordinate.") }
    return value
  }
  mutating func point(_ sx: Double, _ sy: Double) throws -> Point2 {
    .init(try scalar() * sx, try scalar() * sy)
  }
  mutating func count(_ maximum: Int = 200000) throws -> Int {
    let value = Int(try word())
    guard value <= maximum else { throw FigmaClipboardError.limit("vector blob count") }; return value
  }
}

extension FigmaSceneBuilder {
  func commandGeometry(_ data: Data, sx: Double, sy: Double) throws -> [VectorContour] {
    guard data.count <= 8 * 1024 * 1024 else { throw FigmaClipboardError.limit("vector command bytes") }
    var reader = FigmaGeometryReader(data), contours: [VectorContour] = [], nodes: [BezierNode] = []
    var closed = false, count = 0
    func flush() {
      if !nodes.isEmpty { contours.append(.init(nodes, closed: closed)); nodes = []; closed = false }
    }
    while reader.offset < reader.bytes.count {
      count += 1; if count % 256 == 0 { try Task.checkCancellation() }
      guard count <= maximumPathNodes else { throw FigmaClipboardError.limit("vector command count") }
      switch try reader.byte() {
      case 0:
        guard !nodes.isEmpty else { throw FigmaClipboardError.invalid("Vector close without a contour.") }
        if nodes.count > 1, nodes.last!.anchor == nodes.first!.anchor {
          nodes[0].incoming = nodes.last!.incoming; nodes.removeLast()
        }
        closed = true; flush()
      case 1: flush(); nodes.append(.init(try reader.point(sx, sy)))
      case 2:
        guard !nodes.isEmpty else { throw FigmaClipboardError.invalid("Vector line without a start.") }
        nodes.append(.init(try reader.point(sx, sy)))
      case 3:
        guard let last = nodes.last else { throw FigmaClipboardError.invalid("Quadratic curve without a start.") }
        let control = try reader.point(sx, sy), end = try reader.point(sx, sy)
        nodes[nodes.count-1].outgoing = .init(last.anchor.x + (control.x-last.anchor.x)*2/3,
          last.anchor.y + (control.y-last.anchor.y)*2/3)
        nodes.append(.init(end, incoming: .init(end.x + (control.x-end.x)*2/3, end.y + (control.y-end.y)*2/3)))
      case 4:
        guard !nodes.isEmpty else { throw FigmaClipboardError.invalid("Cubic curve without a start.") }
        nodes[nodes.count-1].outgoing = try reader.point(sx, sy)
        let incoming = try reader.point(sx, sy), end = try reader.point(sx, sy)
        nodes.append(.init(end, incoming: incoming))
      default: throw FigmaClipboardError.unsupported("Unknown vector command opcode.")
      }
    }
    flush(); return contours
  }

  func networkGeometry(_ data: Data, sx: Double, sy: Double) throws -> [FigmaVectorShape] {
    struct Segment { var start: Int, end: Int; var outgoing: Point2, incoming: Point2 }
    var r = FigmaGeometryReader(data)
    let vertexCount = try r.count(), segmentCount = try r.count(), regionCount = try r.count(5000)
    guard vertexCount <= (data.count - r.offset) / 12 else { throw FigmaClipboardError.invalid("Truncated vector vertices.") }
    var vertices: [Point2] = []
    for _ in 0..<vertexCount { _ = try r.word(); vertices.append(try r.point(sx, sy)) }
    guard segmentCount <= (data.count - r.offset) / 28 else { throw FigmaClipboardError.invalid("Truncated vector segments.") }
    var segments: [Segment] = []
    for _ in 0..<segmentCount {
      _ = try r.word(); let start = try r.count(), outgoing = try r.point(sx, sy)
      let end = try r.count(), incoming = try r.point(sx, sy)
      guard start < vertexCount, end < vertexCount else { throw FigmaClipboardError.invalid("Vector segment references a missing vertex.") }
      segments.append(.init(start: start, end: end, outgoing: outgoing, incoming: incoming))
    }
    var used = Set<Int>(), result: [FigmaVectorShape] = [], work = 0
    func trace(_ indices: [Int], closed: Bool) throws -> VectorContour {
      guard let firstIndex = indices.first else { throw FigmaClipboardError.invalid("Empty vector region loop.") }
      var current = segments[firstIndex].start
      // Figma lists segment membership, not necessarily segment direction.
      if indices.count > 1 {
        let next = segments[indices[1]], first = segments[firstIndex]
        if next.start != first.end && next.end != first.end { current = first.end }
      }
      let firstVertex = current
      var nodes = [BezierNode(vertices[current])]
      for index in indices {
        work += 1; guard work <= maximumPathNodes else { throw FigmaClipboardError.limit("vector network traversal") }
        let edge = segments[index], forward = edge.start == current
        guard forward || edge.end == current else { throw FigmaClipboardError.invalid("Disconnected vector region loop.") }
        let end = forward ? edge.end : edge.start
        let out = forward ? edge.outgoing : edge.incoming, into = forward ? edge.incoming : edge.outgoing
        if out.x != 0 || out.y != 0 { nodes[nodes.count-1].outgoing = .init(vertices[current].x+out.x, vertices[current].y+out.y) }
        let incoming: Point2? = into.x == 0 && into.y == 0 ? nil : .init(vertices[end].x+into.x, vertices[end].y+into.y)
        nodes.append(.init(vertices[end], incoming: incoming)); current = end; used.insert(index)
      }
      if closed {
        guard current == firstVertex else { throw FigmaClipboardError.invalid("Unclosed vector region loop.") }
        nodes[0].incoming = nodes.last!.incoming; nodes.removeLast()
      }
      return .init(nodes, closed: closed)
    }
    for _ in 0..<regionCount {
      try Task.checkCancellation()
      let styleRule = try r.word(), loops = try r.count(5000)
      var contours: [VectorContour] = []
      for _ in 0..<loops {
        let count = try r.count()
        guard count > 0, count <= (data.count-r.offset)/4 else { throw FigmaClipboardError.invalid("Invalid vector region indices.") }
        var indices: [Int] = []
        for _ in 0..<count { let index = try r.count(); guard index < segments.count else { throw FigmaClipboardError.invalid("Missing region segment.") }; indices.append(index) }
        contours.append(try trace(indices, closed: true))
      }
      result.append(.init(contours: contours, evenOdd: styleRule & 1 == 0, styleID: Int(styleRule >> 1)))
    }
    // Open and branching networks remain editable individual Bézier segments.
    // Filled regions above retain their closed contours and winding rules.
    var open: [VectorContour] = []
    for index in segments.indices where !used.contains(index) { open.append(try trace([index], closed: false)) }
    if !open.isEmpty { result.append(.init(contours: open)) }
    guard r.offset == data.count else { throw FigmaClipboardError.unsupported("Trailing vector network data.") }
    return result
  }

  func vectorShapes(_ node: FigmaValue, id: String, geometry: String = "fillGeometry") throws -> [FigmaVectorShape] {
    if let paths = node[geometry]?.arrayValue, !paths.isEmpty {
      guard paths.count <= 5000 else { throw FigmaClipboardError.limit("vector geometry paths") }
      let sizing=materializedGeometryScale[id] ?? .init(1,1)
      return try paths.map { path in
        .init(contours: try commandGeometry(blob(path["commandsBlob"]), sx: scale*sizing.x, sy: scale*sizing.y),
          evenOdd: ["ODD", "EVENODD"].contains(path["windingRule"]?.stringValue ?? ""),
          styleID: path["styleID"]?.integerValue)
      }
    }
    guard geometry == "fillGeometry", let data = node["vectorData"], data["vectorNetworkBlob"] != nil else { return [] }
    let width = try number(node["size"]?["x"]), height = try number(node["size"]?["y"])
    let nw = try number(data["normalizedSize"]?["x"]), nh = try number(data["normalizedSize"]?["y"])
    return try networkGeometry(blob(data["vectorNetworkBlob"]),
      sx: scale * (nw > 0 && width > 0 ? width/nw : 1), sy: scale * (nh > 0 && height > 0 ? height/nh : 1))
  }
}
