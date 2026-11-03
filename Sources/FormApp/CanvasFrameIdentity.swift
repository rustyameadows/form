import AppKit
import FormGraphics

/// Interface identity of a view, independent of its artwork and physical owner.
enum CanvasFrameRole: String, CaseIterable {
  case artboard, construction, surface

  var title: String {
    switch self {
    case .artboard: return "Artboards"
    case .construction: return "Dielines & patterns"
    case .surface: return "Projected surfaces"
    }
  }
  var symbolName: String {
    switch self {
    case .artboard: return "rectangle"
    case .construction: return "scissors"
    case .surface: return "link"
    }
  }
  var defaultHex: String {
    switch self {
    case .artboard: return "#3D4148"
    case .construction: return "#376BB0"
    case .surface: return "#AD5145"
    }
  }
}

extension CanvasFrame {
  var role: CanvasFrameRole {
    if isWorkspace { return .artboard }
    if let projection { return projection.isProof ? .construction : .surface }
    if legacyDieline || artwork.elements.contains(where: { $0.sewingPiece != nil }) { return .construction }
    return .artboard
  }
}

@MainActor enum CanvasFrameChrome {
  static let headerHeight = 16.0
  static let iconSize = 10.0
  static let iconGap = 4.0
  static let fontSize = 9.0
  private struct Symbol { var color: NSColor; var image: NSImage }
  private static var symbols: [CanvasFrameRole: Symbol] = [:]
  private struct HeaderKey: Hashable {
    var title: String, role: CanvasFrameRole
    var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    var width: Int, density: Double, fonts: Int
  }
  private struct HeaderImage { var image: CGImage, cost: Int }
  private static var headers: [HeaderKey: HeaderImage] = [:]
  private static var headerOrder: [HeaderKey] = []
  private(set) static var headerCacheBytes = 0, headerCacheBuilds = 0, headerCacheHits = 0
  static func clearHeaderCache() {
    headers = [:]; headerOrder = []; headerCacheBytes = 0
  }

  static func headerRect(for frame: CanvasFrame, scale: Double) -> CGRect {
    .init(x: frame.rect.minX, y: frame.rect.minY-headerHeight/scale,
      width: frame.rect.width, height: headerHeight/scale)
  }

  static func drawHeader(_ frame: CanvasFrame, context: CGContext, scale: Double,
    appearance: InterfaceAppearance? = nil) {
    guard !frame.isWorkspace, scale > 0, frame.rect.width > 0 else { return }
    let color = (appearance ?? .shared).frameColor(for: frame.role)
    let header = headerRect(for: frame, scale: scale)
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: header)
    let title = frame.title.uppercased(), width = header.width*scale
    let origin = context.convertToDeviceSpace(CGPoint.zero)
    let unit = context.convertToDeviceSpace(CGPoint(x: 1,y: 0))
    let density = max(1,ceil(hypot(unit.x-origin.x,unit.y-origin.y)/scale*4-1e-6)/4)
    if let image = headerImage(title: title, role: frame.role, color: color, width: width, density: density) {
      context.translateBy(x: header.minX,y: header.maxY); context.scaleBy(x: 1,y: -1)
      context.interpolationQuality = .high
      context.draw(image,in: CGRect(origin: .zero,size: header.size))
      return
    }
    context.translateBy(x: header.minX,y: header.minY); context.scaleBy(x: 1/scale,y: 1/scale)
    drawContents(title: title, role: frame.role, color: color, width: width)
  }

  private static func headerImage(title: String, role: CanvasFrameRole, color: NSColor,
    width: Double, density: Double) -> CGImage? {
    let pixels = ceil(width*density)
    guard width.isFinite, width > 0, density.isFinite, density <= 4,
      pixels > 0, pixels <= 4096, let rgb = color.usingColorSpace(.sRGB) else { return nil }
    let key = HeaderKey(title: title,role: role,red: rgb.redComponent,green: rgb.greenComponent,
      blue: rgb.blueComponent,alpha: rgb.alphaComponent,width: Int(pixels),density: density,
      fonts: ArtworkRenderer.displayFontGeneration)
    if let cached = headers[key] {
      headerCacheHits += 1; headerOrder.removeAll { $0 == key }; headerOrder.append(key)
      return cached.image
    }
    let height = Int(ceil(headerHeight*density))
    guard let context = CGContext(data: nil,width: Int(pixels),height: height,bitsPerComponent: 8,
      bytesPerRow: Int(pixels)*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.translateBy(x: 0,y: CGFloat(height)); context.scaleBy(x: density,y: -density)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true)
    drawContents(title: title,role: role,color: color,width: pixels/density)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { return nil }
    let cost = image.bytesPerRow*image.height
    while headerCacheBytes+cost > 8*1024*1024 || headers.count >= 512 {
      guard let first = headerOrder.first else { break }
      headerOrder.removeFirst()
      if let old = headers.removeValue(forKey: first) { headerCacheBytes -= old.cost }
    }
    headers[key] = .init(image: image,cost: cost); headerOrder.append(key)
    headerCacheBytes += cost; headerCacheBuilds += 1
    return image
  }

  private static func drawContents(title: String, role: CanvasFrameRole, color: NSColor, width: Double) {
    let icon = CGRect(x: 0,y: 3,width: min(iconSize,width),height: iconSize)
    symbol(for: role, color: color)?.draw(in: icon, from: .zero,
      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let textX = iconSize+iconGap
    guard textX < width else { return }
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
    let rect = CGRect(x: textX,y: 1,width: width-textX,height: 14)
    (title as NSString).draw(in: rect, withAttributes: [
      .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
      .foregroundColor: color, .paragraphStyle: paragraph,
    ])
  }

  private static func symbol(for role: CanvasFrameRole, color: NSColor) -> NSImage? {
    if let cached = symbols[role], cached.color == color { return cached.image }
    guard let original = NSImage(systemSymbolName: role.symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) else { return nil }
    let image = NSImage(size: .init(width: 16, height: 16), flipped: false) { bounds in
      original.draw(in: bounds)
      color.setFill(); bounds.fill(using: .sourceIn)
      return true
    }
    image.isTemplate = false
    symbols[role] = .init(color: color, image: image)
    return image
  }
}
