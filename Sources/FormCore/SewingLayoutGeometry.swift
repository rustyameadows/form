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
  /// Sewing and independently cut assemblies use the same exact material
  /// contour kernel. Fold/quantity/source semantics remain with SewingLayouts.
  public static func separation(_ a: SewingLayoutResolvedPlacement, _ b: SewingLayoutResolvedPlacement,
    required: Double, comparisons: inout Int) throws -> (overlaps: Bool, distance: Double) {
    try MaterialContourGeometry.separation(a.materialContours,b.materialContours,required:required,
      comparisons:&comparisons,maximumComparisons:SewingLayoutLimits.maximumSegmentComparisons)
  }
}
