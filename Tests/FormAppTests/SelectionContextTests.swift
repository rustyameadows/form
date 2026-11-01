import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class SelectionContextTests: XCTestCase {
  private func fixture() throws -> (StudioStore, ProductObject, ProductObject) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-context-" + UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    var p = Project(name: "Selection study")
    var frame = try p.makeObject(recipeID: "artboard", name: "Editorial sheet")
    var group = ArtworkElement(kind: "group", x: 0, y: 0, width: 80, height: 30)
    var title = ArtworkElement(kind: "text", x: 4, y: 5, text: "A lighter palette")
    title.parentID = group.id
    group.color = "#223344"
    frame.artwork = .init(elements: [group, title])
    let object = try p.makeObject(recipeID: "box", name: "Physical carton")
    p.objects = [frame, object]
    store.engine.project = p; store.showingHome = false; store.mode = .artwork
    store.artworkSession.activate(frame.id)
    addTeardownBlock { @MainActor in
      store.bridge.stop(); store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    return (store, frame, object)
  }
  private func context(_ store: StudioStore) throws -> [String: Any] {
    try XCTUnwrap(store.engine.call("form_get_context") as? [String: Any])
  }
  private func target(_ context: [String: Any]) throws -> [String: Any] {
    try XCTUnwrap(context["active_target"] as? [String: Any])
  }

  func testCanvasArtboardAndGroupSelectionUseSourceIDsAndDoNotMutateDocument() throws {
    let (store, frame, object) = try fixture(), s = store.artworkSession
    store.engine.selection = [object.id]
    let before = store.project, generation = store.engine.projectGeneration
    var value = try context(store)
    XCTAssertEqual(try target(value)["kind"] as? String, "artboard")
    XCTAssertEqual(try target(value)["object_id"] as? String, frame.id.uuidString)
    let group = frame.artwork!.elements[0], title = frame.artwork!.elements[1]
    s.scopeID = group.id; s.choose([title.id])
    value = try context(store)
    XCTAssertEqual(try target(value)["element_ids"] as? [String], [title.id.uuidString])
    XCTAssertEqual((value["canvas"] as? [String: Any])?["group_scope_id"] as? String, group.id.uuidString)
    XCTAssertEqual((value["table"] as? [String: Any])?["selected_object_ids"] as? [String], [object.id.uuidString])
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.projectGeneration, generation)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    let status = try XCTUnwrap(store.engine.call("form_status") as? [String: Any])
    XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(status["context"] as? [String: Any])), NSDictionary(dictionary: value))
  }

  func testSplitSurfaceUsesLastFocusedPaneAndDoesNotSelectHiddenCanvasInstead() throws {
    let (store, frame, object) = try fixture()
    store.surfaceLayout = .split; store.engine.selection = [object.id]
    store.activateDesignSurface(.table)
    XCTAssertEqual(try target(context(store))["object_id"] as? String, object.id.uuidString)
    store.activateDesignSurface(.artwork)
    XCTAssertEqual(try target(context(store))["object_id"] as? String, frame.id.uuidString)
    store.activateDesignSurface(.table); store.engine.selection = []
    XCTAssertTrue(try context(store)["active_target"] is NSNull)
    XCTAssertEqual(store.artworkSession.objectID, frame.id)
  }

  func testMissingSelectionAndHomeNeverSilentlyFallBackToAnotherTarget() throws {
    let (store, frame, object) = try fixture(), s = store.artworkSession
    s.choose([UUID()])
    XCTAssertTrue(try context(store)["active_target"] is NSNull)
    XCTAssertNil(store.canvasSelectionReference(frameID: UUID(), elementIDs: []))
    s.choose([]); store.engine.project?.objects.removeAll { $0.id == frame.id }
    XCTAssertTrue(try context(store)["active_target"] is NSNull)
    store.mode = .table; store.engine.selection = [object.id, UUID()]
    XCTAssertEqual(try target(context(store))["object_ids"] as? [String], [object.id.uuidString])
    store.showingHome = true
    let home = try context(store)
    XCTAssertTrue(home["active_target"] is NSNull); XCTAssertTrue(home["canvas"] is NSNull)
    XCTAssertEqual(home["focused_surface"] as? String, "home")
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testExplicitCopyPreservesSelectionAndProducesRoundTrippableIDs() throws {
    let (store, frame, object) = try fixture()
    store.engine.selection = [object.id]
    let title = frame.artwork!.elements[1]
    let before = store.project, selected = store.artworkSession.selection
    let ref = try XCTUnwrap(store.canvasSelectionReference(frameID: frame.id, elementIDs: [title.id]))
    let board = NSPasteboard(name: .init("selection-reference-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    XCTAssertTrue(store.copySelectionReference(ref, pasteboard: board))
    let string = try XCTUnwrap(board.string(forType: .string))
    let json = String(string.dropFirst("LAB selection reference\n".count))
    let decoded = try JSONDecoder().decode(LABSelectionReference.self, from: Data(json.utf8))
    XCTAssertEqual(decoded, ref); XCTAssertEqual(decoded.objectID, frame.id)
    XCTAssertTrue(store.copySelectionReference(ref, idsOnly: true, pasteboard: board))
    XCTAssertEqual(board.string(forType: .string), title.id.uuidString)
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.artworkSession.selection, selected)
    XCTAssertEqual(store.engine.selection, [object.id]); XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.engine.project = Project(name: "Other project")
    XCTAssertFalse(store.copySelectionReference(ref, pasteboard: board))
  }

  func testInsidePhysicalFaceReportsCanonicalAndViewArgumentsSeparately() throws {
    let (store, _, _) = try fixture()
    var p = try PaperSamples.sunStudies()
    let physical = try XCTUnwrap(p.objects.first { PaperConstruction.isPaper($0) })
    var inside = try p.makeObject(recipeID: "artboard", name: "Inside source")
    inside.artwork = .init(elements: [.init(kind: "rectangle", x: 1, y: 1, width: 5, height: 5)])
    inside.canvasSourceOnly = true
    var definition = try PaperConstruction.definition(for: physical)
    definition.insideArtworkSourceID = inside.id
    p.objects[p.objects.firstIndex { $0.id == physical.id }!].paperConstruction = definition
    p.objects.append(inside); store.engine.project = p
    let s = store.artworkSession
    let frame = try XCTUnwrap(s.frames.first { $0.projection?.constructionID == physical.id && $0.projection?.inside == true && $0.projection?.panelID != nil })
    s.activate(frame.id)
    let value = try context(store), ref = try target(value), canvas = try XCTUnwrap(value["canvas"] as? [String: Any])
    XCTAssertEqual(ref["object_id"] as? String, inside.id.uuidString)
    XCTAssertEqual(ref["physical_object_id"] as? String, physical.id.uuidString)
    XCTAssertEqual(ref["side"] as? String, "inside")
    XCTAssertEqual(store.canvasSelectionReference()?.copiedIDs, inside.id.uuidString)
    let raw = try XCTUnwrap(canvas["canonical_artwork_query"] as? [String: Any])
    let view = try XCTUnwrap(canvas["view_artwork_query"] as? [String: Any])
    XCTAssertEqual(raw["object_id"] as? String, inside.id.uuidString)
    XCTAssertEqual(view["object_id"] as? String, physical.id.uuidString)
    XCTAssertNoThrow(try store.engine.call("form_get_artwork", arguments: view))
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testStudioContextDistinguishesSceneInstanceSourceAndUnsavedDraft() throws {
    let (store, _, object) = try fixture()
    var scene = StudioComposition(name: "Product hero", camera: store.project!.camera)
    let copy = StudioInstance(name: "Carton in hero", sourceObjectID: object.id)
    scene.instances = [copy]
    var presentation = store.project!.studioPresentation ?? .init()
    presentation.scenes = [scene]; store.engine.project?.studioPresentation = presentation
    store.mode = .studio; store.environment = .studio
    store.studioComposition.requestScene(scene.id); store.studioComposition.selectInstance(copy.id)
    let before = store.project
    var value = try context(store), ref = try target(value)
    XCTAssertEqual(ref["kind"] as? String, "studio_instance")
    XCTAssertEqual(ref["scene_id"] as? String, scene.id.uuidString)
    XCTAssertEqual(ref["instance_id"] as? String, copy.id.uuidString)
    XCTAssertEqual(ref["source_object_id"] as? String, object.id.uuidString)
    XCTAssertNil(ref["object_id"], "An instance must not masquerade as its source")
    XCTAssertNil(store.studioSelectionReference(sceneID: scene.id)?.instanceID)
    store.studioComposition.change { $0.name = "Unsaved title" }
    value = try context(store)
    XCTAssertEqual((value["studio"] as? [String: Any])?["has_unsaved_changes"] as? Bool, true)
    XCTAssertEqual((value["studio"] as? [String: Any])?["scene_name"] as? String, "Unsaved title")
    XCTAssertEqual(store.studioSelectionReference()?.hasUnsavedChanges, true)
    let unsaved = StudioInstance(name: "Draft-only copy", sourceObjectID: object.id)
    store.studioComposition.change { $0.instances.append(unsaved) }
    store.studioComposition.selectInstance(unsaved.id)
    let unsavedRef = try XCTUnwrap(store.studioSelectionReference(sceneID: scene.id, instanceID: unsaved.id))
    XCTAssertEqual(unsavedRef.sceneSaved, true); XCTAssertEqual(unsavedRef.instanceSaved, false)
    XCTAssertEqual(unsavedRef.saved, false); XCTAssertEqual(unsavedRef.hasUnsavedChanges, true)
    XCTAssertEqual(store.project, before); XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.engine.project = Project(name: "Replacement")
    XCTAssertTrue(try context(store)["active_target"] is NSNull)
    XCTAssertTrue(try context(store)["studio"] is NSNull)
  }

  func testStudioSubviewNeverTargetsAHiddenComposition() throws {
    let (store, _, object) = try fixture()
    var scene = StudioComposition(name: "Retained scene", camera: store.project!.camera)
    let instance = StudioInstance(name: "Scene copy", sourceObjectID: object.id)
    scene.instances = [instance]
    let shot = StudioShot(name: "Saved view", camera: store.project!.camera, referenceAspect: 1.5)
    var presentation = StudioPresentation(shots: [shot]); presentation.scenes = [scene]
    store.engine.project?.studioPresentation = presentation
    store.mode = .studio; store.environment = .studio
    store.studioComposition.requestScene(scene.id); store.studioComposition.selectInstance(instance.id)
    let before = store.project, draft = store.studioComposition.draft
    store.studioShowingImages = true
    var value = try context(store)
    XCTAssertEqual(value["studio_subview"] as? String, "images")
    XCTAssertTrue(value["active_target"] is NSNull)
    XCTAssertEqual((value["studio"] as? [String: Any])?["active"] as? Bool, false)
    store.studioShowingImages = false; store.studioShowingShots = true
    store.engine.selection = [object.id]
    value = try context(store)
    XCTAssertEqual(try target(value)["object_id"] as? String, object.id.uuidString)
    XCTAssertEqual((value["table"] as? [String: Any])?["active"] as? Bool, true)
    XCTAssertEqual((value["studio"] as? [String: Any])?["active"] as? Bool, false)
    store.engine.selection = []; store.studioShots.editingID = shot.id
    value = try context(store)
    XCTAssertEqual(try target(value)["shot_id"] as? String, shot.id.uuidString)
    XCTAssertEqual(try target(value)["kind"] as? String, "studio_shot")
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.studioComposition.draft, draft)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testExternalSceneChangeIsReportedBeforeNativeReconciliation() throws {
    let (store, _, object) = try fixture()
    var scene = StudioComposition(name: "Saved scene", camera: store.project!.camera)
    let instance = StudioInstance(name: "Saved copy", sourceObjectID: object.id)
    scene.instances = [instance]
    var presentation = StudioPresentation(); presentation.scenes = [scene]
    store.engine.project?.studioPresentation = presentation
    store.mode = .studio; store.environment = .studio
    store.studioComposition.requestScene(scene.id); store.studioComposition.selectInstance(instance.id)
    XCTAssertFalse(store.studioComposition.dirty)
    store.engine.project?.studioPresentation?.scenes?[0].instances = []
    let before = store.project, draft = store.studioComposition.draft
    let value = try context(store), ref = try target(value)
    XCTAssertEqual(ref["scene_saved"] as? Bool, true)
    XCTAssertEqual(ref["instance_saved"] as? Bool, false)
    XCTAssertEqual(ref["saved"] as? Bool, false)
    XCTAssertEqual(ref["has_unsaved_changes"] as? Bool, true)
    XCTAssertEqual((value["studio"] as? [String: Any])?["has_unsaved_changes"] as? Bool, true)
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.studioComposition.draft, draft)
    store.engine.project?.studioPresentation?.scenes = []
    XCTAssertTrue(try context(store)["active_target"] is NSNull)
  }

  func testPaperSelectionIsOwnedByItsPhysicalObject() throws {
    let (store, _, _) = try fixture()
    var p = try PaperSamples.sunStudies()
    let physical = try XCTUnwrap(p.objects.first { PaperConstruction.isPaper($0) })
    let net = try PaperConstruction.definition(for: physical).net()
    var other = physical; other.id = UUID(); other.name = "Other construction"
    p.objects.append(other); store.engine.project = p; store.mode = .table
    store.selectPaperPanel(objectID: physical.id, panelID: net.rootPanelID)
    store.paperSelectedFoldID = net.folds.first?.id
    var table = try XCTUnwrap(context(store)["table"] as? [String: Any])
    XCTAssertEqual(table["paper_object_id"] as? String, physical.id.uuidString)
    XCTAssertEqual(table["selected_panel_id"] as? String, net.rootPanelID)
    store.engine.selection = [other.id]
    let before = store.project
    table = try XCTUnwrap(context(store)["table"] as? [String: Any])
    XCTAssertTrue(table["paper_object_id"] is NSNull)
    XCTAssertTrue(table["selected_panel_id"] is NSNull); XCTAssertTrue(table["selected_fold_id"] is NSNull)
    XCTAssertEqual(store.project, before)
    store.engine.selection = [physical.id]; store.paperSelectedPanelID = "deleted-panel"; store.paperSelectedFoldID = "deleted-fold"
    table = try XCTUnwrap(context(store)["table"] as? [String: Any])
    XCTAssertTrue(table["selected_panel_id"] is NSNull); XCTAssertTrue(table["selected_fold_id"] is NSNull)
    XCTAssertEqual(store.paperSelectedPanelID, "deleted-panel", "Reads must not reconcile UI state")
  }

  func testPrivateBridgeContextReadLeavesNativeTextDraftAndHistoryUntouched() async throws {
    let socket = "/tmp/lab-context-" + UUID().uuidString + ".sock"
    let old = ProcessInfo.processInfo.environment["FORM_SOCKET_PATH"]
    setenv("FORM_SOCKET_PATH", socket, 1)
    let (store, frame, _) = try fixture()
    if let old { setenv("FORM_SOCKET_PATH", old, 1) } else { unsetenv("FORM_SOCKET_PATH") }
    store.startBridge(); XCTAssertTrue(store.bridgeReady)
    let s = store.artworkSession; s.choose([frame.artwork!.elements[1].id]); s.editingText = true
    s.characterRange = NSRange(location: 2, length: 4)
    let before = store.project, generation = store.engine.projectGeneration
    let value = try await Task.detached {
      try LocalBridgeClient.call("form_get_context", arguments: [:], socketPath: socket) as? [String: Any]
    }.value
    XCTAssertEqual((value?["canvas"] as? [String: Any])?["text_editing"] as? Bool, true)
    XCTAssertTrue(s.editingText); XCTAssertEqual(s.characterRange, NSRange(location: 2, length: 4))
    XCTAssertEqual(store.project, before); XCTAssertEqual(store.engine.projectGeneration, generation)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}
