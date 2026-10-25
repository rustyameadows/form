import AppKit
import CoreGraphics
import FormCore

/// Translates and clips the authoritative vector PDF page; it never fits or reflows source content.
@MainActor public struct SewingTileOutput {
  public let source: SewingPatternOutput
  public let plan: SewingTilePlan
  public init(source: SewingPatternOutput, options: SewingTileOptions) throws {
    self.source = source
    plan = try SewingTilePlan(sourceSize: source.plan.frameSize, options: options)
  }
  public var metadata: [String: Any] {
    var result = source.metadata
    result["tiled"] = plan.metadata
    return result
  }
  public func pdf(assets: URL, dpi: Double = 150, name: String = "Sewing pattern") throws -> Data {
    // Bound repeated rendering independently of page count and raster-effect density.
    let cost = source.combinedArtwork.elements.reduce(0) { partial, e in
      partial + max(4, e.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? e.text.count * 16)
    }
    guard cost * plan.tiles.count <= 8_000_000 else {
      throw FormError.invalid(
        "The tiled pattern exceeds the bounded vector work budget. Use a larger sheet or the unchanged large-format PDF."
      )
    }
    let original = try source.pdf(assets: assets, dpi: dpi)
    guard original.count <= 32 * 1024 * 1024,
      let provider = CGDataProvider(data: original as CFData),
      let document = CGPDFDocument(provider),
      let page = document.page(at: 1)
    else {
      throw FormError.invalid(
        "The authoritative vector pattern page could not be read within its 32 MiB source limit.")
    }
    let k = TypographyEngine.pointsPerMM
    let sheet = plan.options.sheetSize
    var media = CGRect(x: 0, y: 0, width: sheet.x * k, height: sheet.y * k)
    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output),
      let context = CGContext(
        consumer: consumer, mediaBox: &media,
        [
          kCGPDFContextTitle as String: String(name.prefix(200)) + " / tiled sewing pattern",
          kCGPDFContextCreator as String: "FORM",
          kCGPDFContextSubject as String:
            "100% physical scale. Print at actual size; verify the 50 mm square and 100 mm rule. Declared margins are not measured printer capabilities. Trim paper using paired gutter ticks and butt matching labeled edges.",
        ] as CFDictionary)
    else {
      throw FormError.invalid("Could not create tiled sewing PDF.")
    }
    func boxData(_ rect: CGRect) -> Data {
      var rect = rect
      return Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
    }
    func paper(_ rect: Rect2) -> CGRect {
      .init(
        x: rect.x * k, y: (sheet.y - rect.maxY) * k, width: rect.width * k, height: rect.height * k)
    }
    func begin(trim: CGRect) {
      context.beginPDFPage(
        [
          kCGPDFContextMediaBox as String: boxData(media),
          kCGPDFContextCropBox as String: boxData(media),
          kCGPDFContextTrimBox as String: boxData(trim),
        ] as CFDictionary)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(media)
    }
    func millimeters(_ draw: () -> Void) {
      context.saveGState()
      context.translateBy(x: 0, y: sheet.y * k)
      context.scaleBy(x: k, y: -k)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      draw()
      NSGraphicsContext.restoreGraphicsState()
      context.restoreGState()
    }
    begin(trim: media)
    millimeters { drawCover(context, name: name) }
    context.endPDFPage()
    for tile in plan.tiles {
      begin(trim: paper(tile.trimOnSheet))
      context.saveGState()
      context.clip(to: paper(tile.contentOnSheet))
      context.translateBy(
        x: (tile.contentOnSheet.x - tile.sourceRect.x) * k,
        y: (sheet.y - tile.contentOnSheet.y - plan.sourceSize.y + tile.sourceRect.y) * k)
      context.drawPDFPage(page)
      context.restoreGState()
      millimeters { drawAssembly(context, tile: tile) }
      context.endPDFPage()
      if output.length > 128 * 1024 * 1024 {
        context.closePDF()
        throw FormError.invalid(
          "The tiled PDF exceeds 128 MiB. Use a larger sheet or the large-format output.")
      }
    }
    context.closePDF()
    guard output.length <= 128 * 1024 * 1024 else {
      throw FormError.invalid("The completed tiled PDF exceeds 128 MiB. Use a larger sheet or the large-format output.")
    }
    return output as Data
  }
  private func text(
    _ value: String, _ rect: Rect2, size: Double = 9, color: NSColor = .black, bold: Bool = false
  ) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    let font = NSFont.systemFont(
      ofSize: size / TypographyEngine.pointsPerMM, weight: bold ? .semibold : .regular)
    (value as NSString).draw(
      in: .init(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
      withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
  }
  private func drawCover(_ context: CGContext, name: String) {
    let o = plan.options
    let left = o.margins.left + SewingTileOptions.markGutter
    let top = o.margins.top + SewingTileOptions.markGutter
    let width = o.contentSize.x
    text("FORM / TILED SEWING PATTERN", .init(left, top, width, 8), size: 13, bold: true)
    text(String(name.prefix(100)), .init(left, top + 9, width, 13), size: 10)
    text(
      String(
        format: "Source %.1f × %.1f mm · %d rows × %d columns · %d tiles + this calibration sheet",
        plan.sourceSize.x, plan.sourceSize.y, plan.rows, plan.columns, plan.tiles.count),
      .init(left, top + 22, width, 12), size: 8)
    context.setStrokeColor(NSColor.black.cgColor)
    context.setLineWidth(0.2)
    context.stroke(.init(x: left, y: top + 39, width: 50, height: 50))
    text("50 × 50 mm", .init(left + 3, top + 58, 44, 10), size: 11, bold: true)
    text(
      "Print this page at 100% / actual size. Measure both square directions before assembling the pattern. Do not use Fit or Shrink.",
      .init(left + 56, top + 39, width - 56, 45), size: 9)
    text(
      "Match row/column labels. Cut straight between paired gray gutter ticks; butt matching trimmed edges and tape. Overlap is repeated reference. Black cut and blue stitch geometry stay at full scale.",
      .init(left, top + 95, width, 22), size: 9)
    let y = top + 124
    context.move(to: .init(x: left, y: y))
    context.addLine(to: .init(x: left + 100, y: y))
    for tick in stride(from: 0, through: 100, by: 25) {
      let x = left + Double(tick)
      context.move(to: .init(x: x, y: y - 2))
      context.addLine(to: .init(x: x, y: y + 2))
    }
    context.strokePath()
    text("100 mm rule", .init(left, y + 4, width, 6), size: 8)
    text(
      "Margins are declared for your own printer; no device imageable area is assumed. Every source label, guide, note and final partial tile is preserved.",
      .init(left, top + 137, width, max(9, o.contentSize.y - 137)), size: 8)
  }
  private func drawAssembly(_ context: CGContext, tile: SewingTile) {
    let o = plan.options
    let r = tile.trimOnSheet
    let ink = tile.contentOnSheet
    context.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
    context.setLineWidth(0.12)
    // Paired gutter ticks locate the four trim lines without crossing the source.
    for x in [r.x, r.maxX] {
      for (a, b) in [(ink.y - 2.4, ink.y - 0.6), (ink.maxY + 0.6, ink.maxY + 2.4)] {
        context.move(to: .init(x: x, y: a))
        context.addLine(to: .init(x: x, y: b))
      }
    }
    for y in [r.y, r.maxY] {
      for (a, b) in [(ink.x - 2.4, ink.x - 0.6), (ink.maxX + 0.6, ink.maxX + 2.4)] {
        context.move(to: .init(x: a, y: y))
        context.addLine(to: .init(x: b, y: y))
      }
    }
    for join in plan.joins(for: tile) {
      for point in join.sourcePoints {
        let x = ink.x + point.x - tile.sourceRect.x
        let y = ink.y + point.y - tile.sourceRect.y
        context.move(to: .init(x: x - 1.1, y: y))
        context.addLine(to: .init(x: x + 1.1, y: y))
        context.move(to: .init(x: x, y: y - 1.1))
        context.addLine(to: .init(x: x, y: y + 1.1))
      }
    }
    context.strokePath()
    let footer = o.sheetSize.y - o.margins.bottom - SewingTileOptions.footerHeight
    text(
      "\(tile.id) · PDF page \(tile.pdfPage)/\(plan.pageCount) · 100% / actual size",
      .init(o.margins.left, footer + 1, o.contentSize.x, 5), size: 8, bold: true)
    let joins = plan.joins(for: tile).map { $0.edge.rawValue + " " + $0.label }.joined(
      separator: " · ")
    text(
      joins.isEmpty ? "One tile: trim straight between paired gray gutter ticks." : joins,
      .init(o.margins.left, footer + 6, o.contentSize.x, 6), size: 7)
  }
}
