import CFormClipper
import Foundation

/// Source identities and dimensions are independent of derived tessellation and offset ordering.
public struct SewingBoundaryEdge: Equatable, Sendable {
  public var id: UUID?
  public var endID: UUID?
  public var index: Int
  public var contour: Int
  public var points: [Point2]
  public var controls: [Point2]
  public var length: Double
  public var lengthError: Double
  public var isStraight: Bool
  public func sample(fraction: Double) -> SewingBoundarySample {
    let clamped = max(0, min(1, fraction))
    let segments = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
    let total = segments.reduce(0, +)
    let target = total * clamped
    var consumed = 0.0
    for i in segments.indices {
      let n = segments[i]
      if consumed + n >= target || i == segments.count - 1 {
        let t = n > 0 ? max(0, min(1, (target - consumed) / n)) : 0
        let a = points[i]
        let b = points[i + 1]
        return .init(
          edgeID: id, edge: index, contour: contour, fraction: clamped,
          distanceMM: length * clamped,
          point: .init(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t),
          tangent: .init((b.x - a.x) / max(n, 1e-12), (b.y - a.y) / max(n, 1e-12)))
      }
      consumed += n
    }
    return .init(
      edgeID: id, edge: index, contour: contour, fraction: clamped, distanceMM: 0, point: points[0],
      tangent: .init(1, 0))
  }
}
public struct SewingBoundarySample: Equatable, Sendable {
  public var edgeID: UUID?
  public var edge: Int
  public var contour: Int
  public var fraction: Double
  public var distanceMM: Double
  public var point: Point2
  public var tangent: Point2
}
public struct SewingBoundary: Equatable, Sendable {
  /// First original node UUID, stable while that node is retained. No identity uses offset order.
  public var id: UUID?
  public var isHole: Bool
  public var points: [Point2]
  public var edges: [SewingBoundaryEdge]
}
public enum SewingCurveLimits {
  public static let contourToleranceMM = 0.02
  public static let lengthToleranceMM = 0.005
  public static let integerGridMM = 0.001
  public static let maximumSourceEdges = 512
  public static let maximumFlattenedPoints = 8192
  public static let maximumTopologyComparisons = 8_000_000
}

public enum SewingPolygonKernel {
  public static var version: String { String(cString: fc_version()) }
  static func unpack(_ paths: FCPaths) throws -> [[Point2]] {
    defer { fc_free(paths) }
    guard paths.status == 0, paths.count > 0, let counts = paths.counts, let xy = paths.coordinates
    else {
      throw FormError.invalid(
        "The physical allowance collapsed or exceeded the robust offset work limit. Reduce the allowance or simplify the source."
      )
    }
    var at = 0
    var result: [[Point2]] = []
    for i in 0..<Int(paths.count) {
      var points: [Point2] = []
      for _ in 0..<Int(counts[i]) {
        points.append(.init(xy[at], xy[at + 1]))
        at += 2
      }
      result.append(points)
    }
    return result
  }
  public static func offset(_ contours: [[Point2]], distance: Double) throws -> [[Point2]] {
    let counts = contours.map { Int32($0.count) }
    let xy = contours.flatMap { $0.flatMap { [$0.x, $0.y] } }
    return try xy.withUnsafeBufferPointer { c in
      try counts.withUnsafeBufferPointer { n in
        try unpack(
          fc_offset(
            c.baseAddress, n.baseAddress, Int32(n.count), distance,
            SewingCurveLimits.contourToleranceMM / 2))
      }
    }
  }
}

extension SewingPolygonKernel {
  static func boolean(_ subject: [[Point2]], clips: [[Point2]], intersection: Bool = false) throws
    -> [[Point2]]
  {
    let n = subject.map { Int32($0.count) }
    let c = subject.flatMap { $0.flatMap { [$0.x, $0.y] } }
    let cn = clips.map { Int32($0.count) }
    let cc = clips.flatMap { $0.flatMap { [$0.x, $0.y] } }
    return try c.withUnsafeBufferPointer { a in
      try n.withUnsafeBufferPointer { b in
        try cc.withUnsafeBufferPointer { d in
          try cn.withUnsafeBufferPointer { e in
            try unpack(
              fc_boolean(
                a.baseAddress, b.baseAddress, Int32(b.count), d.baseAddress, e.baseAddress,
                Int32(e.count), intersection ? 1 : 0))
          }
        }
      }
    }
  }
}

public enum SewingCurves {
  static func sub(_ a: Point2, _ b: Point2) -> Point2 { .init(a.x - b.x, a.y - b.y) }
  static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
  static func distance(_ a: Point2, _ b: Point2) -> Double { hypot(a.x - b.x, a.y - b.y) }
  static func midpoint(_ a: Point2, _ b: Point2) -> Point2 {
    .init((a.x + b.x) / 2, (a.y + b.y) / 2)
  }
  public static func signedArea(_ p: [Point2]) -> Double {
    p.indices.reduce(0) { $0 + cross(p[$1], p[($1 + 1) % p.count]) } / 2
  }
  static func segmentDistance(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
    let d = sub(b, a)
    let norm = d.x * d.x + d.y * d.y
    guard norm > 1e-20 else { return distance(p, a) }
    let t = max(0, min(1, ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / norm))
    return hypot(p.x - a.x - t * d.x, p.y - a.y - t * d.y)
  }
  public static func contains(_ p: Point2, ring: [Point2]) -> Bool {
    var inside = false
    for i in ring.indices {
      let a = ring[i]
      let b = ring[(i + 1) % ring.count]
      if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
        inside.toggle()
      }
    }
    return inside
  }
  static func intersects(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> Bool {
    let p = cross(sub(b, a), sub(c, a))
    let q = cross(sub(b, a), sub(d, a))
    let r = cross(sub(d, c), sub(a, c))
    let s = cross(sub(d, c), sub(b, c))
    if p * q < 0 && r * s < 0 { return true }
    return abs(p) < 1e-9 && segmentDistance(c, a, b) < 1e-7
      || abs(q) < 1e-9 && segmentDistance(d, a, b) < 1e-7
      || abs(r) < 1e-9 && segmentDistance(a, c, d) < 1e-7
      || abs(s) < 1e-9 && segmentDistance(b, c, d) < 1e-7
  }
  public static func validateTopology(_ rings: [[Point2]]) throws {
    guard (1...17).contains(rings.count),
      rings.reduce(0, { $0 + $1.count }) <= SewingCurveLimits.maximumFlattenedPoints
    else {
      throw FormError.invalid(
        "A sewing piece supports one outer contour, up to 16 holes, and 8192 derived points.")
    }
    var work = 0
    for (ri, p) in rings.enumerated() {
      guard p.count >= 3, abs(signedArea(p)) > 0.01,
        p.allSatisfy({
          $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100000 && abs($0.y) <= 100000
        })
      else {
        throw FormError.invalid("Sewing contours need finite nondegenerate physical geometry.")
      }
      for i in p.indices {
        guard distance(p[i], p[(i + 1) % p.count]) > 0.0005 else {
          throw FormError.invalid(
            "A sewing contour has a collapsed segment at the 0.001 mm geometry grid.")
        }
        for rj in ri..<rings.count {
          let q = rings[rj]
          for j in q.indices {
            if ri == rj && (j <= i || j == i + 1 || i == 0 && j == p.count - 1) { continue }
            work += 1
            guard work <= SewingCurveLimits.maximumTopologyComparisons else {
              throw FormError.invalid(
                "Pattern topology exceeded its validation budget. Simplify the curves or holes.")
            }
            let a = p[i]
            let b = p[(i + 1) % p.count]
            let c = q[j]
            let d = q[(j + 1) % q.count]
            if max(a.x, b.x) + 1e-7 < min(c.x, d.x) || max(c.x, d.x) + 1e-7 < min(a.x, b.x)
              || max(a.y, b.y) + 1e-7 < min(c.y, d.y) || max(c.y, d.y) + 1e-7 < min(a.y, b.y)
            {
              continue
            }
            if intersects(a, b, c, d) {
              throw FormError.invalid(
                "Sewing contours must be simple, disjoint, and free of touching or intersecting boundaries."
              )
            }
          }
        }
      }
      if ri > 0 {
        guard contains(p[0], ring: rings[0]) else {
          throw FormError.invalid("Every hole must lie strictly inside the first outer contour.")
        }
        for j in 1..<ri where contains(p[0], ring: rings[j]) || contains(rings[j][0], ring: p) {
          throw FormError.invalid(
            "Nested holes or separate islands are not supported sewing topology.")
        }
      }
    }
  }
  static func flatten(
    _ p: [Point2], lengthTolerance: Double, depth: Int = 0, points: inout [Point2],
    length: inout Double, error: inout Double
  ) throws {
    let chord = distance(p[0], p[3])
    let polygon = distance(p[0], p[1]) + distance(p[1], p[2]) + distance(p[2], p[3])
    let flat = max(segmentDistance(p[1], p[0], p[3]), segmentDistance(p[2], p[0], p[3]))
    if flat <= SewingCurveLimits.contourToleranceMM && polygon - chord <= 2 * lengthTolerance {
      points.append(p[3])
      length += (polygon + chord) / 2
      error += (polygon - chord) / 2
      guard points.count <= SewingCurveLimits.maximumFlattenedPoints else {
        throw FormError.invalid("Curve exceeds 8192 physical samples. Simplify the source.")
      }
      return
    }
    guard depth < 24 else {
      throw FormError.invalid("A degenerate curve could not meet the physical error tolerance.")
    }
    let a = midpoint(p[0], p[1])
    let b = midpoint(p[1], p[2])
    let c = midpoint(p[2], p[3])
    let d = midpoint(a, b)
    let e = midpoint(b, c)
    let f = midpoint(d, e)
    try flatten(
      [p[0], a, d, f], lengthTolerance: lengthTolerance / 2, depth: depth + 1, points: &points,
      length: &length, error: &error)
    try flatten(
      [f, e, c, p[3]], lengthTolerance: lengthTolerance / 2, depth: depth + 1, points: &points,
      length: &length, error: &error)
  }
  public static func boundaries(_ e: ArtworkElement, in art: Artwork) throws -> [SewingBoundary] {
    guard e.kind == "path", let path = e.path, path.width > 0, path.height > 0,
      path.contours.allSatisfy(\.closed)
    else {
      throw FormError.invalid("General sewing contours must be closed editable Bezier paths.")
    }
    let contourIdentities = path.contours.compactMap(\.id)
    guard Set(contourIdentities).count == contourIdentities.count else {
      throw FormError.invalid("Each manufacturing contour needs a distinct boundary UUID.")
    }
    let total = path.contours.reduce(0, { $0 + $1.nodes.count })
    guard (3...SewingCurveLimits.maximumSourceEdges).contains(total) else {
      throw FormError.invalid("Use 3–512 source edges per sewing piece.")
    }
    let transform = art.worldTransform(e)
    let scale = Affine2(
      a: e.width / path.width, b: 0, c: 0, d: e.height / path.height, tx: 0, ty: 0)
    func world(_ p: Point2) -> Point2 { transform.apply(scale.apply(p)) }
    var result: [SewingBoundary] = []
    var index = 0
    var identities = Set<UUID>()
    for (ci, contour) in path.contours.enumerated() {
      guard contour.nodes.count >= 3 else {
        throw FormError.invalid("Each closed sewing contour needs at least three source edges.")
      }
      var edges: [SewingBoundaryEdge] = []
      var points: [Point2] = []
      for i in contour.nodes.indices {
        let a = contour.nodes[i]
        let b = contour.nodes[(i + 1) % contour.nodes.count]
        guard identities.insert(a.id).inserted else {
          throw FormError.invalid("Source Bezier edge UUIDs must be unique within a sewing piece.")
        }
        let controls = [
          world(a.anchor), world(a.outgoing ?? a.anchor), world(b.incoming ?? b.anchor),
          world(b.anchor),
        ]
        var samples = [controls[0]]
        var length = 0.0
        var error = 0.0
        let straight = a.outgoing == nil && b.incoming == nil
        if straight {
          samples.append(controls[3])
          length = distance(controls[0], controls[3])
        } else {
          try flatten(
            controls, lengthTolerance: SewingCurveLimits.lengthToleranceMM / Double(total),
            points: &samples, length: &length, error: &error)
        }
        guard length >= 0.1, length.isFinite else {
          throw FormError.invalid(
            "Every original sewing edge needs at least 0.1 mm physical arc length.")
        }
        edges.append(
          .init(
            id: a.id, endID: b.id, index: index, contour: ci, points: samples, controls: controls,
            length: length,
            lengthError: error, isStraight: straight))
        index += 1
        points += samples.dropLast()
        let totalPoints = points.count + result.reduce(0) { $0 + $1.points.count }
        guard totalPoints <= SewingCurveLimits.maximumFlattenedPoints else {
          throw FormError.invalid(
            "Pattern curve sampling exceeded8192 physical points. Simplify the source.")
        }
      }
      result.append(
        .init(id: contour.id ?? contour.nodes[0].id, isHole: ci > 0, points: points, edges: edges))
    }
    try validateTopology(result.map(\.points))
    return result
  }
}
