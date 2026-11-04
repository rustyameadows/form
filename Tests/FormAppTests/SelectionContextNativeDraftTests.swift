import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class SelectionContextNativeDraftTests: XCTestCase {
  @MainActor private final class Fixture {
    let root: URL
    let store: StudioStore
    let socket: String

    init(project: Project) throws {
      _ = NSApplication.shared
      root = FileManager.default.temporaryDirectory.appendingPathComponent("native-context-" + UUID().uuidString)
      socket = "/tmp/lab-context-" + UUID().uuidString + ".sock"
      let old = ProcessInfo.processInfo.environment["FORM_SOCKET_PATH"]
      setenv("FORM_SOCKET_PATH", socket, 1)
      defer {
        if let old { setenv("FORM_SOCKET_PATH", old, 1) }
        else { unsetenv("FORM_SOCKET_PATH") }
      }
      store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
      store.engine.project = project
      store.showingHome = false
      store.mode = .artwork
    }

    func close() {
      store.bridge.stop()
      store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func context(_ store: StudioStore) throws -> [String: Any] {
    try XCTUnwrap(store.engine.call("form_get_context") as? [String: Any])
  }

  func testPrivateBridgeProtectsDirtyStudioInstanceAndCameraDraftsButAllowsOtherSavedScene() async throws {
    for cameraOnly in [false, true] {
      var project = Project(name: "Independent saved scene edits")
      var page = try project.makeObject(recipeID: "artboard")
      page.artwork = .init(elements: []); project.objects = [page]
      let publication = try PublicationCommands.createPublication(in: &project, name: "Publication", pages: [page.id])
      let physical = try SheetAssemblyCommands.create(in: &project, definition: .init(publicationID: publication))
      var instance = StudioInstance(name: "Native copy", sourceObjectID: physical)
      instance.sheetPose = .init(openingDegrees: 30)
      var scene = StudioComposition(name: "Native scene", camera: project.camera); scene.instances = [instance]
      let otherInstance = StudioInstance(name: "Other copy", sourceObjectID: physical)
      var otherScene = StudioComposition(name: "Other scene", camera: project.camera); otherScene.instances = [otherInstance]
      var presentation = StudioPresentation(); presentation.scenes = [scene, otherScene]; project.studioPresentation = presentation
      let f = try Fixture(project: project)
      defer { f.store.studioComposition.reset(); f.close() }
      let controller = f.store.studioComposition
      controller.reconcile(); controller.selectInstance(instance.id)
      if cameraOnly { controller.change { $0.camera.azimuth += 0.2 } }
      else { controller.changeInstance(id: instance.id) { $0.positionMM.x += 12 } }
      let draft = try XCTUnwrap(controller.draft)
      XCTAssertTrue(controller.dirty); XCTAssertTrue(controller.canUndoDraft)
      XCTAssertNotEqual(draft, scene)
      let before = f.store.project, undo = f.store.engine.undoStack, redo = f.store.engine.redoStack
      let generation = f.store.engine.projectGeneration
      f.store.startBridge(); XCTAssertTrue(f.store.bridgeReady)
      let socket = f.socket
      for command in ["pose_update", "pose_reset"] {
        var arguments: [String: Any] = ["command": command, "scene_id": scene.id.uuidString,
          "instance_id": instance.id.uuidString, "revision": scene.revision]
        if command == "pose_update" { arguments["pose"] = ["openingDegrees": 90] }
        do {
          _ = try await Task.detached { try LocalBridgeClient.call("form_studio_scene", arguments: arguments, socketPath: socket) }.value
          XCTFail("A valid saved-scene pose edit must preserve the dirty native draft")
        } catch { XCTAssertTrue(error.localizedDescription.contains("native Studio draft")) }
        XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.projectGeneration, generation)
        XCTAssertEqual(f.store.engine.undoStack, undo); XCTAssertEqual(f.store.engine.redoStack, redo)
        XCTAssertEqual(controller.draft, draft); XCTAssertTrue(controller.dirty)
        XCTAssertEqual(controller.selectedInstanceID, instance.id)
      }
      let arguments: [String: Any] = ["command": "pose_update", "scene_id": otherScene.id.uuidString,
        "instance_id": otherInstance.id.uuidString, "revision": otherScene.revision, "pose": ["openingDegrees": 75]]
      _ = try await Task.detached { try LocalBridgeClient.call("form_studio_scene", arguments: arguments, socketPath: socket) }.value
      controller.reconcile()
      XCTAssertEqual(controller.draft, draft); XCTAssertTrue(controller.dirty)
      XCTAssertEqual(controller.selectedInstanceID, instance.id)
      XCTAssertEqual(f.store.project?.studioPresentation?.scenes?.first(where: { $0.id == scene.id }), scene)
      let updated = try XCTUnwrap(f.store.project?.studioPresentation?.scenes?.first(where: { $0.id == otherScene.id }))
      XCTAssertEqual(updated.instances.first?.sheetPose?.openingDegrees, 75)
      XCTAssertEqual(updated.revision, otherScene.revision + 1)
      XCTAssertEqual(f.store.project?.objects, before?.objects)
      XCTAssertEqual(f.store.engine.undoStack.count, undo.count + 1)
      XCTAssertTrue(controller.undoDraft()); XCTAssertEqual(controller.draft, scene)
      XCTAssertTrue(controller.redoDraft()); XCTAssertEqual(controller.draft, draft)
    }
  }

  func testPrivateBridgePreservesMountedNativeCompositionDraftFocusAndUndo() async throws {
    var project = Project(name: "Native context draft")
    var frame = try project.makeObject(recipeID: "artboard")
    var element = ArtworkElement(kind: "text", x: 10, y: 12, width: 140, height: 50,
      text: "Keep 👩🏽‍💻 source", fontSize: 18)
    var typography = Typography()
    typography.fontName = "Helvetica"; typography.frameMode = "area"
    element.typography = typography
    frame.artwork = .init(elements: [element]); project.objects = [frame]
    let publication=try PublicationCommands.createPublication(in:&project,name:"Draft inspection",pages:[frame.id])
    let physical=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication))
    var scene=StudioComposition(name:"Inspection scene",camera:project.camera)
    let instance=StudioInstance(name:"Publication copy",sourceObjectID:physical)
    scene.instances=[instance]
    var presentation=StudioPresentation();presentation.scenes=[scene];project.studioPresentation=presentation
    let f = try Fixture(project: project)
    let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let canvas = VectorCanvasView(frame: .init(x: 0, y: 0, width: 900, height: 650))
    let session = f.store.artworkSession
    canvas.session = session; session.canvas = canvas; window.contentView = canvas
    defer {
      canvas.finishText(); window.contentView = nil; window.close(); f.close()
    }
    session.activate(frame.id); session.choose([element.id]); canvas.synchronize()
    canvas.beginText(element)
    let editor = try XCTUnwrap(canvas.activeTextView)
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertFalse(window.isVisible, "The native test must not present a user window.")
    let undo = try XCTUnwrap(editor.undoManager)
    undo.groupsByEvent = false
    undo.beginUndoGrouping()
    defer {
      editor.unmarkText(); editor.didChangeText(); undo.endUndoGrouping()
    }
    editor.setSelectedRange((editor.string as NSString).range(of: "source"))
    editor.setMarkedText("にほん", selectedRange: .init(location: 1, length: 1),
      replacementRange: .init(location: NSNotFound, length: 0))
    editor.didChangeText()
    if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
    XCTAssertTrue(editor.hasMarkedText())
    XCTAssertNotEqual(editor.string, element.text, "The native draft must differ from the committed document.")
    XCTAssertEqual(f.store.project?.objects[0].artwork?.elements[0].text, element.text)
    let native = NSAttributedString(attributedString: editor.attributedString())
    let marked = editor.markedRange(), selected = editor.selectedRange(), characterRange = session.characterRange
    let before = f.store.project, generation = f.store.engine.projectGeneration
    let engineUndo = f.store.engine.undoStack, engineRedo = f.store.engine.redoStack
    let undoLevel = undo.groupingLevel, canUndo = undo.canUndo, canRedo = undo.canRedo
    let undoName = undo.undoActionName, redoName = undo.redoActionName
    f.store.startBridge(); XCTAssertTrue(f.store.bridgeReady)
    let socket = f.socket
    let result = try await Task.detached {
      try LocalBridgeClient.call("form_get_context", arguments: [:], socketPath: socket) as? [String: Any]
    }.value
    let value = try XCTUnwrap(result)
    let inspections:[(String,[String:Any])]=[
      ("form_get_project",["view":"summary"]),
      ("form_get_project",["view":"scoped","sections":["objects"],"object_ids":[frame.id.uuidString]]),
      ("form_capabilities",["command":"schema","tool_names":["form_publication"]]),
      ("form_publication",["command":"preflight","publication_id":publication.uuidString]),
      ("form_publication",["command":"sheet_assembly_inspect","object_id":physical.uuidString]),
      ("form_studio_scene",["command":"pose_get","scene_id":scene.id.uuidString,"instance_id":instance.id.uuidString])]
    for (name,arguments) in inspections {
      let inspected=try await Task.detached {
        try LocalBridgeClient.call(name,arguments:arguments,socketPath:socket)
      }.value
      XCTAssertNotNil(inspected as? [String:Any],"Native read-only route must accept \(name) without ending marked text")
    }
    for arguments:[String:Any] in [
      ["project_id":project.id.uuidString,"view":"scoped","sections":["objects"],"object_ids":[UUID().uuidString]],
      ["project_id":project.id.uuidString,"view":"invalid"]] {
      do {
        _=try await Task.detached {try LocalBridgeClient.call("form_open_project",arguments:arguments,socketPath:socket)}.value
        XCTFail("An invalid open projection must preserve the mounted marked-text draft before field commits")
      }catch{}
    }
    let navigation=try XCTUnwrap(PublicationPreflightTarget(issue:["object_id":frame.id.uuidString,"element_id":element.id.uuidString],
      projectID:project.id,publicationID:publication))
    XCTAssertFalse(session.publicationWorkspace.focusPreflightIssue(navigation),"Preflight navigation must preserve active marked text")
    let rejectedPoses:[[String:Any]]=[
      ["command":"pose_update","scene_id":scene.id.uuidString,"instance_id":instance.id.uuidString,"revision":scene.revision+1,"pose":["openingDegrees":90]],
      ["command":"pose_update","scene_id":scene.id.uuidString,"instance_id":instance.id.uuidString,"revision":scene.revision,"pose":["bendMM":100]],
      ["command":"pose_update","scene_id":scene.id.uuidString,"instance_id":instance.id.uuidString,"revision":scene.revision,"page_label":"Missing folio"],
      ["command":"pose_update","scene_id":scene.id.uuidString,"instance_id":instance.id.uuidString,"revision":scene.revision,"pose":["openingDegrees":90]]]
    for arguments in rejectedPoses {
      do {
        _=try await Task.detached {try LocalBridgeClient.call("form_studio_scene",arguments:arguments,socketPath:socket)}.value
        XCTFail("Invalid pose requests and active marked text must reject before committing the draft")
      }catch{}
    }
    for command in ["settings","unknown_publication_command"] {
      let arguments:[String:Any]=["command":command,"publication_id":publication.uuidString,
        "margins":["top":-1,"right":14,"bottom":14,"left":14]]
      do {
        _=try await Task.detached {try LocalBridgeClient.call("form_publication",arguments:arguments,socketPath:socket)}.value
        XCTFail("Invalid publication writes must not commit a standalone text draft")
      }catch{}
    }
    let target = try XCTUnwrap(value["active_target"] as? [String: Any])
    let reported = try XCTUnwrap(value["canvas"] as? [String: Any])
    XCTAssertEqual(target["object_id"] as? String, frame.id.uuidString)
    XCTAssertEqual(target["element_ids"] as? [String], [element.id.uuidString])
    XCTAssertEqual(reported["text_editing"] as? Bool, true)
    XCTAssertEqual(reported["uncommitted_text_may_differ"] as? Bool, true)
    let range = try XCTUnwrap(reported["text_selection_utf16"] as? [String: Int])
    XCTAssertEqual(range, ["location": characterRange.location, "length": characterRange.length])
    XCTAssertTrue(canvas.activeTextView === editor); XCTAssertTrue(window.firstResponder === editor)
    XCTAssertNotNil(editor.superview); XCTAssertTrue(editor.hasMarkedText())
    XCTAssertEqual(editor.markedRange(), marked); XCTAssertEqual(editor.selectedRange(), selected)
    XCTAssertTrue(GlyphEngine.nativeEqual(editor.attributedString(), native))
    XCTAssertEqual(session.characterRange, characterRange); XCTAssertTrue(session.editingText)
    XCTAssertEqual(undo.groupingLevel, undoLevel); XCTAssertEqual(undo.canUndo, canUndo)
    XCTAssertEqual(undo.canRedo, canRedo); XCTAssertEqual(undo.undoActionName, undoName)
    XCTAssertEqual(undo.redoActionName, redoName)
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.projectGeneration, generation)
    XCTAssertEqual(f.store.engine.undoStack, engineUndo); XCTAssertEqual(f.store.engine.redoStack, engineRedo)
  }

  func testPathReferenceFiltersStaleAndUnselectedNodesWithoutPruningNativeSelection() throws {
    var project = Project(name: "Precise node context")
    var frame = try project.makeObject(recipeID: "artboard")
    var path = ArtworkElement(kind: "path", x: 10, y: 10, width: 40, height: 30)
    path.path = .init(width: 40, height: 30, contours: [
      .init([.init(.init(0, 0)), .init(.init(40, 0)), .init(.init(20, 30))]),
    ])
    var other = ArtworkElement(kind: "path", x: 70, y: 10, width: 10, height: 10)
    other.path = .init(width: 10, height: 10, contours: [.init([.init(.init(0, 0)), .init(.init(10, 10))], closed: false)])
    frame.artwork = .init(elements: [path, other]); project.objects = [frame]
    let f = try Fixture(project: project); defer { f.close() }
    let session = f.store.artworkSession
    session.activate(frame.id); session.choose([path.id]); session.tool = .direct
    let valid = try XCTUnwrap(path.path?.contours.first?.nodes.first?.id)
    let unselected = try XCTUnwrap(other.path?.contours.first?.nodes.first?.id)
    let stale = UUID()
    session.nodes = [valid, unselected, stale]
    let before = f.store.project, generation = f.store.engine.projectGeneration
    let value = try context(f.store)
    let target = try XCTUnwrap(value["active_target"] as? [String: Any])
    let canvas = try XCTUnwrap(value["canvas"] as? [String: Any])
    XCTAssertEqual(target["element_ids"] as? [String], [path.id.uuidString])
    XCTAssertEqual(target["node_ids"] as? [String], [valid.uuidString])
    XCTAssertEqual(canvas["selected_node_ids"] as? [String], [valid.uuidString])
    XCTAssertEqual(f.store.currentSelectionReference?.copiedIDs, valid.uuidString)
    XCTAssertEqual(session.nodes, [valid, unselected, stale], "Reading context must not reconcile or prune UI state.")
    XCTAssertEqual(session.selection, [path.id]); XCTAssertEqual(f.store.project, before)
    XCTAssertEqual(f.store.engine.projectGeneration, generation); XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }

  func testUnmaterializedInsideFaceHasPhysicalIdentityButNoMisleadingSourceQuery() throws {
    var project = try PaperSamples.sunStudies()
    let index = try XCTUnwrap(project.objects.firstIndex { PaperConstruction.isPaper($0) })
    let physicalID = project.objects[index].id
    var definition = try PaperConstruction.definition(for: project.objects[index])
    definition.insideArtworkSourceID = nil
    definition.insideArtwork = .init(elements: [
      .init(kind: "text", x: 10, y: 10, width: 50, height: 15, text: "Legacy inside artwork"),
    ])
    project.objects[index].paperConstruction = definition
    let f = try Fixture(project: project); defer { f.close() }
    let session = f.store.artworkSession
    let frame = try XCTUnwrap(session.frames.first {
      $0.projection?.constructionID == physicalID && $0.projection?.inside == true && $0.projection?.panelID != nil
    })
    XCTAssertTrue(frame.projection?.requiresInsideSource == true)
    session.activate(frame.id)
    let before = f.store.project, generation = f.store.engine.projectGeneration
    let value = try context(f.store)
    let target = try XCTUnwrap(value["active_target"] as? [String: Any])
    let canvas = try XCTUnwrap(value["canvas"] as? [String: Any])
    XCTAssertEqual(target["kind"] as? String, "physical_surface")
    XCTAssertEqual(target["frame_id"] as? String, frame.id.uuidString)
    XCTAssertEqual(target["physical_object_id"] as? String, physicalID.uuidString)
    XCTAssertEqual(target["surface_id"] as? String, frame.projection?.panelID)
    XCTAssertEqual(target["side"] as? String, "inside")
    XCTAssertEqual(target["source_available"] as? Bool, false)
    XCTAssertNil(target["object_id"])
    XCTAssertNil(canvas["canonical_artwork_query"]); XCTAssertNil(canvas["view_artwork_query"])
    XCTAssertEqual(canvas["editable"] as? Bool, false)
    XCTAssertEqual(f.store.currentSelectionReference?.copiedIDs, physicalID.uuidString)
    XCTAssertEqual(f.store.project, before); XCTAssertEqual(f.store.engine.projectGeneration, generation)
    XCTAssertNil(f.store.project?.objects[index].paperConstruction?.insideArtworkSourceID)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
}
