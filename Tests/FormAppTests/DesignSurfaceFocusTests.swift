import AppKit
import FormCore
import XCTest
@testable import FormApp

/// Deliver AppKit focus notifications to real, hidden native hosts. No window
/// is activated and no input is sent to the user's running LAB process.
@MainActor final class DesignSurfaceFocusTests:XCTestCase {
  private struct Fixture {
    let store:StudioStore,hosts:DesignSurfaceHostController
    let window:NSWindow,split:DesignSurfaceSplitView
  }
  private func fixture(split:Bool=false)throws->Fixture {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("design-focus-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var project=Project(name:"Retained design target")
    project.objects=[try project.makeObject(recipeID:"box")]
    let canvas=try project.ensureCanvasWorkspace()
    project.schemaVersion=project.minimumSchemaVersion
    store.engine.project=project;store.showingHome=false;store.mode = .table
    store.artworkSession.objectID=canvas.id
    store.surfaceLayout=split ? .split:.single
    let hosts=DesignSurfaceHostController(store:store)
    let window=NSWindow(contentRect:.init(x:0,y:0,width:1200,height:800),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let view=DesignSurfaceSplitView(frame:window.contentView!.bounds)
    window.contentView=view;hosts.attachMain(view);view.layoutSubtreeIfNeeded()
    addTeardownBlock { @MainActor in
      store.closeDetachedCanvas();hosts.detachMain(view)
      window.contentView=nil;window.close();store.engine.project=nil
      try? FileManager.default.removeItem(at:root)
    }
    return .init(store:store,hosts:hosts,window:window,split:view)
  }
  private func becameKey(_ window:NSWindow) {
    NotificationCenter.default.post(name:NSWindow.didBecomeKeyNotification,object:window)
  }
  private func leftLAB(_ window:NSWindow) {
    NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)
    NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:NSApplication.shared)
  }
  private func detached(_ f:Fixture)throws->CanvasWindowController {
    let controller=CanvasWindowController(store:f.store)
    f.store.canvasWindowController=controller;f.store.surfaceLayout = .detached
    let window=try XCTUnwrap(controller.window)
    controller.windowDidBecomeKey(.init(name:NSWindow.didBecomeKeyNotification,object:window))
    return controller
  }

  func testSplitRetainsLastPointerSurfaceAcrossExternalAppAndUtilityWindowFocus()throws {
    let f=try fixture(split:true),before=try XCTUnwrap(f.store.project)
    let table=try XCTUnwrap(f.hosts.tableHost),button=NSButton(title:"Native Table control",target:nil,action:nil)
    table.addSubview(button)
    XCTAssertTrue(f.window.makeFirstResponder(button))
    f.store.activateDesignSurface(.artwork)
    leftLAB(f.window)
    XCTAssertEqual(f.store.mode,.artwork,"Moving focus to Codex preserves the last LAB target")
    becameKey(f.window)
    XCTAssertEqual(f.store.mode,.artwork,"A stale native Table responder cannot override the retained split-pane target")
    let utility=NSWindow(contentRect:.init(x:0,y:0,width:100,height:100),styleMask:[.titled],backing:.buffered,defer:false)
    utility.isReleasedWhenClosed=false;defer{utility.close()}
    becameKey(utility)
    XCTAssertEqual(f.store.mode,.artwork)
    f.store.activateDesignSurface(.table)
    leftLAB(f.window);becameKey(f.window)
    XCTAssertEqual(f.store.mode,.table)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertFalse(f.window.isVisible);XCTAssertFalse(utility.isVisible)
  }

  func testDetachedCanvasAndMainWindowActivationSelectTheirVisibleSurface()throws {
    let f=try fixture(),canvasID=f.store.artworkSession.objectID
    let detached=try detached(f),canvasWindow=try XCTUnwrap(detached.window)
    let before=try XCTUnwrap(f.store.project)
    XCTAssertEqual(f.store.mode,.artwork)
    leftLAB(canvasWindow)
    XCTAssertEqual(f.store.mode,.artwork)
    becameKey(f.window)
    XCTAssertEqual(f.store.mode,.table,"Activating the main window is enough; a Table click is not required")
    detached.windowDidBecomeKey(.init(name:NSWindow.didBecomeKeyNotification,object:canvasWindow))
    XCTAssertEqual(f.store.mode,.artwork)
    detached.windowWillClose(.init(name:NSWindow.willCloseNotification,object:canvasWindow))
    XCTAssertEqual(f.store.mode,.table);XCTAssertEqual(f.store.surfaceLayout,.single)
    XCTAssertNil(f.store.canvasWindowController)
    detached.windowDidBecomeKey(.init(name:NSWindow.didBecomeKeyNotification,object:canvasWindow))
    XCTAssertEqual(f.store.mode,.table,"Late notifications from a closed Canvas cannot restore a stale target")
    detached.close()
    XCTAssertEqual(f.store.artworkSession.objectID,canvasID)
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    XCTAssertFalse(f.window.isVisible);XCTAssertFalse(canvasWindow.isVisible)
  }

  func testHomeIgnoresLateWindowActivationAndReopeningCanvasRestoresItsTarget()throws {
    let f=try fixture(),detached=try detached(f),canvasWindow=try XCTUnwrap(detached.window)
    let objects=try XCTUnwrap(f.store.project?.objects)
    f.store.home()
    XCTAssertTrue(f.store.showingHome);XCTAssertEqual(f.store.mode,.table)
    XCTAssertNil(f.store.canvasWindowController)
    becameKey(f.window)
    detached.windowDidBecomeKey(.init(name:NSWindow.didBecomeKeyNotification,object:canvasWindow))
    XCTAssertTrue(f.store.showingHome);XCTAssertEqual(f.store.mode,.table)
    XCTAssertEqual(f.store.project?.objects,objects)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
    f.store.showSurface(.artwork);f.hosts.refresh()
    becameKey(f.window)
    XCTAssertFalse(f.store.showingHome);XCTAssertEqual(f.store.mode,.artwork)
    leftLAB(f.window)
    XCTAssertEqual(f.store.mode,.artwork)
  }

  func testParkedMainHostDoesNotOverrideAnotherEnvironmentAndStudioModeIsRetained()throws {
    let f=try fixture()
    f.store.mode = .studio
    becameKey(f.window)
    XCTAssertEqual(f.store.mode,.studio,"The shared 3D host does not erase Studio presentation mode")
    f.window.contentView=NSView(frame:f.split.bounds)
    f.store.mode = .artwork
    becameKey(f.window)
    XCTAssertEqual(f.store.mode,.artwork,"A detached/parked Form host is not the visible surface")
  }
}
