import Foundation

public struct SewingLayoutPlanningResult: Sendable {
  public var layout: SewingCutLayout
  public var preflight: SewingLayoutPreflight
}

extension SewingLayouts {
  /// A deterministic bounded bottom-left candidate search, not an optimal-nesting solver. Large
  /// pieces are placed first; each allowed pose is tested with exact contour clearance checks.
  public static func planned(_ original: SewingCutLayout, source: Artwork) throws -> SewingLayoutPlanningResult {
    try original.validateMetadata(); try validateArtwork(source)
    guard let width = original.workingWidth, let length = original.availableLength,
      width > original.margin * 2, length > original.margin * 2 else {
      throw FormError.invalid("Enter the usable open stock width and, for sheet stock, its length before planning. Margins must leave usable material.")
    }
    let work = try workItems(original, source: source)
    if let issue = work.issues.first { throw FormError.invalid(issue.message) }
    let sorted = work.items.sorted { a, b in
      let areaA = SewingLayoutGeometry.area(SewingPatternDrawing.cutContour(a.geometry))
      let areaB = SewingLayoutGeometry.area(SewingPatternDrawing.cutContour(b.geometry))
      if abs(areaA - areaB) > 1e-8 { return areaA > areaB }
      let edgeA = max(a.geometry.bounds.width, a.geometry.bounds.height), edgeB = max(b.geometry.bounds.width, b.geometry.bounds.height)
      if abs(edgeA - edgeB) > 1e-8 { return edgeA > edgeB }
      if a.geometry.elementID != b.geometry.elementID { return a.geometry.elementID.uuidString < b.geometry.elementID.uuidString }
      return a.copies[0] < b.copies[0]
    }
    var placed: [SewingLayoutResolvedPlacement] = [], candidateChecks = 0, comparisons = 0
    for item in sorted {
      let rotations = SewingLayoutGeometry.rotations(for: item.geometry, layout: original)
      guard !rotations.isEmpty else { throw FormError.invalid("\(item.geometry.piece.name)'s fold edge conflicts with the chosen grain direction. Edit its grain or stock rule.") }
      let xs: [Double]
      if item.geometry.piece.onFoldEdge != nil { xs = [0] }
      else { xs = Array(Set([original.margin] + placed.map { $0.bounds.maxX + original.spacing })).sorted() }
      let ys = Array(Set([original.margin] + placed.map { $0.bounds.maxY + original.spacing })).sorted()
      var best: SewingLayoutResolvedPlacement?, bestScore: [Double]?
      let usedLength = placed.map { $0.bounds.maxY }.max() ?? original.margin
      for angle in rotations {
        var firstForAngle: SewingLayoutResolvedPlacement?
        search: for y in ys { for x in xs {
          candidateChecks += 1
          guard candidateChecks <= SewingLayoutLimits.maximumCandidates else {
            throw FormError.invalid("The deterministic layout search reached its 20000-candidate budget. Split the cutting job into smaller scopes.")
          }
          let placement = SewingCutPlacement(elementID: item.geometry.elementID, copies: item.copies, x: x, y: y, rotation: angle)
          let resolved = SewingLayoutGeometry.resolve(placement, geometry: item.geometry)
          if !placementIssues(resolved, layout: original, width: width, length: length).isEmpty { continue }
          var clear = true
          for other in placed {
            let separation = try SewingLayoutGeometry.separation(resolved, other, required: original.spacing, comparisons: &comparisons)
            if separation.overlaps || separation.distance + SewingLayoutGeometry.epsilon < original.spacing { clear = false; break }
          }
          if clear { firstForAngle = resolved; break search }
        } }
        if let candidate = firstForAngle {
          let score = [max(usedLength, candidate.bounds.maxY), candidate.bounds.y, candidate.bounds.x,
            abs(SewingLayoutGeometry.normalizedAngle(angle)), SewingLayoutGeometry.normalizedAngle(angle)]
          if bestScore == nil || score.lexicographicallyPrecedes(bestScore!) { best = candidate; bestScore = score }
        }
      }
      // A partial result remains explicit: preflight lists every required copy that did not fit.
      if let best { placed.append(best) }
    }
    var result = original
    result.placements = placed.map(\.placement)
    var report = try preflight(result, source: source); report.candidateChecks = candidateChecks
    return .init(layout: result, preflight: report)
  }
}
