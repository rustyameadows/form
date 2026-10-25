import CryptoKit
import Foundation

private final class SewingGeometryCacheValue: NSObject {
  let value: SewingPieceGeometry
  init(_ value: SewingPieceGeometry) { self.value = value }
}
private enum SewingGeometryCache {
  static let values: NSCache<NSString, SewingGeometryCacheValue> = {
    let cache = NSCache<NSString, SewingGeometryCacheValue>()
    cache.countLimit = 128
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
  }()
  struct Key: Codable {
    var element: ArtworkElement
    var world: Affine2
  }
}
extension SewingPatterns {
  static func cachedGeneralGeometry(_ e: ArtworkElement, in art: Artwork) throws
    -> SewingPieceGeometry
  {
    let key =
      SHA256.hash(
        data: try JSONEncoder.form.encode(
          SewingGeometryCache.Key(element: e, world: art.worldTransform(e)))
      ).map { String(format: "%02x", $0) }.joined() as NSString
    if let cached = SewingGeometryCache.values.object(forKey: key) { return cached.value }
    let result = try generalGeometry(e, in: art)
    let points =
      result.allCutContours.reduce(0) { $0 + $1.count }
      + result.allStitchContours.reduce(0) { $0 + $1.count }
    SewingGeometryCache.values.setObject(
      SewingGeometryCacheValue(result), forKey: key, cost: max(1, points) * 64)
    return result
  }

  public static func needsGeneralGeometry(_ e: ArtworkElement) -> Bool {
    guard e.kind == "path", let path = e.path else { return false }
    if path.contours.count != 1 { return true }
    guard let contour = path.contours.first else { return true }
    if contour.nodes.contains(where: { $0.incoming != nil || $0.outgoing != nil }) { return true }
    let p = contour.nodes.map(\.anchor)
    let sign = SewingCurves.signedArea(p) >= 0 ? 1.0 : -1.0
    return p.indices.contains { i in
      SewingCurves.cross(
        SewingCurves.sub(p[(i + 1) % p.count], p[i]),
        SewingCurves.sub(p[(i + 2) % p.count], p[(i + 1) % p.count])) * sign <= 1e-8
    }
  }
  /// References bind to original starting-node identities, never to tessellated cut vertices.
  public static func bindingStableEdges(_ piece: SewingPatternPiece, to e: ArtworkElement) throws
    -> SewingPatternPiece
  {
    guard needsGeneralGeometry(e), let path = e.path else { return piece }
    let edges = path.contours.flatMap(\.nodes)
    let ends = path.contours.flatMap { contour in
      contour.nodes.indices.map { contour.nodes[($0 + 1) % contour.nodes.count].id }
    }
    var next = piece
    for i in next.notches.indices {
      let n = next.notches[i]
      let index = n.edgeID.flatMap { id in edges.firstIndex { $0.id == id } } ?? n.edge
      guard edges.indices.contains(index) else {
        throw FormError.invalid("Choose an existing source edge for each notch.")
      }
      if next.notches[i].edgeID == nil { next.notches[i].edgeID = edges[index].id }
      if next.notches[i].endID == nil { next.notches[i].endID = ends[index] }
    }
    if next.onFoldEdge != nil || next.onFoldEdgeID != nil {
      let index =
        next.onFoldEdgeID.flatMap { id in edges.firstIndex { $0.id == id } } ?? next.onFoldEdge ?? 0
      guard edges.indices.contains(index) else {
        throw FormError.invalid("Choose an existing source edge for the fold.")
      }
      if next.onFoldEdgeID == nil { next.onFoldEdgeID = edges[index].id }
      if next.onFoldEndID == nil { next.onFoldEndID = ends[index] }
    }
    return next
  }
  static func orderedCutContours(_ paths: [[Point2]], source: [SewingBoundary]) throws -> [[Point2]]
  {
    let positive = paths.filter { SewingCurves.signedArea($0) > 0 }
    let negative = paths.filter { SewingCurves.signedArea($0) < 0 }
    guard positive.count == 1, negative.count == source.count - 1 else {
      throw FormError.invalid(
        "This allowance changes the number of material islands or holes. A hole collapsed or an outer gap closed; change the source or allowance explicitly."
      )
    }
    var output = [positive[0]]
    var used = Set<Int>()
    for hole in source.dropFirst() {
      guard
        let index = negative.indices.first(where: {
          !used.contains($0) && SewingCurves.contains(negative[$0][0], ring: hole.points)
        })
      else {
        throw FormError.invalid(
          "The offset changed hole identity or topology. Reduce the allowance.")
      }
      used.insert(index)
      output.append(negative[index])
    }
    try SewingCurves.validateTopology(output)
    return output
  }
  static func generalGeometry(_ e: ArtworkElement, in art: Artwork) throws -> SewingPieceGeometry {
    var piece = e.sewingPiece!
    let boundaries = try SewingCurves.boundaries(e, in: art)
    let edges = boundaries.flatMap(\.edges)
    func index(_ legacy: Int, _ id: UUID?, _ endID: UUID?) throws -> Int {
      if let id {
        guard let edge = edges.first(where: { $0.id == id && (endID == nil || $0.endID == endID) })
        else {
          throw FormError.invalid(
            "A referenced source Bezier edge was removed or split/reversed. Reassign its notch or fold."
          )
        }
        return edge.index
      }
      guard endID == nil else {
        throw FormError.invalid("An endpoint guard needs its original source edge UUID.")
      }
      guard edges.indices.contains(legacy) else {
        throw FormError.invalid("Choose an existing original source edge.")
      }
      return legacy
    }
    guard !piece.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      piece.name.count <= 160,
      piece.seamAllowance.isFinite,
      piece.seamAllowance == 0 || (0.05...100).contains(piece.seamAllowance),
      (1...100).contains(piece.cutQuantity),
      piece.grainAngle.isFinite, abs(piece.grainAngle) <= 36000, (piece.notes?.count ?? 0) <= 2000,
      (piece.materialID?.count ?? 0) <= 160,
      piece.notches.count <= 128, Set(piece.notches.map(\.id)).count == piece.notches.count
    else {
      throw FormError.invalid(
        "Use named pieces, 1–100 copies, and finite allowances of0 or0.05–100 mm.")
    }
    guard piece.edgeAllowances.isEmpty else {
      throw FormError.invalid(
        "Curved, concave, and holed pieces currently require a uniform seam allowance. Per-edge overrides remain available on the original convex straight pieces; no override is approximated."
      )
    }
    if piece.onFoldEdge != nil || piece.onFoldEdgeID != nil {
      piece.onFoldEdge = try index(piece.onFoldEdge ?? 0, piece.onFoldEdgeID, piece.onFoldEndID)
    }
    for i in piece.notches.indices {
      piece.notches[i].edge = try index(
        piece.notches[i].edge, piece.notches[i].edgeID, piece.notches[i].endID)
    }
    let normals = edges.map { edge -> Point2 in
      let sample = edge.sample(fraction: 0.5)
      let sign =
        (SewingCurves.signedArea(boundaries[edge.contour].points) > 0 ? 1.0 : -1.0)
        * (edge.contour == 0 ? 1 : -1)
      return .init(sign * sample.tangent.y, -sign * sample.tangent.x)
    }
    let normalized = boundaries.enumerated().map { ci, b -> [Point2] in
      let positive = SewingCurves.signedArea(b.points) > 0
      return positive == (ci == 0) ? b.points : Array(b.points.reversed())
    }
    var cut =
      piece.seamAllowance == 0
      ? normalized : try SewingPolygonKernel.offset(normalized, distance: piece.seamAllowance)
    if piece.seamAllowance != 0 { cut = try orderedCutContours(cut, source: boundaries) }
    if let fold = piece.onFoldEdge {
      guard boundaries.count == 1, edges[fold].contour == 0, edges[fold].isStraight else {
        throw FormError.invalid(
          "A cut-on-fold piece needs a straight original outer edge and no holes. Curved or holed folds are not approximated."
        )
      }
      let a = edges[fold].points[0]
      let n = normals[fold]
      guard
        edges.flatMap(\.controls).allSatisfy({
          ($0.x - a.x) * n.x + ($0.y - a.y) * n.y <= 1e-7
        })
      else {
        throw FormError.invalid(
          "A fold edge must bound the whole piece on one side of its straight line.")
      }
      let p = cut.flatMap { $0 }
      let box = SewingLayoutGeometry.bounds(p)
      let pad = 1.0
      var keep = [
        Point2(box.x - pad, box.y - pad), .init(box.maxX + pad, box.y - pad),
        .init(box.maxX + pad, box.maxY + pad), .init(box.x - pad, box.maxY + pad),
      ]
      var clipped: [Point2] = []
      for i in keep.indices {
        let p = keep[i]
        let q = keep[(i + 1) % keep.count]
        let dp = (p.x - a.x) * n.x + (p.y - a.y) * n.y
        let dq = (q.x - a.x) * n.x + (q.y - a.y) * n.y
        if dp <= 0 { clipped.append(p) }
        if (dp <= 0) != (dq <= 0) {
          let t = dp / (dp - dq)
          clipped.append(.init(p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t))
        }
      }
      keep = clipped
      cut = try orderedCutContours(
        SewingPolygonKernel.boolean(cut, clips: [keep], intersection: true), source: boundaries)
    }
    var wedges: [[Point2]] = []
    var cutNotches: [SewingCutNotch] = []
    var notchComparisons = 0
    for notch in piece.notches {
      let edge = edges[notch.edge]
      guard notch.edge != piece.onFoldEdge, notch.position.isFinite,
        (0...1).contains(notch.position), notch.width.isFinite, (1...10).contains(notch.width),
        notch.depth.isFinite, (0.5...10).contains(notch.depth),
        notch.depth + 0.05 < piece.seamAllowance,
        min(notch.position, 1 - notch.position) * edge.length > notch.width / 2 + 1
      else {
        throw FormError.invalid(
          "Notches need physical arc distance from source corners and depth at least0.05 mm inside the allowance."
        )
      }
      let sample = edge.sample(fraction: notch.position)
      let sign =
        (SewingCurves.signedArea(boundaries[edge.contour].points) > 0 ? 1.0 : -1.0)
        * (edge.contour == 0 ? 1 : -1)
      let n = Point2(sign * sample.tangent.y, -sign * sample.tangent.x)
      let resolved = try SewingCurves.notchFootprint(
        notch, edge: edge, normal: n, allowance: piece.seamAllowance, cutRing: cut[edge.contour])
      var wedge = resolved.polygon
      try SewingCurves.validateTopology([wedge])
      cutNotches.append(resolved.record)
      guard
        !wedge.contains(where: { SewingLayoutGeometry.containsMaterial($0, contours: normalized) }),
        !normalized.contains(where: { SewingCurves.contains($0[0], ring: wedge) })
      else {
        throw FormError.invalid(
          "This notch would remove finished stitch material. Reduce its width/depth or change its source arc position."
        )
      }
      for ring in normalized {
        for i in ring.indices {
          for j in wedge.indices {
            notchComparisons += 1
            guard notchComparisons <= SewingCurveLimits.maximumTopologyComparisons else {
              throw FormError.invalid(
                "Notch preflight exceeded its geometry budget. Reduce notch count or simplify the source."
              )
            }
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            let c = wedge[j]
            let d = wedge[(j + 1) % wedge.count]
            let distance = min(
              SewingCurves.segmentDistance(a, c, d), SewingCurves.segmentDistance(b, c, d),
              SewingCurves.segmentDistance(c, a, b), SewingCurves.segmentDistance(d, a, b))
            if SewingCurves.intersects(a, b, c, d) || distance < 0.04 {
              throw FormError.invalid(
                "This curved notch reaches the stitch outline or its physical error margin. Reduce its width/depth or move it to a gentler part of the curve."
              )
            }
          }
        }
      }
      if SewingCurves.signedArea(wedge) < 0 { wedge.reverse() }
      wedges.append(wedge)
    }
    for edge in edges {
      let notches = piece.notches.filter { $0.edge == edge.index }.sorted {
        $0.position < $1.position
      }
      for i in 1..<max(1, notches.count) {
        let a = notches[i - 1]
        let b = notches[i]
        guard (b.position - a.position) * edge.length > (a.width + b.width) / 2 + 1 else {
          throw FormError.invalid(
            "Separate source-edge notches by at least1 mm of physical arc length.")
        }
      }
    }
    if !wedges.isEmpty {
      cut = try orderedCutContours(
        SewingPolygonKernel.boolean(cut, clips: wedges), source: boundaries)
    }
    let radians = piece.grainAngle * Double.pi / 180
    let transform = art.worldTransform(e)
    let d = Point2(
      transform.a * cos(radians) + transform.c * sin(radians),
      transform.b * cos(radians) + transform.d * sin(radians))
    let norm = hypot(d.x, d.y)
    guard norm > 1e-12 else {
      throw FormError.invalid("A sewing piece's transform collapses its grain direction.")
    }
    return .init(
      elementID: e.id, piece: piece, stitch: boundaries[0].points, cut: cut[0], normals: normals,
      edgeLengths: edges.map(\.length),
      grainDirection: .init(d.x / norm, d.y / norm), boundaries: boundaries, cutContours: cut,
      usesGeneralGeometry: true, edgeLengthErrors: edges.map(\.lengthError), cutNotches: cutNotches)
  }
}
