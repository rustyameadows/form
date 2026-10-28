import Foundation

public enum SewingLayoutGeometry {
  static let epsilon = 1e-7
  public static func normalizedAngle(_ degrees: Double) -> Double {
    var value = degrees.truncatingRemainder(dividingBy: 360)
    if value >= 180 { value -= 360 }; if value < -180 { value += 360 }
    return abs(value) < 1e-9 ? 0 : value
  }
  static func subtract(_ a: Point2, _ b: Point2) -> Point2 { .init(a.x - b.x, a.y - b.y) }
  static func dot(_ a: Point2, _ b: Point2) -> Double { a.x * b.x + a.y * b.y }
  static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
  public static func bounds(_ points: [Point2]) -> Rect2 {
    let x = points.map(\.x).min()!, y = points.map(\.y).min()!
    return .init(x, y, points.map(\.x).max()! - x, points.map(\.y).max()! - y)
  }
  public static func area(_ points: [Point2]) -> Double {
    abs(points.indices.reduce(0.0) { $0 + cross(points[$1], points[($1 + 1) % points.count]) }) / 2
  }
  public static func resolve(_ placement: SewingCutPlacement, geometry: SewingPieceGeometry) -> SewingLayoutResolvedPlacement {
    let contour = SewingPatternDrawing.cutContour(geometry)
    let rotation = Affine2.rotation(placement.rotation)
    let rotated = contour.map(rotation.apply), box = bounds(rotated)
    let transform = Affine2.translation(placement.x - box.x, placement.y - box.y).followed(by: rotation)
    let transformed = contour.map(transform.apply)
    let d = geometry.grainDirection
    return .init(placement: placement, geometry: geometry, transform: transform, contour: transformed,
      bounds: bounds(transformed), grainDirection: .init(rotation.a * d.x + rotation.c * d.y, rotation.b * d.x + rotation.d * d.y),
      contours: geometry.allCutContours.map { $0.map(transform.apply) })
  }
  public static func materialArea(_ contours:[[Point2]])->Double {
    guard let outer=contours.first else{return 0};return max(0,area(outer)-contours.dropFirst().reduce(0){$0+area($1)})
  }
  public static func containsMaterial(_ point:Point2,contours:[[Point2]])->Bool {
    guard let outer=contours.first,SewingCurves.contains(point,ring:outer) else{return false}
    return !contours.dropFirst().contains{SewingCurves.contains(point,ring:$0)}
  }
  public static func cuttingPaths(_ p:SewingLayoutResolvedPlacement)->[(points:[Point2],closed:Bool)] {
    if p.geometry.usesGeneralGeometry {return SewingPatternDrawing.cuttingContours(p.geometry).map{($0.points.map(p.transform.apply),$0.closed)}}
    return [cuttingPath(p)]
  }
  public static func cuttingPath(_ placement: SewingLayoutResolvedPlacement) -> (points: [Point2], closed: Bool) {
    if placement.geometry.usesGeneralGeometry { return cuttingPaths(placement)[0] }
    guard let fold = placement.geometry.piece.onFoldEdge else { return (placement.contour, true) }
    let g = placement.geometry
    var points: [Point2] = []
    for offset in 1..<g.cut.count {
      let edge = (fold + offset) % g.cut.count
      let segment = SewingPatternDrawing.cutEdgePoints(g, edge: edge).map(placement.transform.apply)
      points += points.isEmpty ? segment : Array(segment.dropFirst())
    }
    return (points, false)
  }
  public static func grainMatches(_ direction: Point2, rule: SewingCutLayout.Grain) -> Bool {
    if rule == .unrestricted { return true }
    let cosine = cos(Double.pi / 180)
    return rule == .directional ? direction.y >= cosine : abs(direction.y) >= cosine
  }
  public static func rotations(for geometry: SewingPieceGeometry, layout: SewingCutLayout) -> [Double] {
    if let fold = geometry.piece.onFoldEdge {
      guard layout.stock == .foldedPair else { return [] }
      let normal = geometry.normals[fold]
      let angle = normalizedAngle(180 - atan2(normal.y, normal.x) * 180 / Double.pi)
      let rotation = Affine2.rotation(angle), d = geometry.grainDirection
      let grain = Point2(rotation.a * d.x + rotation.c * d.y, rotation.b * d.x + rotation.d * d.y)
      return grainMatches(grain, rule: layout.grain) ? [angle] : []
    }
    if layout.grain == .unrestricted { return [0, 90, -90, -180] }
    let d = geometry.grainDirection, aligned = normalizedAngle(90 - atan2(d.y, d.x) * 180 / Double.pi)
    return layout.grain == .directional ? [aligned] : [aligned, normalizedAngle(aligned + 180)]
  }
  static func aabbDistance(_ a: Rect2, _ b: Rect2) -> Double {
    let dx = max(0, max(a.x - b.maxX, b.x - a.maxX)), dy = max(0, max(a.y - b.maxY, b.y - a.maxY))
    return hypot(dx, dy)
  }
  private static func pointSegmentDistance(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
    let d = subtract(b, a), length = dot(d, d)
    if length <= 1e-20 { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, dot(subtract(p, a), d) / length))
    return hypot(p.x - a.x - t * d.x, p.y - a.y - t * d.y)
  }
  private static func intersects(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> Bool {
    let ab = subtract(b, a), cd = subtract(d, c)
    let ac = subtract(c, a), ad = subtract(d, a), ca = subtract(a, c), cb = subtract(b, c)
    let u = cross(ab, ac), v = cross(ab, ad), w = cross(cd, ca), z = cross(cd, cb)
    if ((u > epsilon && v < -epsilon) || (u < -epsilon && v > epsilon)) &&
      ((w > epsilon && z < -epsilon) || (w < -epsilon && z > epsilon)) { return true }
    return abs(u) <= epsilon && pointSegmentDistance(c, a, b) <= epsilon
      || abs(v) <= epsilon && pointSegmentDistance(d, a, b) <= epsilon
      || abs(w) <= epsilon && pointSegmentDistance(a, c, d) <= epsilon
      || abs(z) <= epsilon && pointSegmentDistance(b, c, d) <= epsilon
  }
  private static func contains(_ point: Point2, polygon: [Point2]) -> Bool {
    var inside = false
    for index in polygon.indices {
      let a = polygon[index], b = polygon[(index + 1) % polygon.count]
      if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
    }
    return inside
  }
  /// Exact simple-polygon intersection/containment and Euclidean segment separation. Bounds are
  /// only an early-out: diagonal empty corners and real V-notch cutouts remain usable geometry.
  public static func separation(_ a: SewingLayoutResolvedPlacement, _ b: SewingLayoutResolvedPlacement,
    required: Double, comparisons: inout Int) throws -> (overlaps: Bool, distance: Double) {
    let broad = aabbDistance(a.bounds, b.bounds)
    if broad + epsilon >= required { return (false, broad) }
    var distance = Double.infinity
    for ap in a.materialContours {for bp in b.materialContours {
      for i in ap.indices { for j in bp.indices {
        comparisons += 1
        guard comparisons <= SewingLayoutLimits.maximumSegmentComparisons else { throw FormError.invalid("Cutting layout exceeded its exact collision-check budget. Reduce the piece count or simplify the contours.") }
        let p=ap[i],q=ap[(i+1)%ap.count],r=bp[j],s=bp[(j+1)%bp.count]
        if intersects(p,q,r,s){return (true,0)}
        distance=min(distance,pointSegmentDistance(p,r,s),pointSegmentDistance(q,r,s),pointSegmentDistance(r,p,q),pointSegmentDistance(s,p,q))
      }}
    }}
    if containsMaterial(a.contour[0],contours:b.materialContours) || containsMaterial(b.contour[0],contours:a.materialContours) {return (true,0)}
    return (false, distance)
  }
}
