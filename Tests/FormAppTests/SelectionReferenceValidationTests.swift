import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class SelectionReferenceValidationTests: XCTestCase {
  private struct Fixture {
    let store: StudioStore
    let board: ProductObject
    let alternate: ProductObject
    let first: ProductObject
    let second: ProductObject
  }
  private func fixture() throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reference-validation-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var project = Project(name: "Reference lifecycle")
    var board = try project.makeObject(recipeID: "artboard", name: "Original sheet")
    var path = ArtworkElement(kind: "path", x: 0, y: 0, width: 30, height: 20)
    path.path = .init(width: 30, height: 20, contours: [.init([
      .init(.init(0, 0)), .init(.init(30, 0)), .init(.init(30, 20))], closed: true)])
    board.artwork = .init(elements: [path, .init(kind: "rectangle", x: 40, y: 0, width: 20, height: 20)])
    var alternate = try project.makeObject(recipeID: "artboard", name: "Alternate sheet")
    alternate.artwork = .init()
    let first = try project.makeObject(recipeID: "box", name: "First object")
    let second = try project.makeObject(recipeID: "box", name: "Second object")
    project.objects = [board, alternate, first, second]
    store.engine.project = project; store.showingHome = false; store.mode = .artwork
    store.artworkSession.activate(board.id)
    addTeardownBlock { @MainActor in
      store.bridge.stop(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return Fixture(store: store, board: board, alternate: alternate, first: first, second: second)
  }
  private func board() -> NSPasteboard {
    let board = NSPasteboard.withUniqueName()
    board.setString("Keep existing clipboard", forType: .string)
    addTeardownBlock { board.releaseGlobally() }
    return board
  }

  func testCanvasCopyRejectsPartialLayerDeletionAndDeletedFrameInSameProject() throws {
    let f = try fixture(), store = f.store, ids = Set(f.board.artwork!.elements.map(\.id))
    let reference = try XCTUnwrap(store.canvasSelectionReference(frameID: f.board.id, elementIDs: ids))
    let frameReference = try XCTUnwrap(store.canvasSelectionReference(frameID: f.board.id, elementIDs: []))
    let pasteboard = board()
    store.engine.project?.objects[0].artwork?.elements.removeLast()
    let before = store.project, generation = store.engine.projectGeneration
    XCTAssertNil(store.resolvedSelectionReference(reference), "A surviving subset must not replace the captured selection.")
    XCTAssertFalse(store.copySelectionReference(reference, pasteboard: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "Keep existing clipboard")
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.projectGeneration, generation)
    store.engine.project?.objects.removeAll { $0.id == f.board.id }
    XCTAssertNil(store.resolvedSelectionReference(frameReference))
    XCTAssertFalse(store.copySelectionReference(frameReference, idsOnly: true, pasteboard: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "Keep existing clipboard")
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testCanvasSourceRebindingDoesNotRetargetAnExistingFrameReference() throws {
    let f = try fixture(), store = f.store
    let index = try XCTUnwrap(store.project?.objects.firstIndex { $0.id == f.first.id })
    store.engine.project?.objects[index].artworkSourceID = f.board.id
    store.artworkSession.activate(f.first.id)
    let reference = try XCTUnwrap(store.canvasSelectionReference(frameID: f.first.id, elementIDs: []))
    XCTAssertEqual(reference.objectID, f.board.id)
    store.engine.project?.objects[index].artworkSourceID = f.alternate.id
    XCTAssertNil(store.resolvedSelectionReference(reference))
    XCTAssertEqual(store.artworkSession.activeFrameID, f.first.id)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testCapturedPathNodesRemainExactWhenCurrentSelectionChangesAndRejectDeletedNodes() throws {
    let f = try fixture(), store = f.store, session = store.artworkSession
    let path = f.board.artwork!.elements[0], other = f.board.artwork!.elements[1]
    let nodes = try XCTUnwrap(path.path?.contours.first?.nodes)
    session.choose([path.id]); session.nodes = [nodes[0].id, nodes[1].id]
    let reference = try XCTUnwrap(store.canvasSelectionReference())
    session.choose([other.id])
    let before = store.project, selection = session.selection
    let resolved = try XCTUnwrap(store.resolvedSelectionReference(reference))
    XCTAssertEqual(resolved.elementIDs, [path.id]); XCTAssertEqual(Set(resolved.nodeIDs), [nodes[0].id, nodes[1].id])
    XCTAssertEqual(session.selection, selection); XCTAssertTrue(session.nodes.isEmpty)
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.engine.project?.objects[0].artwork?.elements[0].path?.contours[0].nodes.removeFirst()
    XCTAssertNil(store.resolvedSelectionReference(reference))
  }

  func testTableCopyRefreshesNamesButRejectsPartialObjectDeletion() throws {
    let f = try fixture(), store = f.store
    let reference = try XCTUnwrap(store.objectSelectionReference([f.first.id, f.second.id]))
    let single = try XCTUnwrap(store.objectSelectionReference([f.first.id]))
    let index = try XCTUnwrap(store.project?.objects.firstIndex { $0.id == f.first.id })
    store.engine.project?.objects[index].name = "Renamed object"
    XCTAssertEqual(store.resolvedSelectionReference(single)?.label, "Renamed object")
    store.engine.selection = [f.second.id]
    store.engine.project?.objects.removeAll { $0.id == f.second.id }
    let pasteboard = board()
    XCTAssertNil(store.resolvedSelectionReference(reference))
    XCTAssertFalse(store.copySelectionReference(reference, pasteboard: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "Keep existing clipboard")
    XCTAssertEqual(store.engine.selection, [f.second.id]); XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testSavedSceneInstanceAndShotReferencesResolveTheirOwnIDsAndRejectDeletion() throws {
    let f = try fixture(), store = f.store
    var scene = StudioComposition(name: "Saved composition", camera: store.project!.camera)
    let instance = StudioInstance(name: "First instance", sourceObjectID: f.first.id)
    scene.instances = [instance]
    let shot = StudioShot(name: "Saved shot", camera: store.project!.camera, referenceAspect: 1)
    var presentation = StudioPresentation(shots: [shot]); presentation.scenes = [scene]
    store.engine.project?.studioPresentation = presentation
    let sceneReference = try XCTUnwrap(store.studioSelectionReference(sceneID: scene.id))
    let instanceReference = try XCTUnwrap(store.studioSelectionReference(sceneID: scene.id, instanceID: instance.id))
    store.studioShots.editingID = shot.id
    let shotReference = try XCTUnwrap(store.shotSelectionReference())
    store.studioShots.editingID = nil
    store.engine.project?.studioPresentation?.scenes?[0].name = "Updated composition"
    store.engine.project?.studioPresentation?.shots[0].name = "Updated shot"
    let before = store.project, generation = store.engine.projectGeneration
    XCTAssertEqual(store.resolvedSelectionReference(sceneReference)?.label, "Updated composition")
    XCTAssertEqual(store.resolvedSelectionReference(instanceReference)?.saved, true)
    XCTAssertEqual(store.resolvedSelectionReference(shotReference)?.label, "Updated shot")
    XCTAssertNil(store.studioShots.editingID)
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.projectGeneration, generation)
    store.engine.project?.studioPresentation?.scenes?[0].instances[0].sourceObjectID = f.second.id
    XCTAssertNil(store.resolvedSelectionReference(instanceReference), "The same instance ID must not silently address a replacement source.")
    store.engine.project?.studioPresentation?.scenes?[0].instances.removeAll()
    XCTAssertNil(store.resolvedSelectionReference(instanceReference))
    store.engine.project?.studioPresentation?.scenes = []
    store.engine.project?.studioPresentation?.shots = []
    let pasteboard = board()
    for reference in [sceneReference, instanceReference, shotReference] {
      XCTAssertNil(store.resolvedSelectionReference(reference))
      XCTAssertFalse(store.copySelectionReference(reference, pasteboard: pasteboard))
    }
    XCTAssertEqual(pasteboard.string(forType: .string), "Keep existing clipboard")
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}
