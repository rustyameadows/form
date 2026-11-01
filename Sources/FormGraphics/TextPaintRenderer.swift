import AppKit
import CoreText
import CryptoKit
import FormCore

/// Paints live shaped text without replacing its characters or fonts with paths.
/// Vector glyph coverage is transient; bitmap/color fonts use bounded alpha masks.
@MainActor public enum TextPaintRenderer {
  private final class Coverage {
    let image: CGImage
    let bounds: CGRect
    init(_ image: CGImage, _ bounds: CGRect) { self.image = image; self.bounds = bounds }
  }
  private static let cache: NSCache<NSString, Coverage> = {
    let value = NSCache<NSString, Coverage>(); value.countLimit = 256; value.totalCostLimit = 64_000_000; return value
  }()
  public static func invalidateFonts() { cache.removeAllObjects() }
  /// Linked frames retain geometry, while their current ink comes from the
  /// shared story. Never write these transient source attributes onto a frame.
  private static func effectivePaints(_ element: ArtworkElement) -> ArtworkElement {
    guard let story=element.storyFrame?.resolved?.story else{return element}
    var result=element
    result.paintStack=story.paintStack;result.textRuns=story.textRuns;result.color=story.color
    return result
  }
  public static func usesPaints(_ element: ArtworkElement) -> Bool {
    let element=effectivePaints(element)
    return element.kind == "text" && (element.paintStack != nil || element.textRuns?.contains { $0.paintStack != nil } == true)
  }
  private static func groups(_ element: ArtworkElement) -> [[ArtworkPaintLayer]?] {
    var groups: [[ArtworkPaintLayer]?] = [element.paintStack]
    for span in element.textRuns ?? [] {
      let stack = span.paintStack ?? element.paintStack
      if !groups.contains(where: { $0 == stack }) { groups.append(stack) }
    }
    return groups
  }
  private static func glyphPath(_ element: ArtworkElement, stack: [ArtworkPaintLayer]?) throws -> CGPath {
    let path = CGMutablePath()
    for run in try TypographyEngine.outlinePaintRuns(element, matchingPaintStack: stack, filtering: true) { path.addPath(run.path) }
    return path
  }
  private static func strokePath(_ path: CGPath, stroke: ArtworkStroke) throws -> CGPath {
    guard stroke.width.isFinite, stroke.width >= 0 else { throw FormError.invalid("Invalid live text stroke width.") }
    let inside = stroke.alignment == "inside", outside = stroke.alignment == "outside"
    let line = (stroke.dash?.isEmpty == false)
      ? path.copy(dashingWithPhase: stroke.dashOffset ?? 0, lengths: stroke.dash!.map { CGFloat($0) }) : path
    let edge = line.copy(strokingWithWidth: stroke.width * (inside || outside ? 2 : 1),
      lineCap: VectorGeometry.cap(stroke.cap), lineJoin: VectorGeometry.join(stroke.join), miterLimit: stroke.miter ?? 10)
    if inside { return edge.intersection(path) }
    if outside { return edge.subtracting(path) }
    return edge
  }
  /// SVG/vector export uses exactly the same shaped paint groups as the canvas.
  /// Fonts without vector glyph outlines fail explicitly; native preview remains live.
  public static func vectorLayers(_ element: ArtworkElement) throws -> [(CGPath, ArtworkPaint)] {
    let element=effectivePaints(element)
    var result: [(CGPath, ArtworkPaint)] = []
    for stack in groups(element) {
      guard let stack else {
        if element.fillEnabled != false {
          for run in try TypographyEngine.outlinePaintRuns(element, matchingPaintStack: nil, filtering: true) {
            result.append((run.path, .init(color: run.color, opacity: element.fillOpacity ?? 1)))
          }
        }
        continue
      }
      guard stack.contains(where: { $0.enabled && $0.effectivePaint.opacity > 0 && ($0.stroke == nil || ($0.stroke?.enabled != false && ($0.stroke?.width ?? 0)>0)) }) else { continue }
      let glyphs = try glyphPath(element, stack: stack)
      guard !glyphs.isEmpty else { continue }
      for layer in stack where layer.enabled && layer.effectivePaint.opacity > 0 {
        if let stroke = layer.stroke {
          guard stroke.enabled != false, stroke.width > 0 else { continue }
          let coverage = try strokePath(glyphs, stroke: stroke)
          if !coverage.isEmpty { result.append((coverage, layer.effectivePaint)) }
        } else { result.append((glyphs, layer.effectivePaint)) }
      }
    }
    return result
  }
  public static func validateOutput(_ element: ArtworkElement) throws {
    let element=effectivePaints(element)
    guard usesPaints(element) else { return }
    for stack in groups(element).compactMap({ $0 }) where stack.contains(where: { $0.enabled && $0.effectivePaint.opacity > 0 && $0.stroke?.enabled != false && ($0.stroke?.width ?? 0) > 0 }) {
      _ = try glyphPath(element, stack: stack)
    }
  }
  public static func draw(_ element: ArtworkElement, assets: URL, context: CGContext) {
    let element=effectivePaints(element)
    context.saveGState();defer{context.restoreGState()}
    if element.storyFrame != nil {context.clip(to:.init(x:0,y:0,width:element.width,height:element.height))}
    for stack in groups(element) {
      guard let stack else {
        guard element.fillEnabled != false else { continue }
        context.saveGState(); context.setAlpha(element.fillOpacity ?? 1)
        TypographyEngine.drawPaintGroup(element, stack: nil, in: context)
        context.restoreGState(); continue
      }
      if stack.isEmpty { continue }
      let path = try? glyphPath(element, stack: stack)
      // Empty shaped coverage is valid for whitespace, overset frames and a
      // base paint entirely replaced by character overrides. Quartz clipping
      // with no current path does not install an empty clip; painting afterward
      // would fill the enclosing canvas/group instead of drawing no glyphs.
      if let path, path.isEmpty { continue }
      var bitmap: Coverage?
      for layer in stack where layer.enabled && layer.effectivePaint.opacity > 0 {
        context.saveGState()
        defer { context.restoreGState() }
        if let stroke = layer.stroke {
          guard stroke.enabled != false, stroke.width > 0, let path,
            let coverage = try? strokePath(path, stroke: stroke), !coverage.isEmpty else { continue }
          context.addPath(coverage); context.clip()
        } else if let path {
          context.addPath(path); context.clip()
        } else {
          if bitmap == nil { bitmap = coverage(element, stack: stack, context: context) }
          guard let bitmap else { continue }
          // Quartz image rows are bottom-up in a flipped canvas. Restore the
          // user transform after installing the clip, keeping only its coverage.
          let box = bitmap.bounds
          context.translateBy(x: box.minX, y: box.maxY); context.scaleBy(x: 1, y: -1)
          context.clip(to: .init(origin: .zero, size: box.size), mask: bitmap.image)
          context.scaleBy(x: 1, y: -1); context.translateBy(x: -box.minX, y: -box.maxY)
        }
        _ = ArtworkPaintRenderer.draw(layer.effectivePaint, size: .init(width: element.width, height: element.height), assets: assets, context: context)
      }
    }
  }
  private static func coverage(_ element: ArtworkElement, stack: [ArtworkPaintLayer], context: CGContext) -> Coverage? {
    let bounds = CGRect(x: 0, y: 0, width: element.width, height: element.height)
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
    let requested = max(0.25, ceil(AppearanceRenderer.scale(context) * 4) / 4)
    let cap = min(Double(AppearanceRenderer.maximumEdge) / max(bounds.width, bounds.height),
      sqrt(Double(AppearanceRenderer.maximumPixels) / (bounds.width * bounds.height)))
    let density = min(requested, cap)
    let width = max(1, Int(ceil(bounds.width * density))), height = max(1, Int(ceil(bounds.height * density)))
    var source = element; source.sourceMetadata = nil; source.x = 0; source.y = 0; source.affine = nil
    var signature = (try? JSONEncoder.form.encode(source)) ?? Data()
    signature.append((try? JSONEncoder.form.encode(stack)) ?? Data())
    if let reference=element.storyFrame {
      signature.append((try? JSONEncoder.form.encode(reference.resolved)) ?? Data())
      signature.append((try? JSONEncoder.form.encode(reference.frame)) ?? Data())
    }
    signature.append(Data("|\(width)x\(height)".utf8))
    let key = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined() as NSString
    if let value = cache.object(forKey: key) { return value }
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
    bitmap.translateBy(x: 0, y: Double(height)); bitmap.scaleBy(x: density, y: -density)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
    TypographyEngine.drawPaintGroup(element, stack: stack, in: bitmap)
    NSGraphicsContext.restoreGraphicsState()
    guard let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var alpha = Data(count: width * height)
    alpha.withUnsafeMutableBytes { output in
      let pointer = output.bindMemory(to: UInt8.self)
      for index in 0..<(width * height) { pointer[index] = bytes[index * 4 + 3] }
    }
    guard let provider = CGDataProvider(data: alpha as CFData), let mask = CGImage(width: width, height: height,
      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent) else { return nil }
    let value = Coverage(mask, .init(x: 0, y: 0, width: Double(width) / density, height: Double(height) / density))
    cache.setObject(value, forKey: key, cost: width * height); return value
  }
}
