import Foundation

struct SewingLayoutWorkItem {
  var geometry: SewingPieceGeometry
  var copies: [Int]
  var id: UUID { SewingLayoutIdentity.placement(geometry.elementID, copies: copies) }
}

public enum SewingLayouts {
  static func sourceIsVisible(_ e: ArtworkElement, in art: Artwork) -> Bool {
    var current: ArtworkElement? = e, seen = Set<UUID>()
    while let item = current, seen.insert(item.id).inserted {
      if item.hidden == true { return false }
      current = item.parentID.flatMap { id in art.elements.first { $0.id == id } }
    }
    return true
  }
  static func workItems(_ layout: SewingCutLayout, source: Artwork) throws -> (items: [SewingLayoutWorkItem], excluded: [UUID], issues: [SewingLayoutIssue]) {
    let explicit = layout.elementIDs.map(Set.init)
    let all = source.elements.filter { $0.sewingPiece != nil }
    var items: [SewingLayoutWorkItem] = [], excluded: [UUID] = [], issues: [SewingLayoutIssue] = []
    let known = Set(all.map(\.id))
    for missing in (explicit ?? []).subtracting(known).sorted(by: { $0.uuidString < $1.uuidString }) {
      issues.append(.init(.source, "The layout source piece \(missing.uuidString) is missing."))
    }
    for e in all {
      if let explicit, !explicit.contains(e.id) { excluded.append(e.id); continue }
      guard sourceIsVisible(e, in: source) else {
        if explicit != nil { issues.append(.init(.source, "\(e.sewingPiece!.name) is hidden. Unhide it or remove it from the layout scope.")) }
        excluded.append(e.id); continue
      }
      if let assigned = e.sewingPiece?.materialID, assigned != layout.materialID {
        if explicit != nil { issues.append(.init(.source, "\(e.sewingPiece!.name) uses \(assigned), while this layout uses \(layout.materialID).")) }
        excluded.append(e.id); continue
      }
      let geometry = try SewingPatterns.geometry(e, in: source), quantity = geometry.piece.cutQuantity
      if geometry.piece.onFoldEdge != nil, layout.stock != .foldedPair {
        issues.append(.init(.fold, "\(geometry.piece.name) is cut on fold. Choose folded two-ply stock.")); continue
      }
      let batch = layout.stock == .foldedPair && geometry.piece.onFoldEdge == nil ? 2 : 1
      if batch == 2 && quantity % 2 != 0 {
        issues.append(.init(.fold, "\(geometry.piece.name) has an odd cut quantity. Folded stock produces two ordinary cuts per placement; choose single-layer stock or an even quantity.")); continue
      }
      for first in stride(from: 1, through: quantity, by: batch) {
        items.append(.init(geometry: geometry, copies: Array(first..<(first + batch))))
      }
    }
    guard items.count <= SewingLayoutLimits.maximumPlacements else { throw FormError.invalid("This material needs more than 200 cutting placements. Split it into smaller layout scopes.") }
    if items.isEmpty && issues.isEmpty { issues.append(.init(.source, "No visible sewing pieces use the selected material. Unassigned pieces can use this layout's stock.")) }
    return (items, excluded, issues)
  }
  static func placementIssues(_ p: SewingLayoutResolvedPlacement, layout: SewingCutLayout, width: Double, length: Double) -> [SewingLayoutIssue] {
    let epsilon = SewingLayoutGeometry.epsilon, id = [p.placement.id]
    let minimumX = p.geometry.piece.onFoldEdge == nil ? layout.margin : 0
    var issues: [SewingLayoutIssue] = []
    if p.bounds.x < minimumX - epsilon || p.bounds.maxX > width - layout.margin + epsilon || p.bounds.y < layout.margin - epsilon || p.bounds.maxY > length - layout.margin + epsilon {
      issues.append(.init(.bounds, "\(p.geometry.piece.name) lies outside the usable stock and margins.", placements: id))
    }
    if !SewingLayoutGeometry.grainMatches(p.grainDirection, rule: layout.grain) {
      issues.append(.init(.grain, "\(p.geometry.piece.name) does not follow the chosen material grain rule (1° tolerance).", placements: id))
    }
    if let fold = p.geometry.piece.onFoldEdge {
      let a = p.transform.apply(p.geometry.stitch[fold]), b = p.transform.apply(p.geometry.stitch[(fold + 1) % p.geometry.stitch.count])
      if layout.stock != .foldedPair || abs(a.x) > 0.001 || abs(b.x) > 0.001 {
        issues.append(.init(.fold, "\(p.geometry.piece.name)'s fold edge must lie along the left stock fold.", placements: id))
      }
    }
    return issues
  }
  public static func preflight(_ layout: SewingCutLayout, source: Artwork) throws -> SewingLayoutPreflight {
    try layout.validateMetadata(); try validateArtwork(source)
    let work = try workItems(layout, source: source)
    var issues = work.issues, resolved: [SewingLayoutResolvedPlacement] = []
    let width = layout.workingWidth ?? 0, available = layout.availableLength ?? 0
    if layout.stockWidth == nil { issues.append(.init(.stock, "Enter the usable open material width in millimeters; this material has no declared width.")) }
    if layout.surface == .sheet && layout.sheetLength == nil { issues.append(.init(.stock, "Enter the sheet length in millimeters.")) }
    if width <= layout.margin * 2 || available <= layout.margin * 2 { issues.append(.init(.stock, "Stock dimensions must leave usable space after margins.")) }
    let expected = Dictionary(uniqueKeysWithValues: work.items.map { ($0.id, $0) })
    var seen = Set<UUID>(), physicalCopies = Set<String>()
    for placement in layout.placements {
      guard let item = expected[placement.id], item.copies.sorted() == placement.copies.sorted() else {
        issues.append(.init(.extraCopy, "A saved placement no longer matches a source piece's material, quantity, or stock layers. Replan it.", placements: [placement.id])); continue
      }
      seen.insert(placement.id)
      for copy in placement.copies {
        if !physicalCopies.insert(placement.elementID.uuidString + ":\(copy)").inserted {
          issues.append(.init(.extraCopy, "A physical cut copy is placed more than once.", placements: [placement.id]))
        }
      }
      let p = SewingLayoutGeometry.resolve(placement, geometry: item.geometry)
      resolved.append(p)
      if width > 0 && available > 0 { issues += placementIssues(p, layout: layout, width: width, length: available) }
    }
    for item in work.items where !seen.contains(item.id) {
      issues.append(.init(.missingCopy, "\(item.geometry.piece.name), cut copies \(item.copies.map(String.init).joined(separator: ", ")), has not been placed.", placements: [item.id]))
    }
    var comparisons = 0, exhausted = false
    for i in resolved.indices {
      if exhausted { break }
      for j in resolved.indices where j > i {
        do {
          let separation = try SewingLayoutGeometry.separation(resolved[i], resolved[j], required: layout.spacing, comparisons: &comparisons)
          if separation.overlaps {
            issues.append(.init(.collision, "\(resolved[i].geometry.piece.name) overlaps \(resolved[j].geometry.piece.name).", placements: [resolved[i].placement.id, resolved[j].placement.id]))
          } else if separation.distance + SewingLayoutGeometry.epsilon < layout.spacing {
            issues.append(.init(.spacing, String(format: "Cut pieces are %.3f mm apart; %.3f mm is required.", separation.distance, layout.spacing), placements: [resolved[i].placement.id, resolved[j].placement.id]))
          }
        } catch { issues.append(.init(.budget, error.localizedDescription)); exhausted = true; break }
      }
    }
    let requiredLength = resolved.isEmpty ? 0 : (resolved.map { $0.bounds.maxY }.max()! + layout.margin)
    let consumedLength = layout.surface == .sheet ? layout.sheetLength ?? 0 : requiredLength
    let allocated = (layout.stockWidth ?? 0) * consumedLength
    let used = resolved.reduce(0.0) { $0 + SewingLayoutGeometry.area($1.contour) * (layout.stock == .foldedPair ? 2 : 1) }
    return .init(issues: issues, placements: resolved, workingWidth: width, requiredLength: requiredLength,
      consumedLength: consumedLength, allocatedAreaMM2: allocated, cutAreaMM2: used,
      estimatedCost: issues.isEmpty ? layout.costPerSquareMeter.map { $0 * allocated / 1_000_000 } : nil,
      excludedPieceIDs: work.excluded)
  }
}
