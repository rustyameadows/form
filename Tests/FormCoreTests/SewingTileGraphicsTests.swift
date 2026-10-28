import AppKit
import XCTest

@testable import FormCore
@testable import FormGraphics

@MainActor final class SewingTileGraphicsTests: XCTestCase {
  private func output(_ options: SewingTileOptions = .init()) throws -> SewingTileOutput {
    let template = try SewingPatternTemplates.roundedPouch([
      "width": 360, "height": 250, "corner_radius": 80,
    ])
    return try SewingTileOutput(
      source: SewingPatternOutput(source: template.artwork), options: options)
  }
  private func document(_ data: Data) throws -> CGPDFDocument {
    try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
  }
  private func render(_ page: CGPDFPage, density: Double = 4) throws -> NSBitmapImageRep {
    let box = page.getBoxRect(.mediaBox)
    let k = TypographyEngine.pointsPerMM
    let w = Int(ceil(box.width / k * density))
    let h = Int(ceil(box.height / k * density))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(.init(x: 0, y: 0, width: w, height: h))
    context.scaleBy(x: density / k, y: density / k)
    context.drawPDFPage(page)
    return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
  }
  private func rgb(
    _ image: NSBitmapImageRep, x: Double, y: Double, pageHeight: Double, density: Double = 4
  ) -> [Double] {
    let ix = min(image.pixelsWide - 1, max(0, Int((x * density).rounded(.down))))
    // NSBitmapImageRep rows are top-origin even though PDF drawing uses bottom-origin coordinates.
    let iy = min(image.pixelsHigh - 1, max(0, Int((y * density).rounded(.down))))
    let color = image.colorAt(x: ix, y: iy)!.usingColorSpace(.deviceRGB)!
    return [color.redComponent, color.greenComponent, color.blueComponent]
  }
  func testEveryMediaCropAndPhysicalTrimBoxMatchesA4LetterOrCustomPlan() throws {
    for options in [
      SewingTileOptions(), .init(sheetSize: SewingTileOptions.letter),
      .init(
        sheetSize: .init(250, 350), margins: .init(top: 8, right: 12, bottom: 9, left: 14),
        overlap: 8),
    ] {
      let out = try output(options)
      let data = try out.pdf(assets: FileManager.default.temporaryDirectory)
      let doc = try document(data)
      XCTAssertEqual(doc.numberOfPages, out.plan.pageCount)
      let k = TypographyEngine.pointsPerMM
      for index in 1...doc.numberOfPages {
        let page = try XCTUnwrap(doc.page(at: index))
        let media = page.getBoxRect(.mediaBox)
        XCTAssertEqual(media.width, options.sheetSize.x * k, accuracy: 0.002)
        XCTAssertEqual(media.height, options.sheetSize.y * k, accuracy: 0.002)
        XCTAssertEqual(page.getBoxRect(.cropBox), media)
        if index > 1 {
          let trim = out.plan.tiles[index - 2].trimOnSheet
          let box = page.getBoxRect(.trimBox)
          XCTAssertEqual(box.minX, trim.x * k, accuracy: 0.002)
          XCTAssertEqual(box.minY, (options.sheetSize.y - trim.maxY) * k, accuracy: 0.002)
          XCTAssertEqual(box.width, trim.width * k, accuracy: 0.002)
          XCTAssertEqual(box.height, trim.height * k, accuracy: 0.002)
        }
      }
      XCTAssertNil(
        String(decoding: data, as: UTF8.self).range(
          of: "/Subtype\\s*/Image", options: .regularExpression),
        "Technical contours must not become raster images while tiling.")
    }
  }
  func testMatchingAssemblyEdgesHaveTheSamePhysicalRegistrationCoordinates() throws {
    let p = try output().plan
    var pairs: [String: [SewingTileJoin]] = [:]
    for tile in p.tiles {
      for join in p.joins(for: tile) { pairs[join.label, default: []].append(join) }
    }
    XCTAssertFalse(pairs.isEmpty)
    for joins in pairs.values {
      XCTAssertEqual(joins.count, 2)
      for (a, b) in zip(joins[0].sourcePoints, joins[1].sourcePoints) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
      }
    }
  }
  func testTranslatedTilesPreserveActualVectorInkAcrossFirstLastAndOverlapRegions() throws {
    let out = try output()
    let assets = FileManager.default.temporaryDirectory
    let doc = try document(out.pdf(assets: assets))
    let original = try document(out.source.pdf(assets: assets))
    let reference = try render(original.page(at: 1)!)
    var samples = 0
    var ink = 0
    var error = 0.0
    var overlapInk = 0
    for tile in out.plan.tiles {
      let image = try render(doc.page(at: tile.pdfPage)!)
      let trim = tile.trimSourceRect
      for y in stride(from: tile.sourceRect.y + 0.5, to: tile.sourceRect.maxY - 0.5, by: 2) {
        for x in stride(from: tile.sourceRect.x + 0.5, to: tile.sourceRect.maxX - 0.5, by: 2) {
          let a = rgb(reference, x: x, y: y, pageHeight: out.plan.sourceSize.y)
          let b = rgb(
            image, x: tile.contentOnSheet.x + x - tile.sourceRect.x,
            y: tile.contentOnSheet.y + y - tile.sourceRect.y,
            pageHeight: out.plan.options.sheetSize.y)
          let difference = zip(a, b).reduce(0.0) { $0 + abs($1.0 - $1.1) }
          error += difference
          samples += 3
          if a.min()! < 0.8 {
            ink += 1
            if x < trim.x || x > trim.maxX || y < trim.y || y > trim.maxY { overlapInk += 1 }
          }
        }
      }
    }
    XCTAssertGreaterThan(ink, 100)
    XCTAssertGreaterThan(overlapInk, 1)
    XCTAssertLessThan(
      error / Double(samples), 0.004,
      "The authoritative source page must translate without scale, drift or lost vector ink.")
  }
  func testCalibrationPageIsSeparateAndVectorPDFPreservesSourceAndDPIIndependentGeometry() throws {
    let template = try SewingPatternTemplates.roundedPouch()
    let before = template.artwork
    let source = try SewingPatternOutput(source: before)
    let out = try SewingTileOutput(source: source, options: .init())
    let low = try out.pdf(assets: FileManager.default.temporaryDirectory, dpi: 72)
    let high = try out.pdf(assets: FileManager.default.temporaryDirectory, dpi: 600)
    XCTAssertEqual(try document(low).numberOfPages, try document(high).numberOfPages)
    XCTAssertEqual(out.plan.tiles.first!.pdfPage, 2)
    XCTAssertEqual(out.plan.metadata["calibration_square_mm"] as? Int, 50)
    XCTAssertEqual(out.plan.metadata["calibration_rule_mm"] as? Int, 100)
    XCTAssertEqual(template.artwork, before)
    if let path = ProcessInfo.processInfo.environment["FORM_SEWING_TILE_PROOF_DIR"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try high.write(to: folder.appendingPathComponent("rounded-pouch-a4-tiled.pdf"))
      try source.pdf(assets: FileManager.default.temporaryDirectory).write(
        to: folder.appendingPathComponent("rounded-pouch-authoritative.pdf"))
      try JSONSerialization.data(
        withJSONObject: out.metadata, options: [.prettyPrinted, .sortedKeys]
      ).write(to: folder.appendingPathComponent("tiled-metadata.json"))
    }
  }
}
