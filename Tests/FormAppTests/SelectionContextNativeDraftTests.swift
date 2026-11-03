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

  func testPrivateBridgePreservesMountedNativeCompositionDraftFocusAndUndo() async throws {
    var project = Project(name: "Native context draft")
    var frame = try project.makeObject(recipeID: "artboard")
    var element = ArtworkElement(kind: "text", x: 10, y: 12, width: 140, height: 50,
      text: "Keep 👩🏽‍💻 source", fontSize: 18)
    var typography = Typography()
    typography.fontName = "Helvetica"; typography.frameMode = "area"
    element.typography = typography
    frame.artwork = .init(elements: [element]); project.objects = [frame]
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
