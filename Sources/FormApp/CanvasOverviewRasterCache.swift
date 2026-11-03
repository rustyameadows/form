import AppKit
import FormCore
import FormGraphics

/// Disposable display pixels for distant finite frames. The editable artwork,
/// close-up view, overlays and output paths always retain their native vectors.
@MainActor final class CanvasOverviewRasterCache {
  struct Presentation: Equatable {
    var size: CGSize
    var projection: CanvasSourceProjection? = nil
    var paperNet: PaperNet? = nil
    var paperColor: String? = nil
    var paperOpacity: Double? = nil
  }
  private struct Entry {
    var source: Artwork
    var assets: URL
    var excluding: Set<UUID>
    var presentation: Presentation
    var fonts: Int
    var image: CGImage
    var cost: Int
  }
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private let byteLimit: Int, entryLimit: Int
  private(set) var retainedBytes = 0
  private(set) var builds = 0, hits = 0
  var count: Int { entries.count }
  init(byteLimit: Int = 64*1024*1024, entryLimit: Int = 512) {
    self.byteLimit = byteLimit; self.entryLimit = entryLimit
  }
  func clear() { entries = [:]; order = []; retainedBytes = 0 }
  func retain(_ ids: Set<UUID>) {
    for id in Array(entries.keys) where !ids.contains(id) { remove(id) }
  }
  private func remove(_ id: UUID) {
    if let entry = entries.removeValue(forKey: id) { retainedBytes -= entry.cost }
    order.removeAll { $0 == id }
  }
  func image(frameID: UUID, source: Artwork, assets: URL, excluding: Set<UUID>,
    presentation: Presentation, zoom: Double, pixelsPerMM: Double,
    render: (CGContext) -> Void) -> CGImage? {
    guard zoom.isFinite, zoom > 0, zoom <= 0.3, pixelsPerMM.isFinite, pixelsPerMM > 0,
      presentation.size.width.isFinite, presentation.size.height.isFinite,
      presentation.size.width > 0, presentation.size.height > 0, entryLimit > 0 else { return nil }
    // Two density buckets per octave retain backing-resolution detail without
    // rebuilding every visible frame for each tiny trackpad zoom change.
    let density = pow(2, ceil(log2(pixelsPerMM)*2)/2)
    let w = ceil(presentation.size.width*density), h = ceil(presentation.size.height*density)
    guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 2048, h <= 2048,
      w*h <= 4_194_304, w*h*4 <= Double(byteLimit) else { return nil }
    let width = Int(w), height = Int(h), cost = width*height*4
    var local = source; local.canvasPosition = nil
    let fonts = ArtworkRenderer.displayFontGeneration
    if let entry = entries[frameID], entry.source == local, entry.assets == assets,
      entry.excluding == excluding, entry.presentation == presentation, entry.fonts == fonts,
      entry.image.width >= width, entry.image.height >= height {
      hits += 1; order.removeAll { $0 == frameID }; order.append(frameID)
      return entry.image
    }
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: CGFloat(width)/presentation.size.width, y: -CGFloat(height)/presentation.size.height)
    let rect = CGRect(origin: .zero, size: presentation.size)
    context.clip(to: rect)
    // Finite Canvas frames already have a white backing. Capture it with the
    // artwork so pass-through fill/group blending has the same backdrop.
    context.setFillColor(NSColor.white.cgColor); context.fill(rect)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    render(context)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { return nil }
    remove(frameID)
    while retainedBytes+cost > byteLimit || entries.count >= entryLimit {
      guard let first = order.first else { break }; remove(first)
    }
    entries[frameID] = .init(source: local, assets: assets, excluding: excluding,
      presentation: presentation, fonts: fonts, image: image, cost: cost)
    retainedBytes += cost; order.append(frameID); builds += 1
    return image
  }
  static func draw(_ image: CGImage, size: CGSize, context: CGContext) {
    context.saveGState(); defer { context.restoreGState() }
    context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
  }
}
