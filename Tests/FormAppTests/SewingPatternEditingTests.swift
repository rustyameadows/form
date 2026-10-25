import AppKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class SewingPatternEditingTests: XCTestCase {
  private func store() throws -> StudioStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Sewing pattern regression"); _ = try project.ensureCanvasWorkspace()
    store.engine.project = project; store.showingHome = false; store.mode = .artwork
    store.artworkSession.objectID = project.canvasWorkspace!.id
    return store
  }
  private func cleanup(_ store: StudioStore) { try? FileManager.default.removeItem(at: store.repository.root) }
  private func frame(_ store: StudioStore) throws -> ProductObject { try XCTUnwrap(store.project?.objects.first { $0.artwork?.elements.contains { $0.sewingPiece != nil } == true }) }
  func testNativeToteCreationIsOneUndoAndKeepsEditableSourceAndCopySeams() throws {
    let store = try store(); defer { cleanup(store) }
    let before = store.project!
    store.createTotePattern(); let frame = try frame(store)
    XCTAssertNil(store.error); XCTAssertEqual(store.mode, .artwork)
    XCTAssertEqual(store.artworkSession.objectID, frame.id)
    XCTAssertEqual(frame.artwork?.elements.count, 2); XCTAssertEqual(frame.artwork?.sewingSeams?.count, 3)
    XCTAssertEqual(store.project!.minimumSchemaVersion, 24)
    XCTAssertTrue(try SewingPatterns.diagnostics(frame.artwork!).allSatisfy(\.matches))
    store.engine.undo(); XCTAssertEqual(store.project, before)
    store.engine.redo(); XCTAssertNotNil(try self.frame(store).artwork?.elements.first?.sewingPiece)
  }
  func testNativeMouseMovePreservesPhysicalAllowancesAndPairingWithUndo() throws {
    let store = try store(); defer { cleanup(store) }; store.createTotePattern()
    let session = store.artworkSession, frame = try frame(store)
    var art = frame.artwork!; art.snapEnabled = false
    try store.engine.edit("Disable snapping", source: "Test") { try $0.setArtwork(art, for: frame.id) }
    let baseline = store.project!, body = art.elements[0], geometry = try SewingPatterns.geometry(body, in: art)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    let canvas = VectorCanvasView(frame: .init(x: 0, y: 0, width: 900, height: 650))
    canvas.session = session; session.canvas = canvas; scroll.documentView = canvas; window.contentView = scroll
    window.makeFirstResponder(canvas); canvas.synchronize(); canvas.fit(all: false); session.selection = []
    let canvasFrame = try XCTUnwrap(session.frames.first { $0.id == frame.id })
    let start = CGPoint(x: canvasFrame.rect.minX + body.x + body.width / 2, y: canvasFrame.rect.minY + body.y)
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.documentPoint(point), to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    let end = CGPoint(x: start.x + 50, y: start.y + 30)
    canvas.mouseDown(with: event(.leftMouseDown, start)); canvas.mouseDragged(with: event(.leftMouseDragged, end)); canvas.mouseUp(with: event(.leftMouseUp, end))
    let moved = try XCTUnwrap(session.art.elements.first { $0.id == body.id }), after = try SewingPatterns.geometry(moved, in: session.art)
    XCTAssertEqual(after.stitch[0].x, geometry.stitch[0].x + 50, accuracy: 0.001)
    XCTAssertEqual(after.stitch[0].y, geometry.stitch[0].y + 30, accuracy: 0.001)
    XCTAssertEqual(after.piece, geometry.piece); XCTAssertEqual(after.edgeLengths, geometry.edgeLengths)
    XCTAssertEqual(session.art.sewingSeams, art.sewingSeams)
    store.engine.undo(); XCTAssertEqual(store.project, baseline)
  }
  func testMCPPatternTemplateAndMetadataHaveAtomicUndoAndSchemaRoundTrip() throws {
    let store = try store(); defer { cleanup(store) }
    let id = store.project!.canvasWorkspace!.id, before = store.project!
    _ = try store.engine.call("form_edit_artwork", arguments: ["object_id": id.uuidString, "command": "pattern_template", "template": "tote", "pattern_parameters": ["width": 420, "height": 450]])
    let updated = store.project!, art = store.project!.canvasWorkspace!.artwork!, body = art.elements[0]
    XCTAssertEqual(body.width, 420); XCTAssertEqual(body.height, 450)
    XCTAssertEqual(updated.minimumSchemaVersion, 24)
    store.engine.undo(); XCTAssertEqual(store.project, before); store.engine.redo()
    var bad = body.sewingPiece!; bad.notches[0].depth = 50
    XCTAssertThrowsError(try store.engine.call("form_edit_artwork", arguments: ["object_id": id.uuidString, "command": "pattern_piece", "element_ids": [body.id.uuidString], "piece": try jsonObject(bad)]))
    XCTAssertEqual(store.project, updated)
    try store.repository.save(updated); let loaded = try store.repository.load(updated.id)
    XCTAssertEqual(loaded.canvasWorkspace?.artwork, art); XCTAssertEqual(loaded.minimumSchemaVersion, 24)
  }
  func testDerivedCutGeometryIncludesNotchesFoldOmissionAndNoPersistedCopies() throws {
    let template = try SewingPatternTemplates.tote(), original = template.artwork
    let first = try SewingPatternDrawing.plan(original), again = try SewingPatternDrawing.plan(original)
    XCTAssertEqual(first.artwork, again.artwork)
    XCTAssertEqual(first.artwork.elements.filter { $0.name == "Seam schedule" }.count, original.sewingSeams!.count)
    XCTAssertTrue(first.artwork.elements.filter { $0.name == "Seam schedule" }.allSatisfy { $0.text.contains("copy 1") && $0.text.contains("copy 2") })
    let cut = try XCTUnwrap(first.artwork.elements.first { $0.name == "Cut contour" })
    XCTAssertEqual(cut.path?.contours.first?.nodes.count, 10, "Four corners plus the two three-point V notches.")
    XCTAssertTrue(first.artwork.elements.allSatisfy { $0.sewingPiece == nil })
    XCTAssertNil(first.artwork.sewingSeams); XCTAssertEqual(template.artwork, original)
    var folded = original; folded.elements[0].sewingPiece!.notches = []; folded.elements[0].sewingPiece!.onFoldEdge = 0
    folded.sewingSeams = nil
    let plan = try SewingPatternDrawing.plan(folded, selection: [folded.elements[0].id])
    let edges = plan.artwork.elements.filter { $0.productionRole == "cut" }
    XCTAssertEqual(edges.count, 3); XCTAssertTrue(edges.allSatisfy { $0.path?.contours.first?.closed == false })
    XCTAssertTrue(plan.artwork.elements.contains { $0.name == "Place on fold" })
  }
  func testRealMCPExportHasActualSizeLayeredSVGCombinedPDFAndCalibratedPixels() throws {
    let store = try store(); defer { cleanup(store) }; store.createTotePattern()
    let object = try frame(store), original = store.project!, output = try SewingPatternOutput(source: object.artwork!)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(output.metadata))
    let folder = store.repository.root.appendingPathComponent("Proof"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for format in ["svg", "pdf", "png"] {
      let path = folder.appendingPathComponent("tote." + format)
      let result = try store.graphicsCall("form_export_artwork", ["object_id": object.id.uuidString, "pattern_pieces": true,
        "format": format, "path": path.path, "dpi": 72]) as! [String: Any]
      XCTAssertEqual(result["width_mm"] as? Double, output.plan.frameSize.x); XCTAssertEqual(result["height_mm"] as? Double, output.plan.frameSize.y)
      XCTAssertEqual(result["calibration_square_mm"] as? Int, 50)
      let data = try Data(contentsOf: path)
      if format == "svg" {
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("form-sewing-pattern")); XCTAssertTrue(xml.contains("form-role-cut")); XCTAssertTrue(xml.contains("form-role-stitch")); XCTAssertTrue(xml.contains("form-role-guide"))
        XCTAssertTrue(XMLParser(data: data).parse())
      }
      if format == "pdf" {
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!)), page = try XCTUnwrap(doc.page(at: 1))
        XCTAssertEqual(doc.numberOfPages, 1)
        XCTAssertEqual(page.getBoxRect(.mediaBox).width / TypographyEngine.pointsPerMM, output.plan.frameSize.x, accuracy: 0.001)
        XCTAssertEqual(page.getBoxRect(.mediaBox).height / TypographyEngine.pointsPerMM, output.plan.frameSize.y, accuracy: 0.001)
      }
      if format == "png" {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, Int((output.plan.frameSize.x * 72 / 25.4).rounded()))
        XCTAssertEqual(bitmap.pixelsHigh, Int((output.plan.frameSize.y * 72 / 25.4).rounded()))
      }
      if let directory = ProcessInfo.processInfo.environment["FORM_SEWING_PROOF_DIR"] {
        let folder = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("everyday-tote." + format), options: .atomic)
      }
    }
    XCTAssertEqual(store.project, original)
    XCTAssertThrowsError(try store.exportSewingPattern(object: object, arguments: ["format": "svg", "roles": ["cut"]]))
    XCTAssertThrowsError(try store.exportSewingPattern(object: object, arguments: ["format": "png", "dpi": true]))
  }
}
