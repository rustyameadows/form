import AppKit

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
    let width = min(iconSize/scale, header.width)
    let icon = CGRect(x: header.minX, y: frame.rect.minY-13/scale, width: width, height: iconSize/scale)
    symbol(for: frame.role, color: color)?.draw(in: icon, from: .zero,
      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let textX = header.minX+(iconSize+iconGap)/scale
    guard textX < header.maxX else { return }
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
    let rect = CGRect(x: textX, y: frame.rect.minY-15/scale,
      width: header.maxX-textX, height: 14/scale)
    (frame.title.uppercased() as NSString).draw(in: rect, withAttributes: [
      .font: NSFont.systemFont(ofSize: fontSize/scale, weight: .medium),
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
