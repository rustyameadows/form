import AppKit
import FormCore
import SwiftUI
import XCTest
@testable import FormApp

/// Surface transitions use hidden AppKit windows. These tests never order a
/// window front or send input to the user's running FORM process.
@MainActor final class DesignSurfaceTests: XCTestCase {
  private func fixture(withCanvas:Bool = false) throws -> (StudioStore,URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root:root)
    var project = Project(name:"Design surface lifecycle")
    var box = try project.makeObject(recipeID:"box")
    box.position = .init(-140,0,60)
    var sheet = try project.makeObject(recipeID:"artboard")
    sheet.position = .init(160,0,-100)
    sheet.artwork = Artwork(elements:[ArtworkElement(kind:"text",x:10,y:10,width:80,height:20,text:"Surface study")])
    project.objects = [box,sheet]
    if withCanvas {
      let workspace = try project.ensureCanvasWorkspace()
      let index = project.objects.firstIndex {$0.id == workspace.id}!
      project.objects[index].artwork!.elements = [ArtworkElement(kind:"text",x:10,y:10,width:100,height:25,text:"Canvas draft")]
    }
    project.schemaVersion = project.minimumSchemaVersion
    try repository.save(project)
    let store = StudioStore(repository:repository,seedLibrary:false)
    try store.engine.open(project.id)
    store.showingHome = false
    return (store,root)
  }
  private func clean(_ store:StudioStore,_ root:URL) {
    store.closeDetachedCanvas()
    store.engine.project = nil
    try? FileManager.default.removeItem(at:root)
  }
  private func descendants<T:NSView>(_ root:NSView,of type:T.Type) -> [T] {
    ((root as? T).map {[$0]} ?? []) + root.subviews.flatMap {descendants($0,of:type)}
  }
  private func hiddenController(_ store:StudioStore) -> CanvasWindowController {
    let controller = CanvasWindowController(store:store)
    XCTAssertFalse(controller.window!.isVisible)
    store.canvasWindowController = controller
    store.surfaceLayout = .detached
    return controller
  }
  private func event(_ type:NSEvent.EventType,view:NSView,point:NSPoint = .init(x:100,y:100)) -> NSEvent {
    NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:0,
      windowNumber:view.window?.windowNumber ?? 0,context:nil,eventNumber:1,clickCount:1,
      pressure:type == .leftMouseUp ? 0:1)!
  }
  private func settle(_ view:NSView) {
    // NSHostingView schedules representable replacement on the main run loop.
    // No window is made visible while those native lifecycle callbacks run.
    for _ in 0..<4 {
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
    }
  }

  func testEnsureCanvasIsOneUndoableCreationAndLaterVisitsDoNotMutateTheProject() throws {
    let (store,root) = try fixture(); defer {clean(store,root)}
    let before = try XCTUnwrap(store.project)
    let id = try XCTUnwrap(store.ensureCanvas())
    let created = try XCTUnwrap(store.project)
    XCTAssertEqual(created.objects.filter(\.isCanvasWorkspace).count,1)
    XCTAssertEqual(created.objects.filter { !$0.isCanvasWorkspace },before.objects)
    XCTAssertEqual(created.history.count,before.history.count+1)
    XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertEqual(store.artworkSession.objectID,id)
    for _ in 0..<5 {XCTAssertEqual(store.ensureCanvas(),id)}
    XCTAssertEqual(store.project,created)
    XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo(); XCTAssertEqual(store.project,before)
    store.engine.redo(); XCTAssertEqual(store.project,created)
    try store.engine.flush()
    let canonical = try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(created))
    XCTAssertEqual(try store.repository.load(created.id),canonical)
  }

  func testSplitFocusChangesThroughActualPointerHandlersRetainBothSurfacesAndProject() throws {
    let (store,root) = try fixture(withCanvas:true); defer {clean(store,root)}
    store.showSplit()
    let before = try XCTUnwrap(store.project)
    let window = NSWindow(contentRect:.init(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let container = NSView(frame:window.contentView!.bounds)
    window.contentView = container
    defer {window.contentView = nil; window.close()}
    let scene = TableSceneController(store:store)
    let table = TableSCNView(frame:.init(x:600,y:0,width:600,height:800))
    table.controller = scene; scene.view = table; store.scene = scene
    table.scene = scene.scene; table.pointOfView = scene.cameraNode
    let canvas = VectorCanvasView(frame:.init(x:0,y:0,width:600,height:800))
    canvas.session = store.artworkSession; store.artworkSession.canvas = canvas
    container.addSubview(table); container.addSubview(canvas)
    canvas.synchronize()
    table.mouseDown(with:event(.leftMouseDown,view:table))
    XCTAssertEqual(store.mode,.table)
    XCTAssertEqual(store.surfaceLayout,.split)
    table.cancelPointerInteraction()
    canvas.mouseDown(with:event(.leftMouseDown,view:canvas))
    canvas.mouseUp(with:event(.leftMouseUp,view:canvas))
    XCTAssertEqual(store.mode,.artwork)
    XCTAssertEqual(store.surfaceLayout,.split)
    XCTAssertTrue(store.artworkSession.canvas === canvas)
    XCTAssertEqual(store.project,before)
    XCTAssertFalse(window.isVisible)
  }

  func testStandaloneCanvasAndTableVisitsPreserveDocumentAndUseTheSharedCanvas() throws {
    let (store,root) = try fixture(withCanvas:true); defer {clean(store,root)}
    let before = try XCTUnwrap(store.project),workspace = try XCTUnwrap(before.canvasWorkspace)
    let physicalSheet = before.objects.first { $0.recipeID == "artboard" && !$0.isCanvasWorkspace }!
    store.artworkSession.activate(physicalSheet.id)
    store.showSurface(.artwork)
    XCTAssertEqual(store.artworkSession.objectID,workspace.id)
    XCTAssertEqual(store.surfaceLayout,.single)
    XCTAssertEqual(store.mode,.artwork)
    store.showSurface(.table)
    XCTAssertEqual(store.mode,.table)
    XCTAssertEqual(store.surfaceLayout,.single)
    store.showSplit()
    store.activateDesignSurface(.table)
    XCTAssertEqual(store.surfaceLayout,.split)
    store.showSurface(.studio)
    XCTAssertEqual(store.mode,.studio)
    XCTAssertEqual(store.surfaceLayout,.single)
    XCTAssertEqual(store.project,before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testDetachedWindowFocusCloseAndDockKeepProjectAndOneControllerOwnership() throws {
    let (store,root) = try fixture(withCanvas:true); defer {clean(store,root)}
    let before = try XCTUnwrap(store.project)
    let first = hiddenController(store)
    first.windowDidBecomeKey(Notification(name:NSWindow.didBecomeKeyNotification,object:first.window))
    XCTAssertEqual(store.mode,.artwork)
    XCTAssertEqual(store.surfaceLayout,.detached)
    XCTAssertTrue(store.canvasWindowController === first)
    first.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:first.window))
    XCTAssertNil(store.canvasWindowController)
    XCTAssertEqual(store.surfaceLayout,.single)
    XCTAssertEqual(store.mode,.table)
    first.close()
    let second = hiddenController(store)
    store.dockCanvas()
    XCTAssertNil(store.canvasWindowController)
    XCTAssertEqual(store.surfaceLayout,.split)
    XCTAssertEqual(store.mode,.artwork)
    XCTAssertFalse(second.window!.isVisible)
    XCTAssertEqual(store.project,before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testLateCloseFromAnOldDetachedWindowCannotClearItsReplacement() throws {
    let (store,root) = try fixture(withCanvas:true); defer {clean(store,root)}
    let before = try XCTUnwrap(store.project)
    let first = hiddenController(store)
    store.closeDetachedCanvas()
    let replacement = hiddenController(store)
    store.activateDesignSurface(.artwork)
    first.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:first.window))
    XCTAssertTrue(store.canvasWindowController === replacement)
    XCTAssertEqual(store.surfaceLayout,.detached)
    XCTAssertEqual(store.mode,.artwork)
    XCTAssertEqual(store.project,before)
  }

  func testProjectChangeClosesDetachedCanvasAndRetainsBothSavedProjects() throws {
    let (store,root) = try fixture(withCanvas:true); defer {clean(store,root)}
    let previous = try XCTUnwrap(store.project)
    let controller = hiddenController(store)
    var next = Project(name:"Second project")
    next.objects = [try next.makeObject(recipeID:"cylinder")]
    try store.repository.save(next)
    let expected = try store.repository.load(next.id)
    store.openProject(next.id)
    XCTAssertNil(store.canvasWindowController)
    XCTAssertEqual(store.surfaceLayout,.single)
    XCTAssertEqual(store.mode,.table)
    XCTAssertFalse(controller.window!.isVisible)
    XCTAssertEqual(store.project,expected)
    XCTAssertEqual(try store.repository.load(previous.id),previous)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertNil(store.project!.canvasWorkspace)
    let workspace = try XCTUnwrap(store.ensureCanvas())
    let created = try XCTUnwrap(store.project)
    XCTAssertEqual(created.canvasWorkspace?.id,workspace)
    XCTAssertEqual(created.objects.filter { !$0.isCanvasWorkspace },expected.objects)
    XCTAssertEqual(created.history.count,expected.history.count+1)
    store.engine.undo(); XCTAssertEqual(store.project,expected)
  }

  func testTableNeverBuildsOrFramesTheUnframedCanvasAndIgnoresItsArtworkChanges() throws {
    let (store,root) = try fixture(); defer {clean(store,root)}
    let controller = TableSceneController(store:store)
    store.scene = controller; store.synchronizeScene(); controller.fitAll()
    let before = controller.camera,builds = controller.geometryBuilds
    XCTAssertEqual(controller.objectRoot.childNodes.count,2)
    let workspace = try XCTUnwrap(store.ensureCanvas())
    store.synchronizeScene(); controller.fitAll()
    XCTAssertEqual(controller.objectRoot.childNodes.count,2)
    XCTAssertEqual(controller.geometryBuilds,builds)
    XCTAssertEqual(controller.camera,before)
    XCTAssertFalse(controller.objectRoot.childNodes.contains {$0.name == "object:\(workspace.uuidString)"})
    try store.engine.edit("Canvas-only design") { project in
      let i = project.objects.firstIndex {$0.id == workspace}!
      project.objects[i].artwork!.elements = [ArtworkElement(kind:"rectangle",x:-900,y:800,width:1800,height:1700)]
    }
    store.synchronizeScene(); controller.fitAll()
    XCTAssertEqual(controller.geometryBuilds,builds)
    XCTAssertEqual(controller.camera,before)
  }

  func testHostedSingleSplitDetachedAndDockedLayoutsHaveExactlyOneNativeCanvasOwner() throws {
    let (store,root) = try fixture(withCanvas:true); defer {clean(store,root)}
    store.showSurface(.artwork)
    let before = try XCTUnwrap(store.project)
    let window = NSWindow(contentRect:.init(x:0,y:0,width:1800,height:1000),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let main = NSHostingView(rootView:WorkspaceView().environmentObject(store))
    window.contentView = main
    defer {window.contentView = nil; window.close()}
    settle(main)
    XCTAssertEqual(descendants(main,of:VectorCanvasView.self).count,1)
    XCTAssertTrue(store.artworkSession.canvas === descendants(main,of:VectorCanvasView.self).first)
    store.showSplit(); settle(main)
    XCTAssertEqual(descendants(main,of:VectorCanvasView.self).count,1)
    XCTAssertEqual(descendants(main,of:TableSCNView.self).filter {$0.controller?.store != nil}.count,1)
    let detached = hiddenController(store)
    settle(main); settle(detached.window!.contentView!)
    XCTAssertTrue(descendants(main,of:VectorCanvasView.self).isEmpty)
    let separate = descendants(detached.window!.contentView!,of:VectorCanvasView.self)
    XCTAssertEqual(separate.count,1)
    XCTAssertTrue(store.artworkSession.canvas === separate.first)
    store.dockCanvas(); settle(main)
    let docked = descendants(main,of:VectorCanvasView.self)
    XCTAssertEqual(docked.count,1)
    XCTAssertTrue(store.artworkSession.canvas === docked.first)
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(detached.window!.isVisible)
    // Resizing the Table records its actual display aspect. Every design value,
    // camera pose/pivot/distance, timestamp, and history entry must stay intact.
    var expected = before
    expected.camera.viewportAspect = store.project?.camera.viewportAspect
    XCTAssertEqual(store.project,expected)
  }
}
