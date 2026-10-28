import Foundation

extension SewingPatternDrawing {
  public static func cuttingContours(_ g: SewingPieceGeometry) -> [(points: [Point2], closed: Bool)]
  {
    if !g.usesGeneralGeometry {
      if let fold = g.piece.onFoldEdge {
        return g.cut.indices.filter { $0 != fold }.map { (cutEdgePoints(g, edge: $0), false) }
      }
      return [(cutContour(g), true)]
    }
    guard let fold = g.piece.onFoldEdge, let edge = g.sourceEdges.first(where: { $0.index == fold })
    else { return g.allCutContours.map { ($0, true) } }
    let a = edge.points[0]
    let n = g.normals[fold]
    let p = g.cut
    let isFold = p.indices.map { i in
      let b = p[i]
      let c = p[(i + 1) % p.count]
      return abs((b.x - a.x) * n.x + (b.y - a.y) * n.y) < 0.002
        && abs((c.x - a.x) * n.x + (c.y - a.y) * n.y) < 0.002
    }
    guard let start = isFold.firstIndex(of: true) else { return [(p, true)] }
    var result: [(points: [Point2], closed: Bool)] = []
    var run: [Point2] = []
    for offset in 1...p.count {
      let i = (start + offset) % p.count
      if isFold[i] {
        if run.count > 1 { result.append((run, false)) }
        run = []
      } else {
        if run.isEmpty { run = [p[i]] }
        run.append(p[(i + 1) % p.count])
      }
    }
    if run.count > 1 { result.append((run, false)) }
    return result
  }
  public static func technicalCompoundPath(
    _ contours: [[Point2]], source: UUID, name: String, role: String, color: String
  ) -> ArtworkElement {
    let bounds = SewingLayoutGeometry.bounds(contours.flatMap { $0 })
    var e = technicalPath(
      contours[0], closed: true, source: source, name: name, role: role, color: color)
    e.x = bounds.x
    e.y = bounds.y
    e.width = max(0.1, bounds.width)
    e.height = max(0.1, bounds.height)
    var sequence = 0
    let paths = contours.map { points -> VectorContour in
      let nodes = points.map { point -> BezierNode in
        var node = BezierNode(.init(point.x - bounds.x, point.y - bounds.y))
        sequence += 1
        let seed = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", sequence))!
        node.id = ComponentCommands.derivedID(e.id, seed)
        return node
      }
      return VectorContour(nodes, closed: true)
    }
    e.path = .init(width: e.width, height: e.height, contours: paths, evenOdd: true)
    return e
  }
  static func generalGrain(_ g: SewingPieceGeometry) -> [Point2] {
    let bounds = g.bounds
    let d = g.grainDirection
    var best: [Point2] = []
    var bestLength = 0.0
    for x in [0.25, 0.5, 0.75] {
      for y in [0.25, 0.5, 0.75] {
        let center = Point2(bounds.x + x * bounds.width, bounds.y + y * bounds.height)
        var hits: [Double] = []
        for ring in g.allStitchContours {
          for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            let v = Point2(b.x - a.x, b.y - a.y)
            let q = Point2(a.x - center.x, a.y - center.y)
            let det = d.x * v.y - d.y * v.x
            if abs(det) < 1e-12 { continue }
            let t = (q.x * v.y - q.y * v.x) / det
            let u = (q.x * d.y - q.y * d.x) / det
            if u >= 0 && u < 1 { hits.append(t) }
          }
        }
        hits.sort()
        for i in 1..<max(1, hits.count) {
          let a = hits[i - 1]
          let b = hits[i]
          let mid = Point2(center.x + (a + b) / 2 * d.x, center.y + (a + b) / 2 * d.y)
          if b - a > bestLength && SewingCurves.contains(mid, ring: g.allStitchContours[0])
            && !g.allStitchContours.dropFirst().contains(where: {
              SewingCurves.contains(mid, ring: $0)
            })
          {
            let inset = min(5, (b - a) * 0.15)
            best = [
              .init(center.x + (a + inset) * d.x, center.y + (a + inset) * d.y),
              .init(center.x + (b - inset) * d.x, center.y + (b - inset) * d.y),
            ]
            bestLength = b - a
          }
        }
      }
    }
    return best.isEmpty ? [g.stitch[0], g.stitch[1]] : best
  }
}
