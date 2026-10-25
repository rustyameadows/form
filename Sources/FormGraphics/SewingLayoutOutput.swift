import AppKit
import FormCore

/// Stock coordinates remain physical millimeters in every output. Fabric fills are a reference
/// layer anchored to the roll, not a per-piece fit or a promise of matched motifs across seams.
@MainActor public struct SewingLayoutOutput {
  public let layout: SewingCutLayout
  public let report: SewingLayoutPreflight
  public let artwork: Artwork
  public let fabric: ResolvedFabricPattern?
  public let fabricColor: String
  public let includeFabricPreview: Bool
  public init(layout: SewingCutLayout, source: Artwork, fabric: ResolvedFabricPattern? = nil,
    fabricColor: String = "#E0D5BD", includeFabricPreview: Bool = false) throws {
    let report = try SewingLayouts.preflight(layout, source: source)
    guard report.isValid else { throw FormError.invalid(report.issues.prefix(4).map(\.message).joined(separator: " ")) }
    self.layout = layout; self.report = report
    self.artwork = try SewingLayoutDrawing.artwork(report, layout: layout, labelBackplates: includeFabricPreview)
    self.fabric = fabric; self.fabricColor = fabricColor; self.includeFabricPreview = includeFabricPreview
  }
  public var width: Double { report.workingWidth }
  public var height: Double { report.consumedLength }
  public var adjustedFabric: ResolvedFabricPattern? {
    guard var fabric else { return nil }
    let upperPlyOpenX = layout.stock == .foldedPair ? (layout.stockWidth ?? 0) / 2 : 0
    fabric.pattern.offset.x += layout.fabricOrigin.x - upperPlyOpenX
    fabric.pattern.offset.y += layout.fabricOrigin.y
    return fabric
  }
  public var metadata: [String: Any] {
    var value = report.metadata(layout: layout)
    value["width_mm"] = width; value["height_mm"] = height
    value["include_fabric_preview"] = includeFabricPreview
    value["fabric_layer_purpose"] = "Roll-anchored reference; no seam registration or machine postprocessing."
    value["stock_origin_mm"] = ["x": 0, "y": 0]
    return value
  }
  private var combinedArtwork: Artwork {
    var art = artwork
    for i in art.elements.indices { art.elements[i].productionRole = nil }
    return art
  }
  private var clipPath: CGPath {
    let path = CGMutablePath()
    for p in report.placements {
      guard let first = p.contour.first else { continue }
      path.move(to: .init(x: first.x, y: first.y))
      for point in p.contour.dropFirst() { path.addLine(to: .init(x: point.x, y: point.y)) }
      path.closeSubpath()
    }
    return path
  }
  public func drawFabric(assets: URL, vector: Bool, density: Double = 1, fontRevision: Int = 0) throws {
    guard includeFabricPreview, let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState(); context.addPath(clipPath); context.clip()
    defer { context.restoreGState() }
    if let design = adjustedFabric {
      if vector {
        let origins = try design.pattern.tileOrigins(sourceSize: design.sourceSize, width: width, height: height)
        let cost = origins.count * design.pattern.canonicalMotifTransforms(sourceSize: design.sourceSize).count * max(1, design.artwork.elements.count)
        guard cost <= 250000 else { throw FormError.invalid("The fabric reference layer is too complex at this roll size. Export without the fabric preview, or use the standalone SVG yardage export.") }
        try ArtworkRenderer.validateAppearanceOutput(design.artwork, assets: assets, pixelsPerMM: density * design.pattern.scale)
        FabricPatternRenderer.drawVectors(design, assets: assets, width: width, height: height, origins: origins, effectScale: density)
      } else {
        FabricPatternRenderer.drawPreview(design, assets: assets, width: width, height: height, fontRevision: fontRevision)
      }
    } else {
      context.setFillColor(FormColor.color(fabricColor).cgColor); context.fill(.init(x: 0, y: 0, width: width, height: height))
    }
  }
  public func draw(assets: URL, vector: Bool, density: Double = 1, fontRevision: Int = 0) throws {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState(); context.clip(to: .init(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor.white.cgColor); context.fill(.init(x: 0, y: 0, width: width, height: height))
    do {
      try drawFabric(assets: assets, vector: vector, density: density, fontRevision: fontRevision)
      ArtworkRenderer.draw(combinedArtwork, width: width, height: height, assets: assets, effectScale: vector ? density : nil)
    } catch { context.restoreGState(); throw error }
    context.restoreGState()
  }
  public func svg(assets: URL) throws -> String {
    let output = try ArtworkProductionOutput(source: artwork, width: width, height: height, roles: [.cut, .stitch, .guide])
    var svg = try output.svg(assets: assets, outlineText: true)
    let json = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
    var reference = "<metadata id=\"form-cutting-layout\">" + SVGRenderer.xml(json) + "</metadata>"
    if includeFabricPreview {
      let path = SVGRenderer.data(clipPath)
      let fill: String
      if let design = adjustedFabric {
        let full = try FabricPatternRenderer.svg(design, assets: assets, width: width, height: height)
        guard let start = full.range(of: "<defs>"), let end = full.range(of: "</svg>", options: .backwards) else { throw FormError.invalid("Could not compose the fabric reference layer.") }
        fill = String(full[start.lowerBound..<end.lowerBound])
      } else { fill = "<rect width=\"\(width)\" height=\"\(height)\" fill=\"\(fabricColor)\"/>" }
      reference += "<defs><clipPath id=\"cutting-layout-pieces\"><path d=\"\(path)\"/></clipPath></defs><g id=\"form-role-fabric-reference\" inkscape:groupmode=\"layer\" inkscape:label=\"Fabric reference\" data-form-role=\"fabric-reference\"><title>Roll-anchored fabric reference; visible upper ply when folded</title><g clip-path=\"url(#cutting-layout-pieces)\">\(fill)</g></g>"
    }
    if let end = svg.range(of: "</desc>")?.upperBound { svg = String(svg[..<end]) + reference + String(svg[end...]) }
    return svg
  }
  public func pdf(assets: URL, dpi: Double = 150) throws -> Data {
    guard dpi.isFinite, (36...1200).contains(dpi) else { throw FormError.invalid("Choose 36–1200 DPI for layout PDF effects.") }
    try ArtworkRenderer.validateAppearanceOutput(combinedArtwork, assets: assets, pixelsPerMM: dpi / 25.4)
    var box = CGRect(x: 0, y: 0, width: width * TypographyEngine.pointsPerMM, height: height * TypographyEngine.pointsPerMM)
    let data = NSMutableData(), info = [kCGPDFContextTitle as String: layout.name,
      kCGPDFContextSubject as String: "Actual stock size \(width) × \(height) mm. Material \(layout.materialID). \(layout.stock.rawValue). No inventory deduction; no verified seam motif registration."]
    guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { throw FormError.invalid("Could not create the cutting layout PDF.") }
    context.beginPDFPage(nil); context.translateBy(x: 0, y: box.height)
    context.scaleBy(x: TypographyEngine.pointsPerMM, y: -TypographyEngine.pointsPerMM)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    do { try draw(assets: assets, vector: true, density: dpi / 25.4) }
    catch { NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF(); throw error }
    NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF(); return data as Data
  }
  public func image(assets: URL, dpi: Double = 150, fontRevision: Int = 0) throws -> NSImage {
    guard dpi.isFinite, (36...1200).contains(dpi), width * dpi / 25.4 <= 16000, height * dpi / 25.4 <= 16000,
      width * height * pow(dpi / 25.4, 2) <= 100_000_000 else { throw FormError.invalid("Layout raster exports support 36–1200 DPI, 100 megapixels and 16000 pixels per edge.") }
    try ArtworkRenderer.validateAppearanceOutput(combinedArtwork, assets: assets, pixelsPerMM: dpi / 25.4)
    let density = dpi / 25.4, w = max(1, Int(ceil(width * density))), h = max(1, Int(ceil(height * density)))
    guard let graphics = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FormError.invalid("Could not allocate the layout image.") }
    graphics.translateBy(x: 0, y: Double(h)); graphics.scaleBy(x: Double(w) / width, y: -Double(h) / height)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: true)
    do { try draw(assets: assets, vector: true, density: density, fontRevision: fontRevision) }
    catch { NSGraphicsContext.restoreGraphicsState(); throw error }
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: graphics.makeImage()!)
    rep.size = .init(width: width * TypographyEngine.pointsPerMM, height: height * TypographyEngine.pointsPerMM)
    let image = NSImage(size: rep.size); image.addRepresentation(rep); return image
  }
}
