import AppKit
import CryptoKit
import FormCore

/// One renderer for physical yardage, reusable garment textures, and native swatch previews.
@MainActor public enum FabricPatternRenderer {
  private struct TextureDefinition: Codable {
    let artwork: Artwork
    let sourceSize: Point2
    let repeatMode: FabricPattern.Repeat
    let scale: Double
    let spacing: Point2
    let baseColor: String
  }
  private static let textures: NSCache<NSString, NSImage> = {
    let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 48_000_000; c.countLimit = 48; return c
  }()
  private static func concatenate(_ t: Affine2, _ context: CGContext) {
    context.concatenate(.init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty))
  }
  public static func drawSupertile(_ design: ResolvedFabricPattern, assets: URL, effectScale: Double? = nil) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let size = design.supertileSize
    context.saveGState(); context.clip(to: .init(x: 0, y: 0, width: size.x, height: size.y))
    context.setFillColor(FormColor.color(design.baseColor).cgColor)
    context.fill(.init(x: 0, y: 0, width: size.x, height: size.y))
    for transform in design.pattern.motifTransforms(sourceSize: design.sourceSize) {
      context.saveGState(); concatenate(transform, context)
      ArtworkRenderer.draw(design.artwork, width: design.sourceSize.x, height: design.sourceSize.y,
        assets: assets, effectScale: effectScale)
      context.restoreGState()
    }
    context.restoreGState()
  }
  public static func texture(_ design: ResolvedFabricPattern, assets: URL, limit: Int = 1536, fontRevision: Int = 0) -> NSImage {
    let edge = min(4096, max(64, limit)), size = design.supertileSize
    let definition = TextureDefinition(artwork: design.artwork.renderDefinition, sourceSize: design.sourceSize,
      repeatMode: design.pattern.repeatMode, scale: design.pattern.scale, spacing: design.pattern.spacing, baseColor: design.baseColor)
    var keyData = (try? JSONEncoder.form.encode(definition)) ?? Data()
    keyData.append(Data("\(assets.path)|\(edge)|\(fontRevision)".utf8))
    let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined() as NSString
    if let cached = textures.object(forKey: key) { return cached }
    let density = min(20, Double(edge) / max(size.x, size.y))
    let image = bitmap(width: size.x, height: size.y, density: density) {
      drawSupertile(design, assets: assets, effectScale: density)
    }
    let rep = image.representations.first!
    textures.setObject(image, forKey: key, cost: rep.pixelsWide * rep.pixelsHigh * 4)
    return image
  }
  /// Raster previews reuse one supertile; repeat count does not multiply source shaping/geometry work.
  public static func drawPreview(_ design: ResolvedFabricPattern, assets: URL, width: Double, height: Double,
    textureLimit: Int = 1536, fontRevision: Int = 0) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let image = texture(design, assets: assets, limit: textureLimit, fontRevision: fontRevision)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let size = design.supertileSize
    context.saveGState(); context.clip(to: .init(x: 0, y: 0, width: width, height: height))
    concatenate(design.pattern.latticeTransform, context)
    // CGContext image coordinates are bottom-up; the artwork/physical lattice uses top-down Y.
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(cg, in: .init(x: 0, y: -size.y, width: size.x, height: size.y), byTiling: true)
    context.restoreGState()
  }
  public static func image(_ design: ResolvedFabricPattern, assets: URL, width: Double, height: Double,
    pixelsPerMM: Double) throws -> NSImage {
    guard pixelsPerMM.isFinite, pixelsPerMM > 0, width.isFinite, height.isFinite, width > 0, height > 0,
      width * pixelsPerMM <= 16000, height * pixelsPerMM <= 16000,
      width * height * pixelsPerMM * pixelsPerMM <= 100_000_000 else {
      throw FormError.invalid("Fabric raster output supports at most 100 megapixels and 16000 pixels per edge.")
    }
    try ArtworkRenderer.validateAppearanceOutput(design.artwork, assets: assets,
      pixelsPerMM: pixelsPerMM * design.pattern.scale)
    // Render source vectors at the requested output density; do not upsample a screen preview.
    let origins = try design.pattern.tileOrigins(sourceSize: design.sourceSize, width: width, height: height)
    let cost = origins.count * design.pattern.motifTransforms(sourceSize: design.sourceSize).count * max(1, design.artwork.elements.count)
    guard cost <= 250000 else { throw FormError.invalid("This fabric export has too much repeated artwork. Reduce the output area or use SVG.") }
    return bitmap(width: width, height: height, density: pixelsPerMM) {
      drawVectors(design, assets: assets, width: width, height: height, origins: origins, effectScale: pixelsPerMM)
    }
  }
  public static func drawVectors(_ design: ResolvedFabricPattern, assets: URL, width: Double, height: Double,
    origins: [Point2], effectScale: Double) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState(); context.clip(to: .init(x: 0, y: 0, width: width, height: height))
    // A continuous base avoids PDF viewer antialias hairlines between neighboring tile clips.
    context.setFillColor(FormColor.color(design.baseColor).cgColor)
    context.fill(.init(x: 0, y: 0, width: width, height: height))
    concatenate(design.pattern.latticeTransform, context)
    let motifs = design.pattern.canonicalMotifTransforms(sourceSize: design.sourceSize)
    for origin in origins {
      context.saveGState(); context.translateBy(x: origin.x, y: origin.y)
      // Do not clip at supertile boundaries: half-drop/brick motifs extend into the next period.
      for transform in motifs {
        context.saveGState(); concatenate(transform, context)
        ArtworkRenderer.draw(design.artwork, width: design.sourceSize.x, height: design.sourceSize.y,
          assets: assets, effectScale: effectScale)
        context.restoreGState()
      }
      context.restoreGState()
    }
    context.restoreGState()
  }
  public static func svg(_ design: ResolvedFabricPattern, assets: URL, width: Double, height: Double) throws -> String {
    let size = design.supertileSize, t = design.pattern.latticeTransform
    let fragment = try SVGRenderer.fragment(design.artwork, width: design.sourceSize.x,
      height: design.sourceSize.y, assets: assets, outlineText: true)
    let motifs = design.pattern.motifTransforms(sourceSize: design.sourceSize).map { m in
      "<use href=\"#fabric-motif\" transform=\"matrix(\(m.a) \(m.b) \(m.c) \(m.d) \(m.tx) \(m.ty))\"/>"
    }.joined()
    return """
    <?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="\(width)mm" height="\(height)mm" viewBox="0 0 \(width) \(height)"><desc>FORM fabric yardage. Millimeters. Editable tile source retained in the FORM project. Typography outlined. Repeat: \(design.pattern.repeatMode.rawValue).</desc><defs><g id="fabric-motif">\(fragment)</g><pattern id="fabric-repeat" patternUnits="userSpaceOnUse" width="\(size.x)" height="\(size.y)" patternTransform="matrix(\(t.a) \(t.b) \(t.c) \(t.d) \(t.tx) \(t.ty))">\(motifs)</pattern></defs><rect width="\(width)" height="\(height)" fill="\(design.baseColor)"/><rect width="\(width)" height="\(height)" fill="url(#fabric-repeat)"/></svg>
    """
  }
  public static func pdf(_ design: ResolvedFabricPattern, assets: URL, width: Double, height: Double, dpi: Double) throws -> Data {
    guard !design.artwork.requiresInkOutput else{throw FormError.invalid("This fabric tile declares production inks. Yardage PDF does not yet preserve those colorants. Export the source tile with an explicit production ink mode; SVG/raster yardage are RGB appearance previews.")}
    let origins = try design.pattern.tileOrigins(sourceSize: design.sourceSize, width: width, height: height)
    let cost = origins.count * design.pattern.motifTransforms(sourceSize: design.sourceSize).count * max(1, design.artwork.elements.count)
    guard cost <= 250000 else { throw FormError.invalid("This PDF needs too much repeated artwork. Reduce the output area or export SVG.") }
    try ArtworkRenderer.validateAppearanceOutput(design.artwork, assets: assets, pixelsPerMM: dpi / 25.4 * design.pattern.scale)
    var box = CGRect(x: 0, y: 0, width: width * TypographyEngine.pointsPerMM, height: height * TypographyEngine.pointsPerMM)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      throw FormError.invalid("Could not create fabric yardage PDF.")
    }
    context.beginPDFPage(nil); context.translateBy(x: 0, y: box.height)
    context.scaleBy(x: TypographyEngine.pointsPerMM, y: -TypographyEngine.pointsPerMM)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawVectors(design, assets: assets, width: width, height: height, origins: origins, effectScale: dpi / 25.4)
    NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
    return data as Data
  }
  private static func bitmap(width: Double, height: Double, density: Double, draw: () -> Void) -> NSImage {
    let w = max(1, Int(ceil(width * density))), h = max(1, Int(ceil(height * density)))
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: Double(h)); context.scaleBy(x: Double(w) / width, y: -Double(h) / height)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(); NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: .init(width: w, height: h)); image.addRepresentation(NSBitmapImageRep(cgImage: context.makeImage()!))
    return image
  }
}
