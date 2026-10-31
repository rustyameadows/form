import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class StudioImageWorkflowIntegrationTests:XCTestCase {
  private final class TextUndoDelegate:NSObject,NSTextViewDelegate {
    let manager=UndoManager()
    func undoManager(for view:NSTextView)->UndoManager? {manager}
    func replace(_ view:NSTextView,with value:String) {
      let prior=view.string
      manager.registerUndo(withTarget:self){$0.replace(view,with:prior)}
      view.string=value
    }
  }
  private func fixture(canvas:Bool=false)throws->StudioStore {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("studio-image-integration-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    var project=Project(name:"Still workflow integration")
    project.objects=[try project.makeObject(recipeID:"box",parameters:["width":100,"height":80,"depth":60])]
    if canvas {_ = try project.ensureCanvasWorkspace()}
    store.engine.project=project;store.showingHome=false;store.showEnvironment(.studio)
    store.studioComposition.reconcile();store.studioComposition.frameScene()
    addTeardownBlock {@MainActor in
      store.studioImages.reset();store.studioComposition.reset();store.utilityWindows?.shutdown();store.engine.project=nil
      try? FileManager.default.removeItem(at:root)
    }
    return store
  }
  private func png()throws->Data {
    let image=NSImage(size:.init(width:80,height:60));image.lockFocus()
    NSColor.systemTeal.setFill();NSBezierPath(rect:.init(x:0,y:0,width:80,height:60)).fill();image.unlockFocus()
    return try XCTUnwrap(image.pngData())
  }
  private func settle()async throws {try await Task.sleep(nanoseconds:100_000_000)}

  func testPromptUndoUsesNativeTextHistoryAndNeverChangesHiddenComposition()async throws {
    let store=try fixture(),before=try XCTUnwrap(store.project),draft=store.studioComposition.draft
    store.studioShowingImages=true
    let window=NSWindow(contentRect:.init(x:60,y:60,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let text=NSTextView(frame:.init(x:20,y:20,width:400,height:200)),delegate=TextUndoDelegate()
    text.delegate=delegate;text.allowsUndo=true;delegate.manager.groupsByEvent=false
    window.contentView?.addSubview(text);window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(text))
    defer {delegate.manager.removeAllActions();window.makeFirstResponder(nil);window.close()}
    delegate.manager.beginUndoGrouping();delegate.replace(text,with:"A new image prompt");delegate.manager.endUndoGrouping()
    XCTAssertTrue(window.firstResponder === text)
    XCTAssertTrue(text.undoManager === delegate.manager)
    XCTAssertTrue(delegate.manager.canUndo)
    XCTAssertTrue(store.applyStudioImageTextHistory(in:window));XCTAssertEqual(text.string,"")
    XCTAssertTrue(store.applyStudioImageTextHistory(in:window,redo:true));XCTAssertEqual(text.string,"A new image prompt")
    window.makeFirstResponder(nil);store.undo();store.redo()
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.studioComposition.draft,draft)
  }

  func testGlobalLibraryAndConnectionAreNormalWindowsAcrossHomeAndNativeCloseReleasesKeyEditor()async throws {
    let store=try fixture(),before=try XCTUnwrap(store.project),windows=StudioUtilityWindows(store:store)
    defer {windows.shutdown()}
    store.openAssetLibrary();store.showingOpenAISetup=true;try await settle()
    let library=try XCTUnwrap(windows.window(for:.assets)),connection=try XCTUnwrap(windows.window(for:.openAISetup))
    for window in [library,connection] {
      XCTAssertTrue(window.isVisible);XCTAssertNil(window.sheetParent);XCTAssertTrue(window.sheets.isEmpty)
      XCTAssertEqual(window.level,.normal);XCTAssertTrue(window.styleMask.contains(.resizable))
    }
    XCTAssertNil(NSApp.modalWindow);XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    connection.performClose(nil)
    XCTAssertNil(windows.window(for:.openAISetup));XCTAssertNil(connection.contentViewController)
    XCTAssertFalse(store.showingOpenAISetup)
    store.showingOpenAISetup=true;try await settle()
    let fresh=try XCTUnwrap(windows.window(for:.openAISetup));XCTAssertFalse(fresh === connection)
    store.home();try await settle()
    XCTAssertTrue(library.isVisible);XCTAssertTrue(fresh.isVisible)
    XCTAssertEqual(store.project?.objects,before.objects)
  }

  func testCreateStillEntryFreezesWorkingDraftAndHomeCancelsWithoutSavingDesign()async throws {
    let store=try fixture(),before=try XCTUnwrap(store.project),composition=store.studioComposition
    composition.change {$0.instances[0].positionMM.x=37}
    let draft=try XCTUnwrap(composition.draft)
    store.createStudioStill()
    for _ in 0..<120 {
      if store.studioImages.capture != nil && !store.studioImages.busy {break}
      try await Task.sleep(nanoseconds:25_000_000)
    }
    XCTAssertTrue(store.studioShowingImages);XCTAssertEqual(store.environment,.studio)
    let captured=try XCTUnwrap(store.studioImages.capture,store.studioImages.error ?? "No native input captured")
    XCTAssertEqual(captured.scene.instances,draft.instances);XCTAssertEqual(captured.camera,composition.stage.camera)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    store.home()
    XCTAssertFalse(store.studioShowingImages);XCTAssertNil(store.studioImages.capture);XCTAssertFalse(store.studioImages.busy)
    XCTAssertEqual(store.project?.objects,before.objects)
  }

  func testExplicitLibraryCanvasPlacementUsesExistingImporterAndOneUndoPreservesOriginalAsset()throws {
    let store=try fixture(canvas:true),before=try XCTUnwrap(store.project),data=try png()
    let asset=try store.studioAssets.register(data:data,filename:"demo.png",name:"Local demo image",
      metadata:.init(kind:.image,origin:.generated,projectID:before.id,isMock:true))
    let original=try store.studioAssets.fileURL(for:asset)
    store.placeLibraryAssetOnCanvas(asset)
    let current=try XCTUnwrap(store.project),workspace=try XCTUnwrap(current.canvasWorkspace)
    let image=try XCTUnwrap(workspace.artwork?.elements.first(where:{$0.kind=="image"}))
    XCTAssertEqual(store.environment,.form);XCTAssertEqual(store.mode,.artwork)
    XCTAssertEqual(current.objects.first{$0.id==before.objects[0].id},before.objects[0])
    let imported=store.repository.url(for:current.id).appendingPathComponent("Assets").appendingPathComponent(try XCTUnwrap(image.asset))
    XCTAssertEqual(try Data(contentsOf:imported),data);XCTAssertEqual(try Data(contentsOf:original),data)
    XCTAssertEqual(store.engine.undoStack.count,1)
    store.engine.undo();XCTAssertEqual(store.project?.objects,before.objects)
    XCTAssertEqual(try Data(contentsOf:original),data)
  }
}
