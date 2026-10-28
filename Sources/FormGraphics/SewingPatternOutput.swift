import AppKit
import FormCore

@MainActor public struct SewingPatternOutput {
  public let plan: SewingPatternPlan
  public init(source: Artwork, selection: Set<UUID> = []) throws { plan = try SewingPatternDrawing.plan(source, selection: selection) }
  public var combinedArtwork: Artwork {
    var art = plan.artwork
    for i in art.elements.indices { art.elements[i].productionRole = nil }
    return art
  }
  public var metadata: [String: Any] {
    ["units": "mm", "width_mm": plan.frameSize.x, "height_mm": plan.frameSize.y,
      "pieces": plan.pieces.map { g in
        ["element_id": g.elementID.uuidString, "name": g.piece.name, "cut_quantity": g.piece.cutQuantity,
          "material_id": g.piece.materialID.map { $0 as Any } ?? NSNull(), "cut_width_mm": g.bounds.width, "cut_height_mm": g.bounds.height,
          "edge_lengths_mm": g.edgeLengths, "seam_allowances_mm": g.edgeLengths.indices.map { g.piece.allowance(for: $0) },
          "notches": g.piece.notches.count,
          "resolved_notches":g.cutNotches.map{["id":$0.id.uuidString,"edge_id":$0.edgeID?.uuidString ?? "","source_distance_mm":$0.sourceDistanceMM,"cut_opening_length_mm":$0.openingLengthMM,"mouth_a_mm":[$0.firstMouth.x,$0.firstMouth.y],"mouth_b_mm":[$0.secondMouth.x,$0.secondMouth.y],"tip_mm":[$0.tip.x,$0.tip.y]] as [String:Any]}, "hole_count": g.allStitchContours.count-1,
          "contour_tolerance_mm": g.usesGeneralGeometry ? SewingCurveLimits.contourToleranceMM : 0,
          "edge_length_errors_mm": g.edgeLengthErrors,
          "source_edges": g.sourceEdges.map { ["id": $0.id?.uuidString ?? "", "end_id":$0.endID?.uuidString ?? "", "contour_id":g.boundaries[$0.contour].id?.uuidString ?? "", "is_hole":g.boundaries[$0.contour].isHole, "index": $0.index, "contour": $0.contour, "length_mm": $0.length, "length_error_mm": $0.lengthError] as [String:Any] }, "grain_direction": [g.grainDirection.x, g.grainDirection.y],
          "unstitched_edges":g.edgeLengths.indices.filter{index in let ref=g.sourceEdges.first{$0.index==index};return g.piece.isUnstitched(edge:index,edgeID:ref?.id,endID:ref?.endID)},
          "construction_guides": ((try? SewingConstructionGuides.resolve(g)) ?? []).map{guide in
            ["id":guide.guide.id.uuidString,"kind":guide.guide.kind.rawValue,"label":guide.guide.label,"offset_mm":guide.guide.offset,
              "opening_mm":guide.guide.opening,"segments_mm":guide.segments.map{$0.map{[$0.x,$0.y]}}] as [String:Any]
          },
          "on_fold_edge": g.piece.onFoldEdge.map { $0 as Any } ?? NSNull()] as [String: Any]
      },
      "seams": plan.seams.map { d in ["id": d.seam.id.uuidString, "name": d.seam.name,
        "first_length_mm": d.firstLength, "second_length_mm": d.secondLength, "difference_mm": d.difference,
        "tolerance_mm": d.seam.tolerance, "matches": d.matches, "measurement_error_mm": d.measurementError, "conclusive": d.isConclusive] as [String: Any] },
      "mismatched_seams": plan.seams.filter { $0.isConclusive && !$0.matches }.count,
      "uncertain_seams": plan.seams.filter { !$0.isConclusive }.count,
      "cutting_template": true, "cloth_simulation": false, "calibration_square_mm": 50]
  }
  public func svg(assets: URL) throws -> String {
    let output = try ArtworkProductionOutput(source: plan.artwork, width: plan.frameSize.x, height: plan.frameSize.y,
      roles: [.cut, .stitch, .guide])
    var svg = try output.svg(assets: assets, outlineText: true)
    if let end = svg.range(of: "</desc>")?.upperBound {
      let json = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
      svg = String(svg[..<end]) + "<metadata id=\"form-sewing-pattern\">" + SVGRenderer.xml(json) + "</metadata>" + String(svg[end...])
    }
    return svg
  }
  public func pdf(assets: URL, dpi: Double = 300) throws -> Data {
    guard dpi.isFinite, (36...1200).contains(dpi) else { throw FormError.invalid("Choose 36–1200 DPI for pattern PDF effects.") }
    let art = combinedArtwork
    try ArtworkRenderer.validateAppearanceOutput(art, assets: assets, pixelsPerMM: dpi / 25.4)
    var box = CGRect(x: 0, y: 0, width: plan.frameSize.x * TypographyEngine.pointsPerMM, height: plan.frameSize.y * TypographyEngine.pointsPerMM)
    let data = NSMutableData()
    let info = [kCGPDFContextTitle as String: "FORM sewing pattern", kCGPDFContextSubject as String: "Print at actual size. Verify the 50 mm calibration square. Pattern pieces and cut quantities are labelled; this is not simulated garment fit."]
    guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else {
      throw FormError.invalid("Could not create sewing pattern PDF.")
    }
    context.beginPDFPage(nil); context.translateBy(x: 0, y: box.height)
    context.scaleBy(x: TypographyEngine.pointsPerMM, y: -TypographyEngine.pointsPerMM)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    ArtworkRenderer.draw(art, width: plan.frameSize.x, height: plan.frameSize.y, assets: assets, effectScale: dpi / 25.4)
    NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
    return data as Data
  }
  public func image(assets: URL, dpi: Double) throws -> NSImage {
    let w = plan.frameSize.x, h = plan.frameSize.y
    guard dpi.isFinite, (36...1200).contains(dpi), w * dpi / 25.4 <= 16000, h * dpi / 25.4 <= 16000,
      w * h * pow(dpi / 25.4, 2) <= 100_000_000 else { throw FormError.invalid("Pattern raster output supports 36–1200 DPI, 100 megapixels, and 16000 pixels per edge.") }
    try ArtworkRenderer.validateAppearanceOutput(combinedArtwork, assets: assets, pixelsPerMM: dpi / 25.4)
    return ArtworkRenderer.image(combinedArtwork, width: w, height: h, assets: assets, pixelsPerMM: dpi / 25.4, opaqueBackground: true)
  }
}
