import AppKit
import CoreImage
import CryptoKit
import FormCore

@MainActor public enum AppearanceRenderer {
  public static let maximumPixels = 16_000_000
  public static let maximumEdge = 8192
  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let coreImage = CIContext(options: [
    .workingColorSpace: colorSpace, .outputColorSpace: colorSpace, .cacheIntermediates: false,
  ])
  private final class Entry {
    let image: CGImage
    let bounds: CGRect
    init(_ image: CGImage, _ bounds: CGRect) { self.image = image; self.bounds = bounds }
  }
  private static let cache: NSCache<NSString, Entry> = {
    let value = NSCache<NSString, Entry>()
    value.totalCostLimit = 64_000_000
    value.countLimit = 400
    return value
  }()
  private static var builds = 0, hits = 0, limited = 0
  private static var lastMilliseconds = 0.0
  private static var lastError: String?
  public static var diagnostics: [String: Any] {
    ["builds": builds, "cache_hits": hits, "preview_scale_limits": limited,
      "last_build_ms": lastMilliseconds, "cache_limit_bytes": 64_000_000,
      "maximum_pixels": maximumPixels, "last_error": lastError ?? ""]
  }
  public static func invalidateFonts() { cache.removeAllObjects() }
  public static func blend(_ name: String?) -> CGBlendMode {
    switch name {
    case "multiply": return .multiply
    case "screen": return .screen
    case "overlay": return .overlay
    case "darken": return .darken
    case "lighten": return .lighten
    case "color-dodge": return .colorDodge
    case "color-burn": return .colorBurn
    case "hard-light": return .hardLight
    case "soft-light": return .softLight
    case "difference": return .difference
    case "exclusion": return .exclusion
    case "hue": return .hue
    case "saturation": return .saturation
    case "color": return .color
    case "luminosity": return .luminosity
    default: return .normal
    }
  }
  static func scale(_ transform: CGAffineTransform) -> Double {
    let p = transform.a * transform.a + transform.b * transform.b
    let q = transform.c * transform.c + transform.d * transform.d
    let r = transform.a * transform.c + transform.b * transform.d
    return sqrt(max(0, (p + q + sqrt((p - q) * (p - q) + 4 * r * r)) / 2))
  }
  static func scale(_ context: CGContext) -> Double {
    let origin = context.convertToDeviceSpace(CGPoint.zero)
    let x = context.convertToDeviceSpace(CGPoint(x: 1, y: 0))
    let y = context.convertToDeviceSpace(CGPoint(x: 0, y: 1))
    return scale(.init(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x,
      d: y.y - origin.y, tx: 0, ty: 0))
  }
  static func draw(_ e: ArtworkElement, signature: Data, bounds: () -> CGRect,
    context: CGContext, pixelsPerMM: Double?, content: (CGContext) -> Void) -> Bool {
    let requested = max(0.01, scale(context) * (pixelsPerMM ?? 1))
    let quantized = ceil((requested - 1e-7) * 4) / 4
    var data = signature
    data.append(Data("|\(quantized)".utf8))
    let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
    let entry: Entry
    if let existing = cache.object(forKey: key) { hits += 1; entry = existing }
    else {
      let start = CFAbsoluteTimeGetCurrent()
      let bounds = bounds()
      guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return false }
      let cap = min(Double(maximumEdge) / max(bounds.width, bounds.height),
        sqrt(Double(maximumPixels) / (bounds.width * bounds.height)))
      let density = min(quantized, cap)
      if requested > cap { limited += 1 }
      let width = max(1, Int(ceil(bounds.width * density)))
      let height = max(1, Int(ceil(bounds.height * density)))
      guard let bitmap = CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        lastError = "Could not allocate an appearance preview."
        return false
      }
      let output = CGRect(x: bounds.minX, y: bounds.minY,
        width: Double(width) / density, height: Double(height) / density)
      bitmap.translateBy(x: -output.minX * density, y: output.maxY * density)
      bitmap.scaleBy(x: density, y: -density)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
      content(bitmap)
      NSGraphicsContext.restoreGraphicsState()
      guard let source = bitmap.makeImage() else { return false }
      let extent = CGRect(x: 0, y: 0, width: width, height: height)
      var image = CIImage(cgImage: source, options: [.colorSpace: colorSpace])
      if let blur = e.blur, blur.enabled, blur.radius > 0 {
        image = image.applyingGaussianBlur(sigma: blur.radius * density).cropped(to: extent)
      }
      if let shadow = e.shadow, shadow.enabled, shadow.opacity > 0 {
        let color = FormColor.color(shadow.color).usingColorSpace(.sRGB)!
        let ink = CIImage(color: CIColor(red: color.redComponent, green: color.greenComponent,
          blue: color.blueComponent, alpha: shadow.opacity)).cropped(to: extent)
        let alpha = shadow.blur > 0
          ? image.applyingGaussianBlur(sigma: shadow.blur * density) : image
        let shade = ink.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha])
          .transformed(by: .init(translationX: shadow.offset.x * density, y: -shadow.offset.y * density))
        image = image.composited(over: shade).cropped(to: extent)
      }
      guard let filtered = coreImage.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
        lastError = "Could not render the layer's appearance."
        return false
      }
      entry = Entry(filtered, output)
      cache.setObject(entry, forKey: key, cost: width * height * 4)
      builds += 1
      lastError = nil
      lastMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    NSImage(cgImage: entry.image, size: entry.bounds.size).draw(in: entry.bounds,
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high])
    return true
  }
}

@MainActor final class ArtworkRenderTree {
  let art: Artwork
  let assets: URL
  let production: Bool
  let excluding: Set<UUID>
  let byID: [UUID: ArtworkElement]
  let children: [UUID?: [ArtworkElement]]
  let masks: Set<UUID>
  private var boxes: [UUID: CGRect] = [:]
  init(_ art: Artwork, assets: URL, production: Bool, excluding: Set<UUID>) {
    self.art = art; self.assets = assets; self.production = production; self.excluding = excluding
    byID = Dictionary(uniqueKeysWithValues: art.elements.map { ($0.id, $0) })
    children = Dictionary(grouping: art.elements, by: \.parentID)
    masks = Set(art.elements.compactMap(\.clipID))
  }
  func visible(_ e: ArtworkElement) -> Bool {
    e.hidden != true && (e.opacity ?? 1) > 0 && !excluding.contains(e.id) && !masks.contains(e.id)
      && (!production || e.productionRole == nil || ArtworkProductionRole.resolve(e.productionRole) == .print)
  }
  func displayed(_ e: ArtworkElement) -> Bool {
    guard visible(e) else { return false }
    var parent = e.parentID
    while let id = parent, let item = byID[id] {
      if !visible(item) { return false }
      parent = item.parentID
    }
    return true
  }
  func localBounds(_ e: ArtworkElement) -> CGRect {
    if let value = boxes[e.id] { return value }
    var box: CGRect
    if e.kind == "group" {
      box = .null
      for child in children[e.id] ?? [] where visible(child) {
        var value = localBounds(child).applying(child.localTransform.cg)
        if let id = child.clipID, let mask = byID[id] {
          value = value.intersection(VectorGeometry.path(mask).boundingBoxOfPath.applying(mask.localTransform.cg))
        }
        box = box.union(value)
      }
    } else if e.kind == "text" {
      box = (try? TypographyEngine.outlineRuns(e).reduce(CGRect.null) { $0.union($1.0.boundingBoxOfPath) }) ?? .null
    } else if e.kind == "image" { box = .init(x: 0, y: 0, width: e.width, height: e.height) }
    else {
      box = e.fillEnabled == false || e.kind == "line" ? .null : VectorGeometry.path(e).boundingBoxOfPath
      if e.visibleStroke != nil, let stroke = try? VectorGeometry.expandedStroke(e) {
        box = box.union(stroke.boundingBoxOfPath)
      }
    }
    if box.isNull || box.isEmpty { box = CGRect(x: 0, y: 0, width: max(0.01, e.width), height: max(0.01, e.height)) }
    if let blur = e.blur, blur.enabled { box = box.insetBy(dx: -blur.radius * 4, dy: -blur.radius * 4) }
    if let shadow = e.shadow, shadow.enabled, shadow.opacity > 0 {
      box = box.union(box.insetBy(dx: -shadow.blur * 4, dy: -shadow.blur * 4)
        .offsetBy(dx: shadow.offset.x, dy: shadow.offset.y))
    }
    boxes[e.id] = box
    return box
  }
  private func signature(_ root: ArtworkElement) -> Data {
    var source: [ArtworkElement] = []
    func collect(_ e: ArtworkElement) {
      source.append(e)
      for child in children[e.id] ?? [] { collect(child) }
    }
    collect(root)
    let ids = Dictionary(uniqueKeysWithValues: source.enumerated().map { index, e in
      (e.id, UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!)
    })
    for i in source.indices {
      source[i].id = ids[source[i].id]!
      source[i].parentID = source[i].parentID.flatMap { ids[$0] }
      source[i].clipID = source[i].clipID.flatMap { ids[$0] }
      source[i].name = nil; source[i].locked = nil
      source[i]=source[i].withBakedListNumbers
      if source[i].blur?.enabled != true { source[i].blur = nil }
      if source[i].shadow?.enabled != true { source[i].shadow = nil }
    }
    source[0].x = 0; source[0].y = 0; source[0].affine = nil
    source[0].rotation = nil; source[0].flipX = nil; source[0].flipY = nil
    source[0].parentID = nil; source[0].clipID = nil
    source[0].opacity = nil; source[0].blendMode = nil
    var data = (try? JSONEncoder.form.encode(source)) ?? Data()
    data.append(Data("|\(assets.path)|\(production)|\(excluding.sorted { $0.uuidString < $1.uuidString })".utf8))
    return data
  }
  func drawChildren(_ parent: UUID?, context: CGContext, effectScale: Double?) {
    for e in children[parent] ?? [] where visible(e) {
      context.saveGState()
      if let id = e.clipID, let mask = byID[id] {
        var map = mask.localTransform.cg
        context.addPath(VectorGeometry.path(mask).copy(using: &map) ?? VectorGeometry.path(mask))
        context.clip(using: mask.path?.evenOdd == true ? .evenOdd : .winding)
      }
      context.concatenate(e.localTransform.cg)
      context.setAlpha(e.opacity ?? 1)
      context.setBlendMode(AppearanceRenderer.blend(e.blendMode))
      let isolated = e.isolatedBlending == true || e.hasActiveEffects || (e.opacity ?? 1) < 1
        || (e.blendMode ?? "normal") != "normal"
      if isolated { context.beginTransparencyLayer(auxiliaryInfo: nil) }
      func content(_ target: CGContext, scale: Double?) {
        if e.kind == "group" { drawChildren(e.id, context: target, effectScale: scale) }
        else { ArtworkRenderer.drawElement(e, assets: assets, context: target) }
      }
      if !e.hasActiveEffects || !AppearanceRenderer.draw(e, signature: signature(e),
        bounds: { localBounds(e) }, context: context, pixelsPerMM: effectScale,
        content: { content($0, scale: nil) }) {
        content(context, scale: effectScale)
      }
      if isolated { context.endTransparencyLayer() }
      context.restoreGState()
    }
  }
}
