import Foundation

public struct SewingNotch: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var edge: Int
  public var edgeID: UUID?
  public var endID: UUID?
  public var position: Double
  public var width = 3.0
  public var depth = 3.0
  public init(edge: Int, position: Double) { self.edge = edge; self.position = position }
  private enum CodingKeys: String, CodingKey { case id, edge, edgeID, endID, position, width, depth }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    edgeID = try c.decodeIfPresent(UUID.self, forKey: .edgeID)
    endID = try c.decodeIfPresent(UUID.self, forKey: .endID)
    edge = try c.decode(Int.self, forKey: .edge); position = try c.decode(Double.self, forKey: .position)
    width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 3; depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? 3
  }
}

/// The editable closed layer is the finished stitch outline. Allowances are physical millimeters.
public struct SewingPatternPiece: Codable, Equatable, Sendable {
  public var name: String
  public var seamAllowance = 10.0
  public var edgeAllowances: [Int: Double] = [:]
  public var materialID: String?
  public var cutQuantity = 1
  public var grainAngle = 90.0
  public var onFoldEdge: Int?
  public var onFoldEdgeID: UUID?
  public var onFoldEndID: UUID?
  public var notches: [SewingNotch] = []
  public var notes: String?
  public init(name: String) { self.name = name }
  private enum CodingKeys: String, CodingKey { case name, seamAllowance, edgeAllowances, materialID, cutQuantity, grainAngle, onFoldEdge, onFoldEdgeID, onFoldEndID, notches, notes }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    seamAllowance = try c.decodeIfPresent(Double.self, forKey: .seamAllowance) ?? 10
    edgeAllowances = try c.decodeIfPresent([Int: Double].self, forKey: .edgeAllowances) ?? [:]
    materialID = try c.decodeIfPresent(String.self, forKey: .materialID)
    cutQuantity = try c.decodeIfPresent(Int.self, forKey: .cutQuantity) ?? 1
    grainAngle = try c.decodeIfPresent(Double.self, forKey: .grainAngle) ?? 90
    onFoldEdge = try c.decodeIfPresent(Int.self, forKey: .onFoldEdge)
    onFoldEdgeID = try c.decodeIfPresent(UUID.self, forKey: .onFoldEdgeID)
    onFoldEndID = try c.decodeIfPresent(UUID.self, forKey: .onFoldEndID)
    notches = try c.decodeIfPresent([SewingNotch].self, forKey: .notches) ?? []
    notes = try c.decodeIfPresent(String.self, forKey: .notes)
  }
  public func allowance(for edge: Int) -> Double { edge == onFoldEdge ? 0 : edgeAllowances[edge] ?? seamAllowance }
}

public struct SewingSeamEnd: Codable, Equatable, Sendable {
  public var elementID: UUID
  public var edge: Int
  public var edgeID: UUID?
  public var endID: UUID?
  public var copy: Int = 1
  public init(elementID: UUID, edge: Int, copy: Int = 1) { self.elementID = elementID; self.edge = edge; self.copy = copy }
  private enum CodingKeys: String, CodingKey { case elementID, edge, edgeID, endID, copy }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    elementID = try c.decode(UUID.self, forKey: .elementID); edge = try c.decode(Int.self, forKey: .edge)
    edgeID = try c.decodeIfPresent(UUID.self, forKey: .edgeID)
    endID = try c.decodeIfPresent(UUID.self, forKey: .endID)
    copy = try c.decodeIfPresent(Int.self, forKey: .copy) ?? 1
  }
}
public struct SewingSeam: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var first: SewingSeamEnd
  public var second: SewingSeamEnd
  public var reversed = true
  public var tolerance = 1.0
  public init(name: String, first: SewingSeamEnd, second: SewingSeamEnd) { self.name = name; self.first = first; self.second = second }
  private enum CodingKeys: String, CodingKey { case id, name, first, second, reversed, tolerance }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); name = try c.decode(String.self, forKey: .name)
    first = try c.decode(SewingSeamEnd.self, forKey: .first); second = try c.decode(SewingSeamEnd.self, forKey: .second)
    reversed = try c.decodeIfPresent(Bool.self, forKey: .reversed) ?? true
    tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? 1
  }
}
public struct SewingSeamDiagnostic: Equatable, Sendable {
  public var seam: SewingSeam
  public var firstLength: Double
  public var secondLength: Double
  public var measurementError = 0.0
  public var isConclusive: Bool { difference + measurementError <= seam.tolerance || difference - measurementError > seam.tolerance }
  public var difference: Double { abs(firstLength - secondLength) }
  public var matches: Bool { difference + measurementError <= seam.tolerance + 1e-8 }
}
public struct SewingPieceGeometry: Equatable, Sendable {
  public var elementID: UUID
  public var piece: SewingPatternPiece
  public var stitch: [Point2]
  public var cut: [Point2]
  public var normals: [Point2]
  public var edgeLengths: [Double]
  public var grainDirection: Point2
  public var boundaries: [SewingBoundary] = []
  public var cutContours: [[Point2]] = []
  public var usesGeneralGeometry: Bool = false
  public var edgeLengthErrors: [Double] = []
  public var cutNotches: [SewingCutNotch] = []
  public var allCutContours: [[Point2]] { cutContours.isEmpty ? [SewingPatternDrawing.cutContour(self)] : cutContours }
  public var allStitchContours: [[Point2]] { boundaries.isEmpty ? [stitch] : boundaries.map(\.points) }
  public var sourceEdges: [SewingBoundaryEdge] { boundaries.flatMap(\.edges) }
  public func edgeIndex(_ legacy: Int, id: UUID?, endID: UUID? = nil) throws -> Int {
    if let id { guard let edge = sourceEdges.first(where: { $0.id == id && (endID == nil || $0.endID == endID) }) else { throw FormError.invalid("A referenced source Bezier edge was removed or split/reversed. Reassign its seam, notch, or fold explicitly.") }; return edge.index }
    guard endID == nil else { throw FormError.invalid("An endpoint guard needs its original source edge UUID.") }
    guard edgeLengths.indices.contains(legacy) else { throw FormError.invalid("A referenced sewing edge no longer exists.") }; return legacy
  }
  public var bounds: Rect2 {
    let points = allStitchContours.flatMap { $0 } + (cutContours.isEmpty ? cut : cutContours.flatMap { $0 }), x = points.map(\.x).min()!, y = points.map(\.y).min()!
    return .init(x, y, points.map(\.x).max()! - x, points.map(\.y).max()! - y)
  }
}

public enum SewingPatterns {
  public static let supportedShapes = "Closed editable Bezier paths with one simple outer contour and up to16 disjoint holes support uniform physical allowances. Existing sharp convex pieces retain per-edge allowances. Curved/concave per-edge overrides, curved folds, masks, live components, and appearance effects require an explicit simpler source."
  private static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
  private static func subtract(_ a: Point2, _ b: Point2) -> Point2 { .init(a.x - b.x, a.y - b.y) }
  private static func dot(_ a: Point2, _ b: Point2) -> Double { a.x * b.x + a.y * b.y }
  private static func vertices(_ e: ArtworkElement) throws -> [Point2] {
    switch e.kind {
    case "rectangle" where (e.cornerRadius ?? 0) == 0:
      return [.init(0, 0), .init(e.width, 0), .init(e.width, e.height), .init(0, e.height)]
    case "polygon":
      let count = e.sides ?? 5
      guard (3...64).contains(count) else { throw FormError.invalid(supportedShapes) }
      return (0..<count).map { index in
        let angle = Double(index) * 2 * .pi / Double(count) - .pi / 2
        return .init(e.width / 2 + cos(angle) * e.width / 2, e.height / 2 + sin(angle) * e.height / 2)
      }
    case "path":
      guard let path = e.path, path.contours.count == 1, let contour = path.contours.first,
        contour.closed, (3...64).contains(contour.nodes.count), path.width > 0, path.height > 0,
        contour.nodes.allSatisfy({ $0.incoming == nil && $0.outgoing == nil }) else { throw FormError.invalid(supportedShapes) }
      return contour.nodes.map { .init($0.anchor.x * e.width / path.width, $0.anchor.y * e.height / path.height) }
    default: throw FormError.invalid(supportedShapes)
    }
  }
  public static func geometry(_ e: ArtworkElement, in art: Artwork) throws -> SewingPieceGeometry {
    guard let piece = e.sewingPiece else { throw FormError.invalid("Select an annotated sewing pattern piece.") }
    var ancestor: ArtworkElement? = e, seen = Set<UUID>()
    let masks = Set(art.elements.compactMap(\.clipID))
    while let item = ancestor {
      guard seen.insert(item.id).inserted, item.clipID == nil, !masks.contains(item.id), item.component == nil,
        item.booleanOperation == nil, !item.hasActiveEffects, (item.opacity ?? 1) == 1,
        item.blendMode == nil || item.blendMode == "normal" else { throw FormError.invalid(supportedShapes) }
      ancestor = item.parentID.flatMap { id in art.elements.first { $0.id == id } }
    }
    if needsGeneralGeometry(e) || piece.onFoldEdgeID != nil || piece.notches.contains(where: { $0.edgeID != nil }) { return try cachedGeneralGeometry(e, in: art) }
    let transform = art.worldTransform(e), points = try vertices(e).map(transform.apply), count = points.count
    let edges = points.indices.map { subtract(points[($0 + 1) % count], points[$0]) }
    let lengths = edges.map { hypot($0.x, $0.y) }, area = points.indices.reduce(0.0) { $0 + cross(points[$1], points[($1 + 1) % count]) } / 2
    guard area.isFinite, abs(area) > 0.01, lengths.allSatisfy({ $0.isFinite && $0 >= 0.1 }),
      points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100000 && abs($0.y) <= 100000 }) else {
      throw FormError.invalid("Pattern pieces need nondegenerate physical edges at least 0.1 mm long.")
    }
    let sign = area > 0 ? 1.0 : -1.0
    guard edges.indices.allSatisfy({ cross(edges[$0], edges[($0 + 1) % count]) * sign > 1e-8 }) else {
      throw FormError.invalid("Pattern allowances currently require convex pieces without collinear corners. " + supportedShapes)
    }
    guard !piece.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, piece.name.count <= 160,
      piece.seamAllowance.isFinite, (0...100).contains(piece.seamAllowance), (1...100).contains(piece.cutQuantity),
      piece.grainAngle.isFinite, abs(piece.grainAngle) <= 36000, (piece.notes?.count ?? 0) <= 2000, (piece.materialID?.count ?? 0) <= 160,
      piece.onFoldEdge == nil || (0..<count).contains(piece.onFoldEdge!),
      piece.edgeAllowances.allSatisfy({ (0..<count).contains($0.key) && $0.value.isFinite && (0...100).contains($0.value) }),
      piece.notches.count <= 128, Set(piece.notches.map(\.id)).count == piece.notches.count else {
      throw FormError.invalid("Use a named piece, 1–100 copies, physical allowances from 0–100 mm, and existing edge numbers.")
    }
    let normals = edges.indices.map { Point2(sign * edges[$0].y / lengths[$0], -sign * edges[$0].x / lengths[$0]) }
    let cut = try points.indices.map { index -> Point2 in
      let previous = (index + count - 1) % count, a = normals[previous], b = normals[index]
      let ka = dot(a, points[index]) + piece.allowance(for: previous), kb = dot(b, points[index]) + piece.allowance(for: index)
      let determinant = cross(a, b)
      let point = Point2((ka * b.y - a.y * kb) / determinant, (a.x * kb - ka * b.x) / determinant)
      guard point.x.isFinite, point.y.isFinite, hypot(point.x - points[index].x, point.y - points[index].y) <= 1000 else {
        throw FormError.invalid("The seam allowance creates an excessive corner. Reduce the allowance or simplify the piece.")
      }
      return point
    }
    for notch in piece.notches {
      guard (0..<count).contains(notch.edge), notch.edge != piece.onFoldEdge, notch.position.isFinite,
        (0...1).contains(notch.position), notch.width.isFinite, (1...10).contains(notch.width),
        notch.depth.isFinite, (0.5...10).contains(notch.depth), notch.depth < piece.allowance(for: notch.edge),
        min(notch.position, 1 - notch.position) * lengths[notch.edge] > notch.width / 2 + 1 else {
        throw FormError.invalid("Notches need space away from corners and a depth smaller than that edge's seam allowance.")
      }
    }
    for edge in points.indices {
      let notches = piece.notches.filter { $0.edge == edge }.sorted { $0.position < $1.position }
      for index in 1..<max(1, notches.count) {
        let a = notches[index - 1], b = notches[index]
        guard (b.position - a.position) * lengths[edge] > (a.width + b.width) / 2 + 1 else {
          throw FormError.invalid("Keep sewing notches separated by at least 1 mm.")
        }
      }
    }
    let radians = piece.grainAngle * .pi / 180
    let grain = Point2(transform.a * cos(radians) + transform.c * sin(radians), transform.b * cos(radians) + transform.d * sin(radians))
    let norm = hypot(grain.x, grain.y)
    return .init(elementID: e.id, piece: piece, stitch: points, cut: cut, normals: normals,
      edgeLengths: lengths, grainDirection: .init(grain.x / norm, grain.y / norm))
  }
  public static func validate(_ art: Artwork) throws {
    guard art.elements.contains(where: { $0.sewingPiece != nil }) || art.sewingSeams?.isEmpty == false else { return }
    var geometry: [UUID: SewingPieceGeometry] = [:]
    for e in art.elements where e.sewingPiece != nil { geometry[e.id] = try self.geometry(e, in: art) }
    let seams = art.sewingSeams ?? []
    guard seams.count <= 500, Set(seams.map(\.id)).count == seams.count else { throw FormError.invalid("A pattern supports up to 500 distinct seams.") }
    for seam in seams {
      guard !seam.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seam.name.count <= 160,
        seam.first != seam.second, seam.tolerance.isFinite, (0...25).contains(seam.tolerance) else { throw FormError.invalid("Name each seam, choose two different piece copies/edges, and use a 0–25 mm tolerance.") }
      for end in [seam.first, seam.second] {
        guard let piece = geometry[end.elementID], let edge = try? piece.edgeIndex(end.edge, id: end.edgeID, endID: end.endID),
          (1...piece.piece.cutQuantity).contains(end.copy), edge != piece.piece.onFoldEdge else {
          throw FormError.invalid("A seam refers to a missing piece, edge, or cut copy. Remove or update that seam first.")
        }
      }
    }
  }
  public static func diagnostics(_ art: Artwork) throws -> [SewingSeamDiagnostic] {
    try validate(art)
    let geometries = try Dictionary(uniqueKeysWithValues: art.elements.filter { $0.sewingPiece != nil }.map { ($0.id, try geometry($0, in: art)) })
    return try (art.sewingSeams ?? []).map { seam in
      let a=geometries[seam.first.elementID]!,b=geometries[seam.second.elementID]!
      let ai=try a.edgeIndex(seam.first.edge,id:seam.first.edgeID,endID:seam.first.endID),bi=try b.edgeIndex(seam.second.edge,id:seam.second.edgeID,endID:seam.second.endID)
      let error=(a.edgeLengthErrors.isEmpty ? 0:a.edgeLengthErrors[ai])+(b.edgeLengthErrors.isEmpty ? 0:b.edgeLengthErrors[bi])
      return .init(seam:seam,firstLength:a.edgeLengths[ai],secondLength:b.edgeLengths[bi],measurementError:error)
    }
  }
}
