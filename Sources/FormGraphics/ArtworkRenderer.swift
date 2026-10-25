import AppKit
import FormCore

@MainActor public enum ArtworkRenderer {
  private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 100
    cache.totalCostLimit = 64_000_000
    return cache
  }()
  public static func draw(
    _ source: Artwork, width: Double, height: Double, assets: URL, production: Bool = true,
    excluding: Set<UUID> = []
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
    context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
    if let boundary = art.boundary {
      var mask = ArtworkElement(
        kind: "path", x: 0, y: 0, width: boundary.width, height: boundary.height)
      mask.path = boundary
      context.addPath(VectorGeometry.path(mask))
      context.clip(using: boundary.evenOdd ? .evenOdd : .winding)
    }
    context.setFillColor(
      FormColor.color(art.background).withAlphaComponent(art.backgroundOpacity ?? 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let masks = Set(art.elements.compactMap(\.clipID))
    let byID = Dictionary(uniqueKeysWithValues: art.elements.map { ($0.id, $0) })
    let children = Dictionary(grouping: art.elements, by: \.parentID)
    func drawChildren(_ parent: UUID?) {
      for e in children[parent] ?? []
      where e.hidden != true && !excluding.contains(e.id)
        && !masks.contains(e.id)
      {
        if production, let role = e.productionRole, role != "artwork" { continue }
        context.saveGState()
        if let clipID = e.clipID, let mask = byID[clipID] {
          var t = mask.localTransform.cg
          context.addPath(VectorGeometry.path(mask).copy(using: &t) ?? VectorGeometry.path(mask))
          context.clip(using: mask.path?.evenOdd == true ? .evenOdd : .winding)
        }
        context.concatenate(e.localTransform.cg)
        context.setAlpha(e.opacity ?? 1)
        if e.kind == "group" {
          context.beginTransparencyLayer(auxiliaryInfo: nil)
          drawChildren(e.id)
          context.endTransparencyLayer()
        } else {
          drawElement(e, assets: assets, context: context)
        }
        context.restoreGState()
      }
    }
    drawChildren(nil)
    context.restoreGState()
  }
  public static func drawElement(_ e: ArtworkElement, assets: URL, context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: e.width, height: e.height)
    if e.kind == "text" {
      guard e.fillEnabled != false else { return }
      if let opacity = e.fillOpacity, opacity < 1 {
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.setAlpha(opacity)
        TypographyEngine.draw(e, in: context)
        context.restoreGState()
        context.endTransparencyLayer()
      } else {
        TypographyEngine.draw(e, in: context)
      }
      return
    }
    if e.kind == "image" {
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
      image.draw(
        in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high])
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
        if gradient.kind == "radial" {
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
    if let stroke = e.stroke ?? (e.kind == "line" ? ArtworkStroke(color: e.color) : nil),
      stroke.width > 0
    {
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
