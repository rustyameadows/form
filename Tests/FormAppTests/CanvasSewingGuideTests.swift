import AppKit
import CryptoKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasSewingGuideTests: XCTestCase {
  private func encoded(_ artwork: Artwork) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(artwork)
  }
  private func fixedTote() throws -> Artwork {
    var source = try SewingPatternTemplates.tote().artwork
    let body = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    source.elements[0].id = body
    source.elements[1].id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    for i in source.sewingSeams!.indices {
      source.sewingSeams![i].id = UUID(uuidString: String(format: "33333333-3333-4333-8333-%012d", i + 1))!
      source.sewingSeams![i].first.elementID = body; source.sewingSeams![i].second.elementID = body
    }
    return source
  }
  func testSourceCoordinatesPreserveOriginalGeometryAndExactDefaultSheetBytes() throws {
    let source = try fixedTote(), original = try encoded(source)
    let sheet = try SewingPatternDrawing.plan(source)
    // Captured from the original compiled plan before adding the Canvas option.
    XCTAssertEqual(SHA256.hash(data: try encoded(sheet.artwork)).map { String(format: "%02x", $0) }.joined(),
      "dd1947c0caae76d6f813fc4ba42eabcadc2620ea7de8ba486a7ce38ce810df05")
    XCTAssertEqual(sheet.frameSize, .init(585, 826))
    let canvas = try SewingPatternDrawing.plan(source, coordinates: .source)
    let stitch = try XCTUnwrap(canvas.artwork.elements.first { $0.name == "Stitch outline" })
    XCTAssertEqual(canvas.artwork.bounds(of: stitch), .init(45, 90, 340, 380))
    XCTAssertEqual(canvas.pieces.map(\.elementID), source.elements.map(\.id))
    XCTAssertTrue(Set(canvas.artwork.elements.map(\.id)).isDisjoint(with: source.elements.map(\.id)))
    XCTAssertFalse(canvas.artwork.elements.contains { $0.name?.contains("calibration") == true || $0.name == "Seam schedule" })
    XCTAssertEqual(canvas.artwork.backgroundOpacity, 0)
    XCTAssertEqual(try encoded(SewingPatternDrawing.plan(source, coordinates: .sheet).artwork), try encoded(sheet.artwork))
    XCTAssertEqual(try encoded(source), original)
  }
  private func curvedSource() -> Artwork {
    let k = 0.5522847498307936 * 50
    let contour = VectorContour([
      .init(.init(100, 50), incoming: .init(100, 50-k), outgoing: .init(100, 50+k)),
      .init(.init(50, 100), incoming: .init(50+k, 100), outgoing: .init(50-k, 100)),
      .init(.init(0, 50), incoming: .init(0, 50+k), outgoing: .init(0, 50-k)),
      .init(.init(50, 0), incoming: .init(50-k, 0), outgoing: .init(50+k, 0)),
    ])
    var element = ArtworkElement(kind: "path", x: 40, y: 45, width: 100, height: 100)
    element.path = .init(width: 100, height: 100, contours: [contour])
    element.sewingPiece = .init(name: "Curved original"); element.sewingPiece!.seamAllowance = 6
    element.fillEnabled = false; element.productionRole = "stitch"
    element.stroke = .init(color: "#43718A", width: 0.3)
    return .init(elements: [element], bleed: 0)
  }
  func testCurvedGuideCacheReusesUnchangedSourceAndClearsInvalidResults() throws {
    let cache = CanvasSewingGuideCache(), id = UUID(), source = curvedSource()
    let original = try encoded(source), first = try XCTUnwrap(cache.overlay(frameID: id, source: source))
    XCTAssertEqual(first.sourceStrokeIDs, [source.elements[0].id]); XCTAssertEqual(cache.builds, 1)
    for _ in 0..<10 { XCTAssertEqual(cache.overlay(frameID: id, source: source)?.artwork, first.artwork) }
    XCTAssertEqual(cache.builds, 1); XCTAssertEqual(try encoded(source), original)
    let legible = first.interfaceArtwork(scale: 0.3)
    XCTAssertTrue(legible.elements.compactMap(\.stroke).allSatisfy { $0.width >= 1/0.3 })
    XCTAssertEqual(cache.overlay(frameID: id, source: source)?.artwork, first.artwork)
    var filled = source; filled.elements[0].fillEnabled = true
    XCTAssertTrue(try XCTUnwrap(cache.overlay(frameID: id, source: filled)).sourceStrokeIDs.isEmpty)
    var invalid = source; invalid.elements[0].sewingPiece!.seamAllowance = -1
    XCTAssertNil(cache.overlay(frameID: id, source: invalid))
    let attempts = cache.builds
    XCTAssertNil(cache.overlay(frameID: id, source: invalid)); XCTAssertEqual(cache.builds, attempts)
    var changed = source; changed.elements[0].sewingPiece!.seamAllowance = 9
    XCTAssertNotEqual(try XCTUnwrap(cache.overlay(frameID: id, source: changed)).artwork, first.artwork)
    changed.showGuides = false
    XCTAssertNil(cache.overlay(frameID: id, source: changed)); XCTAssertEqual(cache.count, 0)
    cache.retain([]); XCTAssertEqual(cache.count, 0)
  }
  private func capture(_ canvas: VectorCanvasView, frame: CanvasFrame) throws -> NSBitmapImageRep {
    let a = canvas.documentPoint(frame.rect.origin), b = canvas.documentPoint(.init(x: frame.rect.maxX, y: frame.rect.maxY))
    let rect = CGRect(x: a.x, y: a.y, width: b.x-a.x, height: b.y-a.y)
    let image = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: rect))
    canvas.cacheDisplay(in: rect, to: image)
    return image
  }
  private func count(_ bitmap: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> Int {
    var result = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
      autoreleasepool {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
          if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) { result += 1 }
        }
      }
    }
    return result
  }
  func testOrdinaryCanvasDrawsReadOnlySewingGuidesWithSharedSourceAndCache() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-sewing-guides-" + UUID().uuidString)
    let repository = try ProjectRepository(root: root), project = Project(name: "Real tote Canvas")
    try repository.save(project)
    let store = StudioStore(repository: repository, seedLibrary: false); try store.engine.open(project.id)
    defer { store.cloth.clear(); store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    store.createTotePattern()
    let session = store.artworkSession, id = try XCTUnwrap(session.objectID)
    let index = try XCTUnwrap(store.engine.project!.objects.firstIndex { $0.id == id })
    store.engine.project!.objects[index].artwork!.elements.append(.init(kind: "rectangle", x: 100, y: 150,
      width: 30, height: 20, color: "#D34523"))
    let before = store.project!, history = store.engine.undoStack
    let original = try XCTUnwrap(before.objects[index].artwork)
    let sheet = try encoded(SewingPatternDrawing.plan(original).artwork)
    let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 700, height: 600)), canvas = VectorCanvasView()
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    scroll.documentView = canvas; canvas.session = session; session.canvas = canvas
    canvas.synchronize()
    let frame = try XCTUnwrap(session.frames.first { $0.id == id })
    XCTAssertNil(frame.projection)
    let technical = try capture(canvas, frame: frame), builds = canvas.diagnostics["sewing_guide_builds"] as? Int
    XCTAssertEqual(builds, 1)
    let dark: (NSColor) -> Bool = {
      let r = $0.redComponent, g = $0.greenComponent, b = $0.blueComponent
      return max(r, max(g, b)) < 0.7 && max(r, max(g, b)) - min(r, min(g, b)) < 0.1
    }
    let gold: (NSColor) -> Bool = {
      let r = $0.redComponent, g = $0.greenComponent, b = $0.blueComponent
      return r > g + 0.04 && g > b + 0.07 && g-b > (r-g)*0.8 && b < 0.85
    }
    let red: (NSColor) -> Bool = { $0.redComponent > 0.6 && $0.greenComponent < 0.4 && $0.blueComponent < 0.3 }
    XCTAssertGreaterThan(count(technical, matching: dark), 100); XCTAssertGreaterThan(count(technical, matching: gold), 20)
    XCTAssertGreaterThan(count(technical, matching: red), 200, "Derived guides must not cover printed artwork.")
    scroll.contentView.scroll(to: .init(x: 20, y: 20)); scroll.magnification = 1.2
    _ = try capture(canvas, frame: frame)
    XCTAssertEqual(canvas.diagnostics["sewing_guide_builds"] as? Int, builds)
    session.hiddenProductionRoles = [.cut, .guide]
    let filtered = try capture(canvas, frame: frame)
    XCTAssertLessThan(count(filtered, matching: dark), 10); XCTAssertLessThan(count(filtered, matching: gold), 10)
    XCTAssertGreaterThan(count(filtered, matching: red), 200)
    XCTAssertEqual(canvas.diagnostics["sewing_guide_builds"] as? Int, builds)
    session.hiddenProductionRoles = []
    store.engine.project!.objects[index].artwork!.showGuides = false; canvas.synchronize()
    let hidden = try capture(canvas, frame: try XCTUnwrap(session.frames.first { $0.id == id }))
    XCTAssertLessThan(count(hidden, matching: dark), 10); XCTAssertLessThan(count(hidden, matching: gold), 10)
    store.engine.project!.objects[index].artwork!.showGuides = nil; canvas.synchronize()
    _ = try capture(canvas, frame: frame)
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.undoStack, history)
    XCTAssertEqual(Set(session.art.elements.map(\.id)), Set(original.elements.map(\.id)))
    session.choose([original.elements[0].id]); session.update { $0.sewingPiece!.seamAllowance += 1 }
    canvas.synchronize(); _ = try capture(canvas, frame: try XCTUnwrap(session.frames.first { $0.id == id }))
    XCTAssertEqual(store.engine.undoStack.count, history.count + 1)
    XCTAssertEqual(store.project!.objects[index].artwork!.sewingSeams, original.sewingSeams)
    store.undo()
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(try encoded(SewingPatternDrawing.plan(store.project!.objects[index].artwork!).artwork), sheet)
    if let path = ProcessInfo.processInfo.environment["FORM_SEWING_CANVAS_PROOF_DIR"] {
      let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, bitmap) in [("technical", technical), ("roles-hidden", filtered), ("guides-hidden", hidden)] {
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
      }
    }
  }
}
