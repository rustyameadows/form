import AppKit
import XCTest

@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class SewingCurvedEditingTests: XCTestCase {
  private func fixture() throws -> (StudioStore, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var p = Project(name: "Curve pattern32 native")
    var existing = try p.makeObject(
      recipeID: "artboard", name: "Retain existing drawing",
      parameters: ["width": 400, "depth": 300])
    existing.artwork = Artwork(elements: [
      ArtworkElement(kind: "text", x: 10, y: 10, width: 80, height: 20, text: "Keep my source")
    ])
    p.objects = [existing]
    store.engine.project = p
    store.showingHome = false
    return (store, root)
  }
  private func saved(_ store: StudioStore) async throws {
    let end = Date().addingTimeInterval(6)
    while store.saving && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(store.saving)
  }
  func testNativeMeasuredCreationAppendsEditableSourceAutosavesAndUsesOneUndo() async throws {
    let (store, root) = try fixture()
    defer {
      store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    let original = store.project!
    let retained = original.objects[0]
    let id = try store.createRoundedPouchPattern(parameters: [
      "width": 310, "height": 220, "corner_radius": 45, "seam_allowance": 12, "facing_height": 50,
    ])
    XCTAssertTrue(store.saving)
    let frame = store.project!.objects.first { $0.id == id }!
    let art = frame.artwork!
    XCTAssertEqual(store.project!.objects[0], retained)
    XCTAssertEqual(art.elements[0].width, 310)
    XCTAssertEqual(art.elements[0].sewingPiece!.seamAllowance, 12)
    XCTAssertEqual(art.elements[1].height, 50)
    XCTAssertTrue(art.elements[0].path!.contours[0].nodes.contains { $0.outgoing != nil })
    XCTAssertEqual(store.artworkSession.objectID, id)
    XCTAssertTrue(try SewingPatterns.diagnostics(art).allSatisfy { $0.matches && $0.isConclusive })
    try await saved(store)
    let disk = try store.repository.load(original.id)
    XCTAssertEqual(disk.objects, store.project!.objects)
    XCTAssertEqual(disk.schemaVersion, 32)
    store.undo()
    XCTAssertEqual(store.project!.objects, original.objects)
    store.redo()
    XCTAssertEqual(store.project!.objects.first { $0.id == id }?.artwork, art)
    let before = store.project!
    XCTAssertThrowsError(
      try store.createRoundedPouchPattern(parameters: ["width": 100, "corner_radius": 100]))
    XCTAssertEqual(store.project, before)
  }
  func testPhysicalCurvedTemplateSVGAndPDFPreserveBezierSourceAndExposeMeasurementBounds() throws {
    let template = try SewingPatternTemplates.roundedPouch()
    let before = template.artwork
    let output = try SewingPatternOutput(source: before)
    let assets = FileManager.default.temporaryDirectory
    let metadata = output.metadata
    let pieces = try XCTUnwrap(metadata["pieces"] as? [[String: Any]])
    let body = pieces[0]
    XCTAssertEqual(body["contour_tolerance_mm"] as? Double, 0.02)
    XCTAssertEqual((body["source_edges"] as? [[String: Any]])?.count, 6)
    let pdf = try output.pdf(assets: assets, dpi: 72)
    let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
    let page = try XCTUnwrap(doc.page(at: 1))
    XCTAssertEqual(
      page.getBoxRect(.mediaBox).width, output.plan.frameSize.x * 72 / 25.4, accuracy: 0.01)
    XCTAssertEqual(
      page.getBoxRect(.mediaBox).height, output.plan.frameSize.y * 72 / 25.4, accuracy: 0.01)
    let svg = try output.svg(assets: assets)
    XCTAssertTrue(svg.contains("form-sewing-pattern"))
    XCTAssertTrue(svg.contains("source_edges"))
    XCTAssertTrue(svg.contains("measurement_error_mm"))
    XCTAssertTrue(svg.contains("50 mm calibration square"))
    XCTAssertEqual(template.artwork, before)
    if let directory = ProcessInfo.processInfo.environment["FORM_PATTERN32_PROOF_DIR"] {
      let folder = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try pdf.write(to: folder.appendingPathComponent("rounded-pouch-pattern.pdf"))
      try Data(svg.utf8).write(to: folder.appendingPathComponent("rounded-pouch-pattern.svg"))
      let image = try output.image(assets: assets, dpi: 72)
      let rep = image.representations[0] as! NSBitmapImageRep
      try rep.representation(using: .png, properties: [:])!.write(
        to: folder.appendingPathComponent("rounded-pouch-pattern.png"))
      try JSONEncoder.form.encode(before).write(
        to: folder.appendingPathComponent("rounded-pouch-editable-source.json"))
    }
  }
  func testHoledLayoutFabricPreviewClipsTheActualHoleAndExportsSeparateCutPaths() throws {
    let outer = VectorContour([
      .init(.init(0, 0)), .init(.init(100, 0)), .init(.init(100, 100)), .init(.init(0, 100)),
    ])
    let hole = VectorContour([
      .init(.init(30, 30)), .init(.init(30, 70)), .init(.init(70, 70)), .init(.init(70, 30)),
    ])
    var e = ArtworkElement(kind: "path", x: 0, y: 0, width: 100, height: 100)
    e.path = .init(width: 100, height: 100, contours: [outer, hole], evenOdd: true)
    e.sewingPiece = .init(name: "Holed panel")
    e.sewingPiece!.seamAllowance = 5
    let art = Artwork(elements: [e])
    var layout = SewingCutLayout(materialID: "flight-nylon", stockWidth: 200)
    layout.margin = 0
    layout.spacing = 5
    layout.grain = .unrestricted
    layout.placements = [.init(elementID: e.id, copies: [1], x: 10, y: 10)]
    let output = try SewingLayoutOutput(
      layout: layout, source: art, fabricColor: "#E00000", includeFabricPreview: true)
    XCTAssertEqual(output.artwork.elements.filter { $0.productionRole == "cut" }.count, 2)
    let image = try output.image(assets: FileManager.default.temporaryDirectory, dpi: 72)
    let rep = image.representations[0] as! NSBitmapImageRep
    func color(_ mm: Point2) -> NSColor {
      rep.colorAt(
        x: Int(mm.x / 200 * Double(rep.pixelsWide)),
        y: Int(mm.y / output.height * Double(rep.pixelsHigh)))!.usingColorSpace(.sRGB)!
    }
    let empty = color(.init(65, 65))
    let filled = color(.init(22, 80))
    XCTAssertGreaterThan(empty.greenComponent, 0.95)
    XCTAssertLessThan(filled.greenComponent, 0.2)
    let svg = try output.svg(assets: FileManager.default.temporaryDirectory)
    XCTAssertTrue(svg.contains("clip-rule=\"evenodd\""))
    XCTAssertTrue(svg.contains("Cut hole 1"))
  }
}
