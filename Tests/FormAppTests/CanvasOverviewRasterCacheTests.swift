import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasOverviewRasterCacheTests: XCTestCase {
  private let assets = FileManager.default.temporaryDirectory
  private func bytes(_ image: CGImage) throws -> Data {
    try XCTUnwrap(image.dataProvider?.data) as Data
  }
  private func bitmap(size: CGSize, draw: (CGContext) -> Void) throws -> CGImage {
    let c = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
      bitsPerComponent: 8, bytesPerRow: Int(size.width)*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.translateBy(x: 0,y: size.height); c.scaleBy(x: 1,y: -1)
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c,flipped: true)
    draw(c)
    return try XCTUnwrap(c.makeImage())
  }
  func testOverviewPixelsPreserveClippedPaperBackdropBlendAndTextOrientation() throws {
    var mask = ArtworkElement(kind: "ellipse", x: 3,y: 3,width: 52,height: 38,color: "#FFFFFF")
    mask.hidden = true; mask.opacity = 0.7
    var group = ArtworkElement(kind: "group",x: 0,y: 0,width: 64,height: 48)
    group.clipID = mask.id; group.clipMode = "alpha"; group.opacity = 0.75
    var red = ArtworkElement(kind: "rectangle",x: -5,y: 0,width: 60,height: 48,color: "#B43921")
    red.parentID = group.id; red.blendMode = "multiply"
    var label = ArtworkElement(kind: "text",x: 10,y: 9,width: 42,height: 20,text: "NORTH",fontSize: 9)
    label.color = "#FAF2DD"
    let art = Artwork(background: "#FFFFFF",elements: [mask,group,red,label])
    let size = CGSize(width: 64,height: 48)
    let presentation = CanvasOverviewRasterCache.Presentation(size: size,paperColor: "#D9C7A2",paperOpacity: 0.8)
    func contents(_ c: CGContext, prepared: Bool) throws {
      c.saveGState(); defer { c.restoreGState() }
      c.addPath(CGPath(roundedRect: .init(x: 2,y: 1,width: 60,height: 44),cornerWidth: 8,cornerHeight: 8,transform: nil))
      c.clip()
      c.setFillColor(NSColor(hex: "#D9C7A2").withAlphaComponent(0.8).cgColor)
      c.fill(CGRect(origin: .zero,size: size))
      var transparent = art; transparent.backgroundOpacity = 0
      if prepared {
        let renderer = try ArtworkRenderer.Prepared(transparent,assets: assets)
        renderer.draw(width: size.width,height: size.height)
      } else {
        ArtworkRenderer.draw(transparent,width: size.width,height: size.height,assets: assets,production: false)
      }
    }
    let expected = try bitmap(size: size) { c in
      c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(origin: .zero,size: size))
      try! contents(c,prepared: false)
    }
    let cache = CanvasOverviewRasterCache(), id = UUID()
    let image = try XCTUnwrap(cache.image(frameID: id,source: art,assets: assets,excluding: [],
      presentation: presentation,zoom: 0.2,pixelsPerMM: 1) { try! contents($0,prepared: true) })
    XCTAssertEqual(try bytes(image),try bytes(expected))
    let displayed = try bitmap(size: size) { CanvasOverviewRasterCache.draw(image,size: size,context: $0) }
    XCTAssertEqual(try bytes(displayed),try bytes(expected), "Cached artwork must retain its top/bottom orientation and composited backdrop.")
    _ = cache.image(frameID: id,source: art,assets: assets,excluding: [],presentation: presentation,
      zoom: 0.2,pixelsPerMM: 1) { _ in XCTFail("Warm display should not rerender text or mask coverage.") }
    XCTAssertEqual(cache.builds,1); XCTAssertEqual(cache.hits,1)
  }
  func testHundredsOfSmallFramesStayWarmWithoutEvictingTheirVectorSnapshots() throws {
    let cache = CanvasOverviewRasterCache(), ids = (0..<240).map { _ in UUID() }
    let art = Artwork(elements: [.init(kind: "rectangle",x: 2,y: 2,width: 20,height: 18)])
    let presentation = CanvasOverviewRasterCache.Presentation(size: .init(width: 60,height: 50))
    for id in ids {
      XCTAssertNotNil(cache.image(frameID: id,source: art,assets: assets,excluding: [],
        presentation: presentation,zoom: 0.08,pixelsPerMM: 0.5) { c in
        c.setFillColor(NSColor.red.cgColor); c.fill(.init(x: 2,y: 2,width: 20,height: 18))
      })
    }
    for id in ids {
      var moved = art; moved.canvasPosition = .init(900,-500)
      XCTAssertNotNil(cache.image(frameID: id,source: moved,assets: assets,excluding: [],
        presentation: presentation,zoom: 0.08,pixelsPerMM: 0.5) { _ in XCTFail("Panning/frame placement should keep all overview images warm.") })
    }
    XCTAssertEqual(cache.builds,240); XCTAssertEqual(cache.hits,240); XCTAssertEqual(cache.count,240)
    XCTAssertEqual(cache.retainedBytes,240*30*25*4)
    XCTAssertNil(cache.image(frameID: ids[0],source: art,assets: assets,excluding: [],
      presentation: presentation,zoom: 0.31,pixelsPerMM: 2) { _ in XCTFail("Close-up drawing must use the vector renderer.") })
  }
  func testSourcePresentationFontsAssetsAndExclusionsInvalidateButSmallZoomChangesReusePixels() throws {
    let cache = CanvasOverviewRasterCache(), id = UUID()
    var art = Artwork(elements: [.init(kind: "rectangle",x: 2,y: 3,width: 20,height: 18)])
    var presentation = CanvasOverviewRasterCache.Presentation(size: .init(width: 60,height: 50))
    func request(density: Double = 1.05, path: URL? = nil, excluded: Set<UUID> = []) -> CGImage? {
      cache.image(frameID: id,source: art,assets: path ?? assets,excluding: excluded,
        presentation: presentation,zoom: 0.2,pixelsPerMM: density) { _ in }
    }
    let initial = try XCTUnwrap(request())
    XCTAssertTrue(request(density: 1.1) === initial)
    XCTAssertTrue(request(density: 0.5) === initial, "Zooming out can reuse already sufficient resolution.")
    XCTAssertEqual(cache.builds,1)
    XCTAssertNotNil(request(density: 1.5)); XCTAssertEqual(cache.builds,2)
    art.elements[0].rotation = 30
    XCTAssertNotNil(request()); XCTAssertEqual(cache.builds,3)
    presentation.paperColor = "#AA6633"; presentation.paperOpacity = 0.6
    XCTAssertNotNil(request()); XCTAssertEqual(cache.builds,4)
    presentation.size.width = 70
    XCTAssertNotNil(request()); XCTAssertEqual(cache.builds,5)
    XCTAssertNotNil(request(excluded: [art.elements[0].id])); XCTAssertEqual(cache.builds,6)
    XCTAssertNotNil(request(path: assets.appendingPathComponent("different-assets"))); XCTAssertEqual(cache.builds,7)
    TypographyEngine.invalidateFonts()
    XCTAssertNotNil(request(path: assets.appendingPathComponent("different-assets"))); XCTAssertEqual(cache.builds,8)
  }
  func testPixelRetentionIsBoundedAndOversizedFramesFallBackToVectors() throws {
    let cache = CanvasOverviewRasterCache(byteLimit: 22_000,entryLimit: 2)
    let art = Artwork(), presentation = CanvasOverviewRasterCache.Presentation(size: .init(width: 50,height: 50))
    let ids = (0..<8).map { _ in UUID() }
    for id in ids {
      XCTAssertNotNil(cache.image(frameID: id,source: art,assets: assets,excluding: [],
        presentation: presentation,zoom: 0.2,pixelsPerMM: 1) { _ in })
      XCTAssertLessThanOrEqual(cache.retainedBytes,22_000); XCTAssertLessThanOrEqual(cache.count,2)
    }
    let oversized = CanvasOverviewRasterCache.Presentation(size: .init(width: 10_000,height: 500))
    XCTAssertNil(cache.image(frameID: UUID(),source: art,assets: assets,excluding: [],
      presentation: oversized,zoom: 0.2,pixelsPerMM: 1) { _ in XCTFail("Oversized frames must avoid allocating overview pixels.") })
    cache.retain([ids.last!]); XCTAssertEqual(cache.count,1)
    cache.clear(); XCTAssertEqual(cache.count,0); XCTAssertEqual(cache.retainedBytes,0)
  }
}
