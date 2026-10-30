import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class IndependentSurfaceSelectionTests: XCTestCase {
  private func fixture() throws -> (StudioStore, UUID, UUID, UUID) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("independent-surfaces-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    var project = try PaperSamples.sunStudies()
    let paper = try XCTUnwrap(project.objects.first { PaperConstruction.isPaper($0) })
    let net = try PaperConstruction.definition(for: paper).net(), sourceID = project.artworkOwner(paper).id
    let panels = Array(net.panels.filter { $0.polygon.count >= 3 }.prefix(2))
    XCTAssertEqual(panels.count, 2)
    project.objects[project.objects.firstIndex { $0.id == sourceID }!].artwork = Artwork(elements: panels.map {
      .init(kind: "rectangle", x: $0.bounds.x + 2, y: $0.bounds.y + 2,
        width: max(1, min(8, $0.bounds.width - 4)), height: max(1, min(8, $0.bounds.height - 4)), color: "#2855AA")
    })
    let first = try project.makeObject(recipeID: "box", position: .init(900, 0, 400))
    let second = try project.makeObject(recipeID: "box", position: .init(-700, 0, 350))
    project.objects += [first, second]; project.schemaVersion = project.minimumSchemaVersion
    store.engine.project = project; store.showingHome = false; store.environment = .form; store.mode = .artwork
    store.select(first.id); store.activatePaperArtwork(paper); store.tableInspectorVisible = false
    var camera = project.camera; camera.target = .init(8, 2, 4); camera.distance = 19; camera.azimuth = 1.2
    let scene = TableSceneController(store: store); scene.camera = camera; store.scene = scene
    addTeardownBlock { @MainActor in store.engine.project = nil; try? FileManager.default.removeItem(at: directory) }
    return (store, paper.id, first.id, second.id)
  }

  private func makeCanvas(_ store: StudioStore) -> (NSWindow, VectorCanvasView) {
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = ArtworkScrollView(frame: .init(x: 0, y: 0, width: 900, height: 650)), canvas = VectorCanvasView()
    scroll.allowsMagnification = true; scroll.minMagnification = 0.08; scroll.maxMagnification = 24
    scroll.documentView = canvas; window.contentView = scroll
    canvas.session = store.artworkSession; store.artworkSession.canvas = canvas
    canvas.synchronize(); scroll.tile(); canvas.fit(all: true)
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    return (window, canvas)
  }

  private func event(_ type: NSEvent.EventType, canvas: VectorCanvasView, point: CGPoint) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.documentPoint(point), to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
      context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
  }

  func testNativeCanvasFrameClicksKeepUnrelatedTableSelectionCameraAndPanelContext() throws {
    let (store, paperID, tableID, _) = try fixture(), (_, canvas) = makeCanvas(store), session = store.artworkSession
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.constructionID == paperID && $0.projection?.panelID != nil })
    let before = try XCTUnwrap(store.project), camera = try XCTUnwrap(store.scene).camera
    store.paperSelectedPanelID = "Table-only panel"
    let point = CGPoint(x: frame.rect.midX, y: frame.rect.midY)
    canvas.mouseDown(with: try event(.leftMouseDown, canvas: canvas, point: point))
    canvas.mouseUp(with: try event(.leftMouseUp, canvas: canvas, point: point))
    XCTAssertEqual(session.activeFrameID, frame.id); XCTAssertEqual(session.paperContext?.id, paperID)
    XCTAssertEqual(store.engine.selection, [tableID]); XCTAssertEqual(store.scene?.camera, camera)
    XCTAssertEqual(store.paperSelectedPanelID, "Table-only panel"); XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertEqual(store.project?.objects, before.objects); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testTablePicksAndReconcileKeepCanvasSourceFrameElementsAndViewport() throws {
    let (store, paperID, _, nextTableID) = try fixture(), (_, canvas) = makeCanvas(store), session = store.artworkSession
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.constructionID == paperID && $0.projection?.panelID != nil })
    session.activate(frame.id); session.choose([try XCTUnwrap(session.art.elements.first).id]); canvas.synchronize(); canvas.setZoom(1.25)
    let source = session.objectID, chosen = session.selection, visible = canvas.visibleCanvasRect, zoom = canvas.zoom
    store.select(nextTableID); session.reconcile(); canvas.synchronize()
    XCTAssertEqual(store.primary?.id, nextTableID)
    XCTAssertEqual(session.objectID, source); XCTAssertEqual(session.activeFrameID, frame.id); XCTAssertEqual(session.selection, chosen)
    XCTAssertEqual(session.paperContext?.id, paperID); XCTAssertEqual(canvas.zoom, zoom)
    XCTAssertEqual(canvas.visibleCanvasRect.midX, visible.midX, accuracy: 0.000001)
    XCTAssertEqual(canvas.visibleCanvasRect.midY, visible.midY, accuracy: 0.000001)
  }

  func testTablePanelPickingDoesNotNavigateOrRefitCanvas() throws {
    let (store, paperID, _, _) = try fixture(), (_, canvas) = makeCanvas(store), session = store.artworkSession
    let frames = session.frames.filter { $0.projection?.constructionID == paperID && $0.projection?.panelID != nil }
    let selected = try XCTUnwrap(frames.first), other = try XCTUnwrap(frames.dropFirst().first?.projection?.panelID)
    session.activate(selected.id); session.choose([try XCTUnwrap(session.art.elements.first).id]); canvas.synchronize(); canvas.setZoom(0.7)
    let source = session.objectID, chosen = session.selection, visible = canvas.visibleCanvasRect, zoom = canvas.zoom
    store.selectPaperPanel(objectID: paperID, panelID: other); session.reconcile()
    XCTAssertEqual(store.paperSelectedPanelID, other); XCTAssertEqual(store.primary?.id, paperID)
    XCTAssertEqual(session.objectID, source); XCTAssertEqual(session.activeFrameID, selected.id); XCTAssertEqual(session.selection, chosen)
    XCTAssertEqual(canvas.zoom, zoom); XCTAssertEqual(canvas.visibleCanvasRect, visible)
  }

  func testContextMenuFindExplicitlySelectsAndCentersTableWithoutChangingCanvasOrOpeningInspector() throws {
    let (store, paperID, tableID, _) = try fixture(), (_, canvas) = makeCanvas(store), session = store.artworkSession
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.constructionID == paperID && $0.projection?.panelID != nil })
    session.activate(frame.id); canvas.synchronize()
    let source = session.objectID, chosen = session.selection, visible = canvas.visibleCanvasRect, zoom = canvas.zoom
    let before = try XCTUnwrap(store.project), camera = try XCTUnwrap(store.scene).camera
    XCTAssertEqual(store.engine.selection, [tableID]); store.isolated = [tableID]
    let menu = try XCTUnwrap(canvas.menu(for: try event(.rightMouseDown, canvas: canvas, point: .init(x: frame.rect.midX, y: frame.rect.midY))))
    XCTAssertEqual(menu.items.first?.title, "Find on Table")
    menu.performActionForItem(at: 0)
    XCTAssertEqual(store.engine.selection, [paperID]); XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertTrue(store.isolated.isEmpty)
    XCTAssertNotEqual(store.scene?.camera.target, camera.target)
    let physical = try XCTUnwrap(before.objects.first { $0.id == paperID })
    XCTAssertLessThan(abs(try XCTUnwrap(store.scene?.camera.target.x) - physical.position.x / 100), 5)
    XCTAssertEqual(session.objectID, source); XCTAssertEqual(session.activeFrameID, frame.id); XCTAssertEqual(session.selection, chosen)
    XCTAssertEqual(canvas.zoom, zoom); XCTAssertEqual(canvas.visibleCanvasRect, visible)
    XCTAssertEqual(store.project?.objects, before.objects); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testCanvasSourceEditsAndSVGImportKeepTableSelectionCameraAndOneUndo() throws {
    let (store, paperID, tableID, _) = try fixture(), session = store.artworkSession
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.constructionID == paperID && $0.projection?.panelID != nil })
    session.activate(frame.id); session.choose([try XCTUnwrap(session.art.elements.first).id])
    let before = try XCTUnwrap(store.project), camera = try XCTUnwrap(store.scene).camera
    session.update { $0.color = "#DD4411" }
    XCTAssertEqual(store.engine.selection, [tableID]); XCTAssertEqual(store.scene?.camera, camera)
    XCTAssertFalse(store.tableInspectorVisible); XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project?.objects, before.objects)
    let data = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm"><rect width="10mm" height="10mm"/></svg>"#.utf8)
    let imported = try SVGImporter.read(data, name: "Canvas-only SVG")
    let projection = try XCTUnwrap(frame.projection)
    _ = try store.commitSVG(imported, data: data, name: "Canvas-only SVG", targetID: projection.sourceID, projection: projection)
    XCTAssertEqual(store.engine.selection, [tableID]); XCTAssertEqual(store.scene?.camera, camera)
    XCTAssertEqual(session.objectID, projection.sourceID); XCTAssertEqual(session.activeFrameID, frame.id)
    XCTAssertFalse(store.tableInspectorVisible); XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project?.objects, before.objects)
  }

  func testNewCanvasFrameKeepsTableSelectionCameraAndClosedInspector() throws {
    let (store, _, tableID, _) = try fixture(), camera = try XCTUnwrap(store.scene).camera
    let ids = Set(try XCTUnwrap(store.project).objects.map(\.id))
    store.artworkSession.createFrame(width: 80, height: 60, name: "New independent frame")
    let added = try XCTUnwrap(store.project?.objects.first { !ids.contains($0.id) })
    XCTAssertEqual(store.artworkSession.objectID, added.id)
    XCTAssertEqual(store.engine.selection, [tableID]); XCTAssertEqual(store.scene?.camera, camera)
    XCTAssertFalse(store.tableInspectorVisible)
    XCTAssertNotNil(added.artwork)
  }
}
