import Foundation

/// A source edge, guarded by both original endpoint UUIDs whenever they are available.
public struct SewingConstructionEdge: Codable, Equatable, Sendable {
  public var edge: Int
  public var edgeID: UUID?
  public var endID: UUID?
  public init(edge: Int, edgeID: UUID? = nil, endID: UUID? = nil) {
    self.edge = edge; self.edgeID = edgeID; self.endID = endID
  }
  public func matches(edge: Int, edgeID: UUID?, endID: UUID?) -> Bool {
    if self.edgeID != nil || self.endID != nil { return self.edgeID == edgeID && self.endID == endID }
    return self.edge == edge
  }
}

public struct SewingConstructionGuide: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case fold, stitch }
  public var id = UUID()
  public var edge: SewingConstructionEdge
  /// Physical millimeters inward from the actual transformed source edge.
  public var offset: Double
  public var kind: Kind
  public var label: String
  public var opening: Double = 0
  public var openingPosition: Double = 0.5
  public init(edge: SewingConstructionEdge, offset: Double, kind: Kind, label: String) {
    self.edge = edge; self.offset = offset; self.kind = kind; self.label = label
  }
}

public struct ResolvedSewingConstructionGuide: Equatable, Sendable {
  public var guide: SewingConstructionGuide
  public var first: Point2
  public var last: Point2
  public var segments: [[Point2]]
  public var opening: [Point2]?
}

extension SewingPatternPiece {
  public var hasConstructionMetadata: Bool {
    unstitchedEdges?.isEmpty == false || constructionGuides?.isEmpty == false
  }
  /// This controls seam eligibility only; physical support pins may still use the boundary.
  public func isUnstitched(edge: Int, edgeID: UUID? = nil, endID: UUID? = nil) -> Bool {
    unstitchedEdges?.contains { $0.matches(edge: edge, edgeID: edgeID, endID: endID) } == true
  }
}

public enum SewingConstructionGuides {
  public static let supported = "Construction boundaries and fold/stitch guides require one sharp, strictly convex straight contour. Curves, holes, concave contours and changed endpoint identities are not approximated."
  private static func sub(_ a: Point2, _ b: Point2) -> Point2 { .init(a.x-b.x,a.y-b.y) }
  private static func dot(_ a: Point2, _ b: Point2) -> Double { a.x*b.x+a.y*b.y }
  private static func cross(_ a: Point2, _ b: Point2) -> Double { a.x*b.y-a.y*b.x }
  private static func reference(_ ref: SewingConstructionEdge, in geometry: SewingPieceGeometry) throws -> Int {
    guard (ref.edgeID == nil) == (ref.endID == nil) else {
      throw FormError.invalid("Construction references need both original edge endpoint UUIDs.")
    }
    return try geometry.edgeIndex(ref.edge, id: ref.edgeID, endID: ref.endID)
  }
  public static func resolve(_ geometry: SewingPieceGeometry) throws -> [ResolvedSewingConstructionGuide] {
    let piece = geometry.piece
    guard piece.hasConstructionMetadata else { return [] }
    guard !geometry.usesGeneralGeometry, geometry.boundaries.count <= 1,
      geometry.sourceEdges.allSatisfy(\.isStraight), geometry.stitch.count <= 64 else {
      throw FormError.invalid(supported)
    }
    let unstitched = piece.unstitchedEdges ?? [], guides = piece.constructionGuides ?? []
    guard unstitched.count <= geometry.edgeLengths.count, guides.count <= 32,
      Set(guides.map(\.id)).count == guides.count else {
      throw FormError.invalid("Use at most one construction-boundary record per edge and up to 32 distinct guides.")
    }
    var boundaryIndices = Set<Int>()
    for ref in unstitched {
      let index = try reference(ref, in: geometry)
      guard boundaryIndices.insert(index).inserted, piece.allowance(for: index) == 0,
        index != piece.onFoldEdge else {
        throw FormError.invalid("An unstitched raw construction boundary needs zero allowance and cannot also be a cut-on-fold edge.")
      }
    }
    let cut = SewingPatternDrawing.cutContour(geometry)
    guard cut.count <= 2048 else { throw FormError.invalid("Construction guides exceed the bounded cut-contour limit.") }
    return try guides.map { guide in
      let index = try reference(guide.edge, in: geometry)
      guard guide.offset.isFinite, (0.1...2000).contains(guide.offset), guide.opening.isFinite,
        (0...200).contains(guide.opening), guide.openingPosition.isFinite,
        (0...1).contains(guide.openingPosition), !guide.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        guide.label.count <= 160, guide.kind == .stitch || guide.opening == 0 else {
        throw FormError.invalid("Use named guides, finite 0.1–2000 mm inward offsets, and optional 0–200 mm openings on stitching guides.")
      }
      let start = geometry.stitch[index], end = geometry.stitch[(index+1)%geometry.stitch.count]
      let length = geometry.edgeLengths[index]
      let tangent = Point2((end.x-start.x)/length,(end.y-start.y)/length)
      let outward = geometry.normals[index]
      let origin = Point2(start.x-outward.x*guide.offset,start.y-outward.y*guide.offset)
      var distances: [Double] = []
      for i in cut.indices {
        let a = cut[i], b = cut[(i+1)%cut.count]
        let da = dot(sub(a,origin),outward), db = dot(sub(b,origin),outward)
        if abs(da)<1e-7 && abs(db)<1e-7 {
          throw FormError.invalid("A construction guide overlaps a cut edge. Move it strictly inside the piece.")
        }
        if abs(da)<1e-7 { distances.append(dot(sub(a,origin),tangent)) }
        if (da < -1e-7 && db > 1e-7) || (da > 1e-7 && db < -1e-7) {
          let fraction = da/(da-db)
          let point = Point2(a.x+(b.x-a.x)*fraction,a.y+(b.y-a.y)*fraction)
          distances.append(dot(sub(point,origin),tangent))
        }
      }
      distances.sort()
      var unique: [Double] = []
      for value in distances where unique.last.map({ abs(value-$0)>1e-6 }) ?? true { unique.append(value) }
      guard unique.count == 2, unique[1]-unique[0] > 0.1,
        unique.allSatisfy({ $0.isFinite && abs($0)<=200000 }) else {
        throw FormError.invalid("The construction guide needs one unambiguous material span. It misses the cut contour or crosses notch/topology boundaries; move it explicitly.")
      }
      func point(_ distance: Double) -> Point2 { .init(origin.x+tangent.x*distance,origin.y+tangent.y*distance) }
      let first = point(unique[0]), last = point(unique[1]), span = unique[1]-unique[0]
      if guide.opening > 0 {
        let center = unique[0]+span*guide.openingPosition
        let a = center-guide.opening/2, b = center+guide.opening/2
        guard a > unique[0]+1, b < unique[1]-1 else {
          throw FormError.invalid("Keep a stitching opening at least 1 mm away from both guide ends.")
        }
        let opening = [point(a),point(b)]
        return .init(guide:guide,first:first,last:last,segments:[[first,opening[0]],[opening[1],last]],opening:opening)
      }
      return .init(guide:guide,first:first,last:last,segments:[[first,last]],opening:nil)
    }
  }
}
