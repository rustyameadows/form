import AppKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasConstructionProjectionTests: XCTestCase {
  private func fixture() throws -> (StudioStore, UUID) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-construction-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Shared construction sources")
    let authored = PlanarConstructionDefinition(name: "Agent folded card", parameters: [
      .init("width", 100, 60...160), .init("height", 40, 20...80)
    ], size: .init("width+20", "height*2"), panels: [
      .init(id: "front", name: "Front", polygon: [.init(0, 0), .init("width", 0), .init("width", "height"), .init(0, "height")]),
      .init(id: "back", name: "Back", polygon: [.init(0, "height"), .init("width", "height"), .init("width", "height*2"), .init(0, "height*2")], artworkRotationDegrees: 180),
      .init(id: "side", name: "Side", polygon: [.init("width", 0), .init("width+20", 0), .init("width+20", "height"), .init("width", "height")], artworkRotationDegrees: 90)
    ], hinges: [
      .init(id: "fold.back", parentPanelID: "front", childPanelID: "back", start: .init(0, "height"), end: .init("width", "height"), angleDegrees: 90),
      .init(id: "fold.side", parentPanelID: "front", childPanelID: "side", start: .init("width", 0), end: .init("width", "height"), angleDegrees: -90)
    ], rootPanelID: "front")
    var definition = PaperConstruction(kind: .authored, dimensions: .init(width: 100, height: 80, depth: 1))
    definition.authored = authored
    let parameters = PaperConstructionEngine.parameters(definition).sorted { $0.key < $1.key }.map {
      Parameter($0.key, $0.key, $0.value, $0.key == "width" ? 60...160 : $0.key == "height" ? 20...80 : 0...100)
    }
    let recipe = Recipe("agent-folded-card", "Agent folded card", "square", "Authored test", parameters)
    project.recipes = [recipe]
    var object = try project.makeObject(recipeID: recipe.id)
    object.paperConstruction = definition
    object.artwork = Artwork(background: "#FFFFFF", bleed: 2)
    object.artwork?.elements = [
      .init(kind: "text", x: 10, y: 10, width: 35, height: 10, text: "Original", fontSize: 12),
      .init(kind: "rectangle", x: 5, y: 37, width: 80, height: 6, color: "#245BFF")
    ]
    project.objects = [object]
    store.engine.project = project; store.showingHome = false; store.mode = .artwork
    store.select(object.id); store.activatePaperArtwork(object)
    addTeardownBlock { @MainActor in store.engine.project = nil; try? FileManager.default.removeItem(at: root) }
    return (store, object.id)
  }

  func testOneCanvasContainsProofAndUprightSurfacesWithoutCreatingArtworkCopies() throws {
    let (store, id) = try fixture(), before = store.project!
    let session = store.artworkSession, frames = session.frames
    XCTAssertEqual(frames.filter { $0.projection != nil }.count, 4)
    XCTAssertEqual(Set(frames.map(\.id)).count, frames.count)
    let proof = try XCTUnwrap(frames.first { $0.projection?.isProof == true })
    let back = try XCTUnwrap(frames.first { $0.projection?.panelID == "back" })
    session.activate(back.id)
    XCTAssertEqual(session.objectID, id)
    XCTAssertEqual(session.activeFrameID, back.id)
    XCTAssertEqual(store.project, before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertEqual(Set(back.artwork.elements.map(\.id)), Set(proof.artwork.elements.map(\.id)))
    XCTAssertEqual(back.rect.width, 100, accuracy: 1e-8)
    XCTAssertEqual(back.rect.height, 40, accuracy: 1e-8)
    XCTAssertEqual(store.engine.selection, [id])
  }

  func testUprightTextEditMapsToOneSourceAndUndoReopenRetainOrientation() throws {
    let (store, id) = try fixture(), session = store.artworkSession
    let panel = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "back" })
    session.activate(panel.id)
    let before = store.project!, new = ArtworkElement(kind: "text", x: 12, y: 8, width: 40, height: 12, text: "Upright back", fontSize: 13)
    session.add([new])
    XCTAssertNil(store.error)
    let source = try XCTUnwrap(store.project?.objects.first { $0.id == id }?.artwork)
    XCTAssertEqual(source.elements.count, 3)
    let visible = try XCTUnwrap(session.art.elements.first { $0.id == new.id })
    let local = session.art.worldTransform(visible)
    XCTAssertEqual(local.a, 1, accuracy: 1e-8); XCTAssertEqual(local.b, 0, accuracy: 1e-8)
    XCTAssertEqual(session.art.bounds(of: visible).x, 12, accuracy: 1e-8)
    XCTAssertEqual(session.art.bounds(of: visible).y, 8, accuracy: 1e-8)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    let proof = try XCTUnwrap(session.frames.first { $0.projection?.isProof == true })
    XCTAssertTrue(proof.artwork.elements.contains { $0.id == new.id && $0.text == "Upright back" })
    XCTAssertEqual(store.project?.objects.count, before.objects.count)
    store.engine.undo(); XCTAssertEqual(store.project, before)
    store.engine.redo(); try store.engine.flush()
    let reopened = try store.repository.load(before.id)
    XCTAssertEqual(reopened.objects.first { $0.id == id }?.artwork, source)
  }

  func testDielineArtworkEditsKeepDerivedGeometryAndMovingProjectionHasIndependentSavedUndo() throws {
    let (store, id) = try fixture(), session = store.artworkSession
    let proof = try XCTUnwrap(session.frames.first { $0.projection?.isProof == true })
    session.activate(proof.id)
    let before = store.project!
    let definition = try PaperConstruction.definition(for: before.objects[0]).net()
    let newText = ArtworkElement(kind: "text", x: 0, y: 0, text: "Shared flat artwork")
    session.add([newText])
    XCTAssertTrue(session.art.elements.contains { $0.id == newText.id })
    XCTAssertEqual(store.project!.objects[0].paperConstruction, before.objects[0].paperConstruction)
    XCTAssertEqual(try PaperConstruction.definition(for: store.project!.objects[0]).net(), definition)
    XCTAssertEqual(session.art.elements.count, before.objects[0].artwork!.elements.count+1,
      "Derived cuts and folds must never become editable artwork layers.")
    store.engine.undo(); XCTAssertEqual(store.project, before)
    session.moveCanvasFrame(to: .init(-200, 400))
    XCTAssertEqual(session.frames.first { $0.id == proof.id }?.rect.origin, CGPoint(x: -200, y: 400))
    XCTAssertEqual(store.project?.objects.first { $0.id == id }?.artwork, before.objects.first?.artwork)
    try store.engine.flush()
    XCTAssertEqual(try store.repository.load(before.id).objects.first?.canvasProjectionPositions?[proof.projection!.key], Point2(-200, 400))
    store.engine.undo(); XCTAssertEqual(store.project, before)
  }

  func testMovingProjectionReusesActualPhysicalGeometryAndTextures() throws {
    let (store, _) = try fixture(), session = store.artworkSession
    var project = Project(name: "View placement keeps physical buffers")
    var object = try project.makeObject(recipeID: "paperEnvelope")
    object.artwork = Artwork(background: "#FFFFFF", elements: [
      .init(kind: "text", x: 12, y: 20, width: 35, height: 10, text: "Physical source")
    ])
    project.objects = [object]; store.engine.project = project
    store.select(object.id); store.activatePaperArtwork(object)
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "front" })
    session.activate(frame.id)
    let first = GeometryFactory.object(object, project: project, assets: session.assets, textureLimit: 128)
    let geometry = try XCTUnwrap(first.childNode(withName: PaperGeometry.panelPrefix+"front", recursively: true)?.geometry)
    let textures = PaperGeometry.textureBuilds, meshes = PaperGeometry.physicalMeshBuilds
    session.moveCanvasFrame(to: .init(320, -250))
    let moved = try XCTUnwrap(store.project), changed = try XCTUnwrap(moved.objects.first)
    let next = GeometryFactory.object(changed, project: moved, assets: session.assets, textureLimit: 128)
    XCTAssertTrue(next.childNode(withName: PaperGeometry.panelPrefix+"front", recursively: true)?.geometry === geometry,
      "A Canvas arrangement edit must reuse the actual cached physical geometry handle.")
    XCTAssertEqual(PaperGeometry.textureBuilds, textures)
    XCTAssertEqual(PaperGeometry.physicalMeshBuilds, meshes)
    XCTAssertEqual(changed.paperConstruction, object.paperConstruction)
    XCTAssertEqual(changed.artwork, object.artwork)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project, project)
  }

  func testProjectionHitTestingUsesPolygonAndSourceRoundTripPreservesUnchangedLayers() throws {
    let (store, id) = try fixture(), object = store.project!.objects[0]
    let panel = PaperPanel(id: "triangle", name: "Triangle", role: .body,
      polygon: [.init(10, 20), .init(60, 20), .init(10, 70)], artworkRotationDegrees: 90)
    let net = PaperNet(size: .init(100, 100), panels: [panel], folds: [], joins: [], cutEdges: [], rootPanelID: panel.id)
    let projection = CanvasSourceProjection.views(of: object, sourceID: id, inside: false, net: net)[1]
    let frame = CanvasFrame(object: object, surfaceObject: object, rect: .init(x: 200, y: 100, width: 50, height: 50), artwork: projection.display(object.artwork!), projection: projection)
    XCTAssertTrue(frame.contains(.init(x: 240, y: 110)))
    XCTAssertFalse(frame.contains(.init(x: 201, y: 149)))
    XCTAssertTrue(projection.intersects(.init(35, 5, 10, 10)))
    XCTAssertFalse(projection.intersects(.init(0, 40, 5, 5)))
    XCTAssertEqual(projection.source(from: projection.display(object.artwork!), original: object.artwork!), object.artwork!)
  }

  func testUprightSelectAllAndNativeMarqueeOnlySelectArtworkIntersectingThatSurface() throws {
    let (store, _) = try fixture(), session = store.artworkSession
    let front = ArtworkElement(kind: "rectangle", x: 10, y: 20, width: 20, height: 10)
    let back = ArtworkElement(kind: "rectangle", x: 10, y: 55, width: 20, height: 10)
    let crossing = ArtworkElement(kind: "rectangle", x: 10, y: 35, width: 20, height: 15)
    var project = store.project!; project.objects[0].artwork!.elements = [front, back, crossing]
    store.engine.project = project
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "front" })
    session.activate(frame.id)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = VectorCanvasView(frame: window.contentView!.bounds)
    window.contentView = canvas; canvas.session = session; session.canvas = canvas
    canvas.synchronize(); window.makeFirstResponder(canvas)
    defer { canvas.finishText(); window.close() }
    canvas.selectAll(nil)
    XCTAssertEqual(session.selection, [front.id, crossing.id])
    session.choose([])
    func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
      let point = CGPoint(x: frame.rect.minX+x, y: frame.rect.minY+y)
      return NSEvent.mouseEvent(with: type, location: canvas.convert(canvas.documentPoint(point), to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    canvas.mouseDown(with: event(.leftMouseDown, 2, 2))
    canvas.mouseDragged(with: event(.leftMouseDragged, 45, 75))
    canvas.mouseUp(with: event(.leftMouseUp, 45, 75))
    XCTAssertEqual(session.selection, [front.id, crossing.id])
    XCTAssertEqual(store.project, project)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertEqual(ArtworkLayers(session: session).rows.map(\.element.id).sorted { $0.uuidString < $1.uuidString },
      [front.id, crossing.id].sorted { $0.uuidString < $1.uuidString })
  }

  func testClipboardAcrossRotatedSurfacesKeepsUprightArtworkAndOneUndo() async throws {
    let (store, id) = try fixture(), session = store.artworkSession
    let board = NSPasteboard.withUniqueName(); session.transferPasteboard = board
    defer { session.cancelArtworkTransfer(); board.releaseGlobally() }
    let back = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "back" })
    let side = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "side" })
    session.activate(back.id)
    let text = ArtworkElement(kind: "text", x: 4, y: 2, width: 15, height: 8, text: "Upright copy")
    session.add([text]); session.choose([text.id])
    let before = store.project!, undo = store.engine.undoStack.count
    XCTAssertTrue(session.copyArtwork(), session.lastTransferError ?? "Copy failed")
    let wire = try XCTUnwrap(board.data(forType: ArtworkTransferPasteboard.type))
    let bundle = try ArtworkTransferBundle.decode(wire)
    XCTAssertEqual(bundle.metadata.sourceSchema, 55)
    let local = try XCTUnwrap(bundle.metadata.artwork.elements.first { $0.id == text.id })
    let copiedOrigin = bundle.metadata.artwork.worldTransform(local).apply(.init())
    XCTAssertEqual(copiedOrigin.x, 4, accuracy: 1e-8); XCTAssertEqual(copiedOrigin.y, 2, accuracy: 1e-8)
    var future = bundle; future.metadata.sourceSchema = Project.maximumSchemaVersion+1
    XCTAssertThrowsError(try future.encoded(), "Unknown future source schemas remain rejected.")
    XCTAssertEqual(store.project, before)
    session.activate(side.id); session.pasteArtwork()
    for _ in 0..<250 { if !session.transferInFlight { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(session.transferInFlight); XCTAssertNil(session.lastTransferError)
    XCTAssertEqual(store.engine.undoStack.count, undo+1)
    XCTAssertEqual(session.objectID, id)
    let pasted = try XCTUnwrap(session.primary)
    XCTAssertNotEqual(pasted.id, text.id)
    let transform = session.art.worldTransform(pasted), origin = transform.apply(.init()), unit = transform.apply(.init(1, 0))
    XCTAssertEqual(origin.x, 14, accuracy: 1e-8); XCTAssertEqual(origin.y, 12, accuracy: 1e-8)
    XCTAssertEqual(unit.x-origin.x, 1, accuracy: 1e-8); XCTAssertEqual(unit.y-origin.y, 0, accuracy: 1e-8)
    XCTAssertEqual(store.project!.objects[0].artwork!.elements.first { $0.id == text.id },
      before.objects[0].artwork!.elements.first { $0.id == text.id })
    XCTAssertEqual(store.project!.objects[0].artwork!.elements.count, before.objects[0].artwork!.elements.count+1)
    let pastedProject = store.project!
    store.engine.undo(); XCTAssertEqual(store.project, before)
    store.engine.redo(); XCTAssertEqual(store.project, pastedProject)
  }

  func testSVGImportCentersUprightOnRotatedSurfaceInOneUndoAndRetainsOriginalSource() throws {
    let (store, id) = try fixture(), session = store.artworkSession
    let back = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "back" })
    session.activate(back.id)
    let data = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="20mm" height="10mm" viewBox="0 0 20 10"><rect width="20" height="10" fill="#2468aa"/><text x="1" y="6" font-size="4">Upright</text></svg>"##.utf8)
    let imported = try SVGImporter.read(data, name: "Rotated surface source")
    let before = store.project!, count = store.engine.undoStack.count
    let report = try store.commitSVG(imported, data: data, name: "Rotated surface source", targetID: id, projection: back.projection)
    XCTAssertEqual(session.activeFrameID, back.id)
    XCTAssertEqual(store.engine.undoStack.count, count+1)
    let root = try XCTUnwrap(imported.artwork.elements.first { $0.parentID == nil })
    let placed = try XCTUnwrap(session.art.elements.first { $0.id == root.id })
    let original = imported.artwork.worldTransform(root), actual = session.art.worldTransform(placed)
    XCTAssertEqual(actual.a, original.a, accuracy: 1e-8); XCTAssertEqual(actual.b, original.b, accuracy: 1e-8)
    XCTAssertEqual(actual.c, original.c, accuracy: 1e-8); XCTAssertEqual(actual.d, original.d, accuracy: 1e-8)
    XCTAssertEqual(actual.tx-original.tx, 40, accuracy: 1e-8); XCTAssertEqual(actual.ty-original.ty, 15, accuracy: 1e-8)
    XCTAssertEqual(store.project!.objects[0].paperConstruction, before.objects[0].paperConstruction)
    for layer in before.objects[0].artwork!.elements {
      XCTAssertEqual(store.project!.objects[0].artwork!.elements.first { $0.id == layer.id }, layer)
    }
    let asset = try XCTUnwrap(report["original_asset"] as? String)
    XCTAssertEqual(try Data(contentsOf: session.assets.appendingPathComponent(asset)), data)
    let saved = store.project!
    store.engine.undo(); XCTAssertEqual(store.project, before)
    store.engine.redo(); XCTAssertEqual(store.project, saved)
  }

  func testSVGImportRetainsInsideSourceAndConstructionSelectionAfterReconcile() throws {
    let (store, id) = try fixture(), session = store.artworkSession
    store.createPaperInside(store.project!.objects[0]); XCTAssertNil(store.error)
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.inside == true && $0.projection?.panelID == "back" })
    let projection = try XCTUnwrap(frame.projection)
    session.activate(frame.id)
    let before = store.project!, undo = store.engine.undoStack.count
    let data = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm"><rect width="10mm" height="10mm"/></svg>"#.utf8)
    let imported = try SVGImporter.read(data, name: "Inside source")
    _ = try store.commitSVG(imported, data: data, name: "Inside source", targetID: projection.sourceID, projection: projection)
    session.reconcile()
    XCTAssertEqual(store.primary?.id, id)
    XCTAssertEqual(session.objectID, projection.sourceID)
    XCTAssertEqual(session.activeFrameID, frame.id)
    XCTAssertTrue(store.paperInside)
    XCTAssertEqual(store.project!.objects[0].artwork, before.objects[0].artwork)
    XCTAssertEqual(store.engine.undoStack.count, undo+1)
    store.engine.undo(); XCTAssertEqual(store.project, before)
  }

  func testInsideProjectionUsesIndependentSharedSourceAndPreservesOutsideArtwork() throws {
    let (store, id) = try fixture(), outside = store.project!.objects[0].artwork
    store.createPaperInside(store.project!.objects[0])
    let object = try XCTUnwrap(store.project?.objects.first { $0.id == id })
    let insideID = try XCTUnwrap(object.paperConstruction?.insideArtworkSourceID)
    let session = store.artworkSession
    let back = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "back" && $0.projection?.inside == true })
    session.activate(back.id)
    let undo = store.engine.undoStack.count
    session.add([.init(kind: "text", x: 7, y: 6, text: "Inside only")])
    XCTAssertEqual(session.objectID, insideID)
    XCTAssertEqual(store.project?.objects.first { $0.id == id }?.artwork, outside)
    XCTAssertEqual(store.project?.objects.first { $0.id == insideID }?.artwork?.elements.last?.text, "Inside only")
    XCTAssertEqual(store.engine.undoStack.count, undo + 1)
    session.reconcile()
    XCTAssertEqual(session.activeFrameID, back.id)
    store.engine.undo()
    XCTAssertFalse(store.project?.objects.first { $0.id == insideID }?.artwork?.elements.contains { $0.text == "Inside only" } == true)
  }

  func testImagePlacementIntoRotatedSurfaceIsUprightAndOneUndo() throws {
    let (store, _) = try fixture(), session = store.artworkSession
    let back = try XCTUnwrap(session.frames.first { $0.projection?.panelID == "back" })
    session.activate(back.id)
    let imageURL = store.repository.root.appendingPathComponent("asymmetric.png")
    let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: imageURL)
    let before = store.project!
    XCTAssertTrue(session.placeImages([imageURL], point: .init(50, 20)))
    let element = try XCTUnwrap(session.primary)
    XCTAssertEqual(element.kind, "image")
    let transform = session.art.worldTransform(element)
    XCTAssertEqual(transform.a, 1, accuracy: 1e-8); XCTAssertEqual(transform.b, 0, accuracy: 1e-8)
    XCTAssertEqual(session.selectionBounds?.center.x ?? 0, 50, accuracy: 1e-8)
    XCTAssertEqual(session.selectionBounds?.center.y ?? 0, 20, accuracy: 1e-8)
    XCTAssertEqual(store.engine.undoStack.count, 1)
    store.engine.undo(); XCTAssertEqual(store.project, before)
  }

  func testSewingArtworkUsesTheSameOrdinarySourceSessionWithoutPaperProjection() throws {
    let (store, _) = try fixture()
    var project = store.project!, frame = try project.makeObject(recipeID: "artboard", name: "Sewing source", parameters: ["width": 200, "depth": 240])
    var piece = ArtworkElement(kind: "rectangle", x: 20, y: 30, width: 80, height: 120)
    piece.sewingPiece = SewingPatternPiece(name: "Front sewing piece")
    frame.artwork = Artwork(background: "#FFFFFF", elements: [piece], bleed: 0)
    project.objects.append(frame); store.engine.project = project
    let session = store.artworkSession
    session.activate(try XCTUnwrap(session.frames.first { $0.projection?.panelID == "back" }).id)
    session.activate(frame.id); session.choose([piece.id])
    XCTAssertNil(session.activeProjection)
    XCTAssertEqual(session.art, frame.artwork)
    session.update { $0.sewingPiece?.seamAllowance = 14 }
    XCTAssertEqual(store.project?.objects.first { $0.id == frame.id }?.artwork?.elements[0].sewingPiece?.seamAllowance, 14)
    store.engine.undo()
    XCTAssertEqual(store.project?.objects.first { $0.id == frame.id }?.artwork, frame.artwork)
  }

  func testCADNamedSurfaceUsesTheSameCanvasFrameAndOriginalArtboardSource() throws {
    let (store, _) = try fixture()
    var project = store.project!, source = try project.makeObject(recipeID: "artboard", name: "Top graphic", parameters: ["width": 100, "depth": 40])
    let text = ArtworkElement(kind: "text", x: 8, y: 6, text: "Shared top")
    source.artwork = Artwork(background: "#FFFFFF", elements: [text])
    let box = CADFeatureNode(name: "Body", operation: .init(.box, values: ["width": 100, "height": 30, "depth": 40]))
    let surface = CADPlanarSurface(id: "top", name: "Top", outputFeatureID: box.id,
      selection: .faceAtMaximum(axis: "y"), origin: .init(0, 30, 40),
      uAxis: .xAxis, vAxis: .init(0, 0, -1), width: 100, height: 40)
    let definition = CADModelDefinition(name: "Mapped model", features: [box], outputs: [box.id], surfaces: [surface])
    let fingerprint = String(repeating: "a", count: 64)
    var component = CADComponentRepresentation(id: box.id, name: "Body", brepAsset: "body.brep", brepSHA256: fingerprint,
      meshAsset: "body.mesh", meshSHA256: fingerprint, minimum: .init(), maximum: .init(100, 30, 40), volumeMM3: 120000,
      valid: true, closed: true, solidCount: 1, faceCount: 6, edgeCount: 12, vertexCount: 8, triangleCount: 12)
    component.featureFingerprint = fingerprint
    var resolved = try surface.resolved(using: [:]); resolved.faceIndex = 1; resolved.fingerprint = fingerprint
    var representation = CADRepresentation(modelID: definition.id, definitionSHA256: try CADRepresentation.definitionHash(definition),
      kernelVersion: "test", components: [component])
    representation.resolvedSurfaces = [resolved]
    var model = ProductObject(name: "Mapped model", recipeID: "cadModel", parameters: [:])
    model.cadModel = definition; model.cadRepresentation = representation
    model.surfaceArtworkBindings = [.init(surfaceID: "top", sourceObjectID: source.id, widthMM: 100, heightMM: 40)]
    project.objects += [source, model]; store.engine.project = project
    let session = store.artworkSession
    let frame = try XCTUnwrap(session.frames.first { $0.projection?.constructionID == model.id })
    let tableSelection = store.engine.selection
    session.activate(frame.id); session.reconcile()
    XCTAssertEqual(session.objectID, source.id)
    XCTAssertEqual(session.activeFrameID, frame.id)
    XCTAssertEqual(store.engine.selection, tableSelection)
    XCTAssertEqual(session.physicalObject?.id, model.id)
    XCTAssertEqual(session.art, source.artwork)
    session.choose([text.id]); session.update { $0.text = "Edited from surface" }
    XCTAssertEqual(store.project?.objects.first { $0.id == source.id }?.artwork?.elements.first?.text, "Edited from surface")
    XCTAssertNil(store.project?.objects.first { $0.id == model.id }?.artwork)
    store.engine.undo()
    XCTAssertEqual(store.project?.objects.first { $0.id == source.id }?.artwork, source.artwork)
  }
}
