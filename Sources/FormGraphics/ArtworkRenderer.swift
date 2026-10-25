import AppKit
import FormCore

@MainActor public enum ArtworkRenderer {
  public static func validateGlyphOutput(_ source: Artwork, assets: URL) throws {
    let art=try BooleanGeometry.materialized(source)
    let tree=ArtworkRenderTree(art,assets:assets,production:true,excluding:[])
    for e in art.elements where e.kind=="text" && tree.displayed(e) { try GlyphEngine.validateOutput(e) }
  }
  public static func validateAppearanceOutput(_ source: Artwork, assets: URL, pixelsPerMM: Double) throws {
    let art = try BooleanGeometry.materialized(source)
    let tree = ArtworkRenderTree(art, assets: assets, production: true, excluding: [])
    for e in art.elements where e.visibleStroke != nil && tree.displayed(e) {
      _ = try VectorGeometry.expandedStroke(e)
    }
    for e in art.elements where e.kind == "text" && tree.displayed(e) {
      try GlyphEngine.validateOutput(e)
    }
    for e in art.elements where e.kind == "image" && tree.displayed(e) {
      try ImageRenderer.validateOutput(e, assets: assets, pixelsPerMM: pixelsPerMM, transform: art.worldTransform(e))
    }
    for e in art.elements where e.hasActiveEffects && tree.displayed(e) {
      let box = tree.localBounds(e)
      let density = pixelsPerMM * AppearanceRenderer.scale(art.worldTransform(e).cg)
      let width = ceil(box.width * density), height = ceil(box.height * density)
      guard width.isFinite, height.isFinite, width <= Double(AppearanceRenderer.maximumEdge),
        height <= Double(AppearanceRenderer.maximumEdge), width * height <= Double(AppearanceRenderer.maximumPixels)
      else { throw FormError.invalid("An effect is too large at this resolution. Lower the export DPI, reduce the layer size, or export SVG to retain vector effects.") }
    }
  }
  private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 100
    cache.totalCostLimit = 64_000_000
    return cache
  }()
  public static func draw(
    _ source: Artwork, width: Double, height: Double, assets: URL, production: Bool = true,
    excluding: Set<UUID> = [], effectScale: Double? = nil, unbounded: Bool = false
  ) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let art: Artwork
    do { art = try BooleanGeometry.materialized(source) } catch {
      context.saveGState()
      context.setStrokeColor(FormColor.color("#D45A37").cgColor)
      context.stroke(CGRect(x: 0, y: 0, width: width, height: height))
      context.restoreGState()
      return
    }
    context.saveGState()
    if !unbounded { context.clip(to: CGRect(x: 0, y: 0, width: width, height: height)) }
    if !unbounded, let boundary = art.boundary {
      var mask = ArtworkElement(
        kind: "path", x: 0, y: 0, width: boundary.width, height: boundary.height)
      mask.path = boundary
      context.addPath(VectorGeometry.path(mask))
      context.clip(using: boundary.evenOdd ? .evenOdd : .winding)
    }
    if !unbounded {
      context.setFillColor(
        FormColor.color(art.background).withAlphaComponent(art.backgroundOpacity ?? 1).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    ArtworkRenderTree(art, assets: assets, production: production, excluding: excluding)
      .drawChildren(nil, context: context,
        effectScale: effectScale.map { $0 / max(0.001, AppearanceRenderer.scale(context)) })
    context.restoreGState()
  }
  public static func drawElement(_ e: ArtworkElement, assets: URL, context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: e.width, height: e.height)
    if e.kind == "text" {
      guard e.fillEnabled != false else { return }
      if let opacity = e.fillOpacity, opacity < 1 {
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        TypographyEngine.draw(e, in: context)
        context.endTransparencyLayer()
        context.restoreGState()
      } else {
        TypographyEngine.draw(e, in: context)
      }
      return
    }
    if e.kind == "image" {
      if ImageRenderer.draw(e, assets: assets, context: context) { return }
      guard let name = e.asset, !name.contains("/") else { return }
      let url = assets.appendingPathComponent(name)
      let key = url.path as NSString
      let image: NSImage
      if let cached = images.object(forKey: key) {
        image = cached
      } else {
        guard let loaded = NSImage(contentsOf: url) else { return }
        image = loaded
        let pixels =
          image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
          ?? Int(image.size.width * image.size.height)
        images.setObject(image, forKey: key, cost: max(1, pixels) * 8)
      }
      let crop = e.imageCrop ?? .full
      context.saveGState()
      context.clip(to: rect)
      context.scaleBy(x: e.width / crop.width, y: e.height / crop.height)
      context.translateBy(x: -crop.x, y: -crop.y)
      image.draw(
        in: CGRect(x: 0, y: 0, width: 1, height: 1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high])
      context.restoreGState()
      return
    }
    let path = VectorGeometry.path(e)
    let rule: CGPathFillRule = e.path?.evenOdd == true ? .evenOdd : .winding
    if e.fillEnabled != false && e.kind != "line" {
      if let gradient = e.gradient, let colors = makeGradient(gradient, opacity: e.fillOpacity ?? 1)
      {
        context.saveGState()
        context.addPath(path)
        context.clip(using: rule)
        if let transform = gradient.transform { context.concatenate(transform.cg) }
        let start = CGPoint(x: gradient.start.x * e.width, y: gradient.start.y * e.height)
        let end = CGPoint(x: gradient.end.x * e.width, y: gradient.end.y * e.height)
        if hypot(end.x-start.x,end.y-start.y) < 1e-9, let stop = gradient.stops.last {
          context.setFillColor(FormColor.color(stop.color).withAlphaComponent((stop.opacity ?? 1)*(e.fillOpacity ?? 1)).cgColor)
          context.fill(rect)
        } else if gradient.kind == "radial" {
          context.drawRadialGradient(
            colors, startCenter: start, startRadius: 0, endCenter: start,
            endRadius: max(0.001, hypot(end.x - start.x, end.y - start.y)),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
          context.drawLinearGradient(
            colors, start: start, end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
      } else {
        context.setFillColor(
          FormColor.color(e.color).withAlphaComponent(e.fillOpacity ?? 1).cgColor)
        context.addPath(path)
        context.fillPath(using: rule)
      }
    }
    if let stroke = e.visibleStroke {
      if (stroke.alignment ?? "center") != "center" {
        if let outline = try? VectorGeometry.expandedStroke(e) {
          context.setFillColor(FormColor.color(stroke.color).withAlphaComponent(stroke.opacity ?? 1).cgColor)
          context.addPath(outline); context.fillPath()
        }
        return
      }
      if stroke.dash?.isEmpty == false, (try? StrokeGeometry.path(e)) == nil { return }
      context.setStrokeColor(
        FormColor.color(stroke.color).withAlphaComponent(stroke.opacity ?? 1).cgColor)
      context.setLineWidth(stroke.width)
      context.setLineCap(VectorGeometry.cap(stroke.cap))
      context.setLineJoin(VectorGeometry.join(stroke.join))
      context.setMiterLimit(stroke.miter ?? 10)
      context.setLineDash(
        phase: stroke.dashOffset ?? 0, lengths: (stroke.dash ?? []).map { CGFloat($0) })
      context.addPath(path)
      context.strokePath()
    }
  }
  private static func makeGradient(_ gradient: ArtworkGradient, opacity: Double) -> CGGradient? {
    let colors: [CGColor] = gradient.stops.map {
      FormColor.color($0.color).withAlphaComponent(($0.opacity ?? 1) * opacity).cgColor
    }
    let locations: [CGFloat] = gradient.stops.map { CGFloat($0.offset) }
    return CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
      locations: locations)
  }
  public static func image(
    _ art: Artwork, width: Double, height: Double, assets: URL, pixelsPerMM: Double? = nil,
    opaqueBackground: Bool = false
  ) -> NSImage {
    let scale = pixelsPerMM ?? min(5, 2048 / max(width, height))
    let w = max(1, Int((width * scale).rounded()))
    let h = max(1, Int((height * scale).rounded()))
    let graphics = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if opaqueBackground {
      graphics.setFillColor(NSColor.white.cgColor)
      graphics.fill(CGRect(x: 0, y: 0, width: Double(w), height: Double(h)))
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: true)
    graphics.translateBy(x: 0, y: Double(h))
    graphics.scaleBy(x: scale, y: -scale)
    draw(art, width: width, height: height, assets: assets)
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: graphics.makeImage()!)
    let image = NSImage(size: .init(width: w, height: h))
    image.addRepresentation(rep)
    return image
  }
}
