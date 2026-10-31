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
    store.studioComposition.reconcile();store.studioComposition.change{$0.pixels = .init(width:300,height:200)};store.studioComposition.frameScene()
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

  func testProjectLibraryClosesAtHomeWhileGlobalConnectionSurvivesAndReleasesItsKeyEditor()async throws {
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
    XCTAssertFalse(library.isVisible);XCTAssertNil(library.contentViewController)
    XCTAssertNil(windows.window(for:.assets));XCTAssertFalse(store.showingAssets)
    XCTAssertTrue(fresh.isVisible)
    store.openAssetLibrary();try await settle()
    XCTAssertFalse(store.showingAssets);XCTAssertNil(windows.window(for:.assets))
    store.showingAssets=true;try await settle()
    XCTAssertFalse(store.showingAssets);XCTAssertNil(windows.window(for:.assets),"A stale request cannot reopen project Library on Home")
    XCTAssertEqual(store.project?.objects,before.objects)
  }

  func testProjectSwitchReplacesLibraryOwnerDiscardsOldWindowAndOpensEmptyProjectNormally()async throws {
    let store=try fixture(),first=try XCTUnwrap(store.project),windows=StudioUtilityWindows(store:store)
    defer{windows.shutdown()}
    try store.repository.save(first)
    let libraryA=store.studioAssets
    let connection=store.studioImageConnection
    connection.useDemoConnection()
    XCTAssertTrue(store.studioImages.connection === connection)
    XCTAssertEqual(libraryA.projectID,first.id)
    let bytes=try png()
    let asset=try libraryA.register(data:bytes,filename:"only-a.png",metadata:.init(kind:.image,origin:.uploaded))
    store.openAssetLibrary();try await settle()
    let oldWindow=try XCTUnwrap(windows.window(for:.assets))
    XCTAssertTrue(oldWindow.isVisible);XCTAssertTrue(oldWindow.title.contains(first.name))
    let second=Project(name:"Empty project B");try store.repository.save(second)
    store.openProject(second.id);try await settle()
    let libraryB=store.studioAssets
    XCTAssertTrue(store.studioImages.connection === connection)
    XCTAssertEqual(store.studioImages.connection.state,.demoReady)
    XCTAssertFalse(libraryB === libraryA);XCTAssertEqual(libraryB.projectID,second.id)
    XCTAssertNil(libraryB.asset(id:asset.id));XCTAssertTrue(libraryB.visibleItems.isEmpty)
    XCTAssertFalse(oldWindow.isVisible);XCTAssertNil(oldWindow.contentViewController);XCTAssertNil(windows.window(for:.assets))
    XCTAssertFalse(store.showingAssets)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    store.openAssetLibrary();try await settle()
    let emptyWindow=try XCTUnwrap(windows.window(for:.assets))
    XCTAssertFalse(emptyWindow === oldWindow);XCTAssertTrue(emptyWindow.isVisible)
    XCTAssertTrue(emptyWindow.title.contains(second.name));XCTAssertNil(emptyWindow.sheetParent);XCTAssertEqual(emptyWindow.level,.normal)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    store.openProject(first.id);try await settle()
    XCTAssertFalse(emptyWindow.isVisible);XCTAssertNil(emptyWindow.contentViewController)
    let returned=store.studioAssets
    XCTAssertEqual(returned.projectID,first.id);XCTAssertNotNil(returned.asset(id:asset.id))
    XCTAssertEqual(try Data(contentsOf:returned.fileURL(for:asset)),bytes)
  }

  func testForeignLibraryCanvasAndReferenceActionsCannotMutateTheCurrentProjectOrWorkflow()async throws {
    let store=try fixture(),first=try XCTUnwrap(store.project)
    try store.repository.save(first)
    let oldLibrary=store.studioAssets,data=try png()
    let foreign=try oldLibrary.register(data:data,filename:"foreign.png",metadata:.init(kind:.image,origin:.uploaded))
    let sourceURL=try oldLibrary.fileURL(for:foreign)
    let second=Project(name:"Unrelated empty project");try store.repository.save(second)
    store.openProject(second.id)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,mode=store.mode,environment=store.environment
    let currentLibrary=store.studioAssets,workflow=store.studioImages
    let references=workflow.references,prompt=workflow.prompt
    store.placeLibraryAssetOnCanvas(foreign)
    store.useLibraryAssetAsReference(foreign)
    try await settle()
    XCTAssertEqual(currentLibrary.projectID,second.id);XCTAssertNil(currentLibrary.asset(id:foreign.id))
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertEqual(store.mode,mode);XCTAssertEqual(store.environment,environment);XCTAssertFalse(store.studioShowingImages)
    XCTAssertNil(store.project?.canvasWorkspace);XCTAssertEqual(workflow.references,references);XCTAssertEqual(workflow.prompt,prompt)
    XCTAssertNil(workflow.capture);XCTAssertFalse(workflow.busy)
    XCTAssertEqual(try Data(contentsOf:sourceURL),data)
    let own=try currentLibrary.register(data:data,filename:"project-b.png",metadata:.init(kind:.image,origin:.uploaded))
    store.home();let homeProject=store.project
    store.placeLibraryAssetOnCanvas(own);store.useLibraryAssetAsReference(own)
    try await settle()
    XCTAssertTrue(store.showingHome);XCTAssertFalse(store.studioShowingImages)
    XCTAssertEqual(store.project,homeProject);XCTAssertEqual(store.engine.undoStack.count,undo)
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

  func testGenerateImageEntryRefreshesChangedStudioPixelsAndKeepsNextFormAndPriorRunFrozen()async throws {
    let store=try fixture(),source=try XCTUnwrap(store.project),composition=store.studioComposition,images=store.studioImages
    images.prompt="First native view";await images.captureScene();await images.generate()
    let previous=try XCTUnwrap(images.currentRun),oldCapture=try XCTUnwrap(images.capture)
    let oldBytes=try Data(contentsOf:images.imageURL(assetID:oldCapture.inputAssetID))
    images.prompt="Keep this next image prompt";images.style="Keep this next style"
    images.options.model = .flare;images.options.quality = .draft;images.options.count=2
    images.references=[.init(assetID:oldCapture.inputAssetID,role:.composition)]
    let prompt=images.prompt,style=images.style,references=images.references
    var expected=images.options;let pixels=StudioPixels(width:641,height:853);expected.outputPixels=pixels
    composition.change{$0.pixels=pixels}
    let draft=composition.draft,camera=composition.stage.camera,undo=store.engine.undoStack.count
    store.studioShowingImages=false;store.createStudioStill()
    for _ in 0..<400 {
      if images.capture?.id != oldCapture.id,images.capture?.hasExactStudioPixels==true,!images.busy {break}
      try await Task.sleep(nanoseconds:10_000_000)
    }
    let fresh=try XCTUnwrap(images.capture,images.error ?? "No refreshed native image")
    XCTAssertNotEqual(fresh.id,oldCapture.id);XCTAssertEqual(fresh.scene.pixels,pixels)
    XCTAssertEqual(fresh.width,641);XCTAssertEqual(fresh.height,853)
    let bitmap=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:images.imageURL(assetID:fresh.inputAssetID))))
    XCTAssertEqual(bitmap.pixelsWide,641);XCTAssertEqual(bitmap.pixelsHigh,853)
    XCTAssertEqual(images.prompt,prompt);XCTAssertEqual(images.style,style);XCTAssertEqual(images.references,references);XCTAssertEqual(images.options,expected)
    XCTAssertEqual(images.history.first{$0.id==previous.id},previous)
    XCTAssertEqual(try Data(contentsOf:images.imageURL(assetID:oldCapture.inputAssetID)),oldBytes)
    XCTAssertTrue(store.studioShowingImages);XCTAssertFalse(images.isCaptureStale)
    XCTAssertEqual(store.project,source);XCTAssertEqual(composition.draft,draft);XCTAssertEqual(composition.stage.camera,camera);XCTAssertEqual(store.engine.undoStack.count,undo)
  }

  func testEveryStudioEntryRefreshesOnlyInputAcrossSavedScenesAndUnchangedSceneReentry()async throws {
    let store=try fixture(),composition=store.studioComposition,images=store.studioImages
    composition.save();let first=try XCTUnwrap(composition.draft)
    var second=first;second.id=UUID();second.name="Portrait alternate view";second.pixels = .init(width:641,height:853)
    second.instances[0].id=UUID();second.instances[0].positionMM.x=35;second.instances[0].rotationDegrees=28
    _ = try store.engine.call("form_studio_scene",arguments:["command":"save","scene":try jsonObject(second)],source:"Test saved scene")
    store.metadataRecordsChanged();composition.load(first.id)
    XCTAssertEqual(composition.draft?.id,first.id)
    @MainActor func waitForInput(after id:UUID?)async throws->StudioGenerationCapture {
      for _ in 0..<400 {
        if let capture=images.capture,capture.id != id,capture.hasExactStudioPixels,!images.busy {return capture}
        try await Task.sleep(nanoseconds:10_000_000)
      }
      return try XCTUnwrap(nil as StudioGenerationCapture?,images.error ?? "No fresh Studio input arrived")
    }
    images.prompt="First saved view";store.createStudioStill()
    let oldCapture=try await waitForInput(after:nil)
    XCTAssertEqual(oldCapture.sceneID,first.id)
    await images.generate();let previous=try XCTUnwrap(images.currentRun),oldOutput=try XCTUnwrap(previous.outputAssetIDs.first)
    let inputBytes=try Data(contentsOf:images.imageURL(assetID:oldCapture.inputAssetID))
    let outputBytes=try Data(contentsOf:images.imageURL(assetID:oldOutput))
    let record=store.repository.root.appendingPathComponent("StudioAssets/GenerationRuns/"+previous.id.uuidString+".json"),recordBytes=try Data(contentsOf:record)
    images.prompt="Keep all of my next-image instructions";images.style="Keep this custom finish direction"
    images.options.model = .flare;images.options.quality = .draft;images.options.count=4
    images.references=[.init(assetID:oldCapture.inputAssetID,role:.composition),.init(assetID:oldOutput,role:.style)]
    let prompt=images.prompt,style=images.style,references=images.references
    var expected=images.options;expected.outputPixels=second.pixels
    store.studioShowingImages=false;composition.load(second.id)
    XCTAssertEqual(composition.draft?.id,second.id,"Switch using the same saved-scene controller path as thumbnails")
    let source=try XCTUnwrap(store.project),draft=composition.draft,camera=composition.stage.camera,undo=store.engine.undoStack.count
    store.createStudioStill();XCTAssertNil(images.capture,"Explicit entry clears the previous input before asynchronous capture")
    let fresh=try await waitForInput(after:oldCapture.id)
    XCTAssertNotEqual(fresh.sceneID,oldCapture.sceneID);XCTAssertEqual(fresh.sceneID,second.id)
    XCTAssertEqual(fresh.scene.pixels,second.pixels);XCTAssertEqual(fresh.width,641);XCTAssertEqual(fresh.height,853)
    let bitmap=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:images.imageURL(assetID:fresh.inputAssetID))))
    XCTAssertEqual(bitmap.pixelsWide,641);XCTAssertEqual(bitmap.pixelsHigh,853)
    XCTAssertEqual(images.prompt,prompt);XCTAssertEqual(images.style,style);XCTAssertEqual(images.references,references);XCTAssertEqual(images.options,expected)
    // Reenter without changing the scene: an old exact, nonstale input must
    // still be replaced, while the user's next-image form remains intact.
    store.studioShowingImages=false;store.createStudioStill();XCTAssertNil(images.capture)
    let repeated=try await waitForInput(after:fresh.id)
    XCTAssertNotEqual(repeated.id,fresh.id);XCTAssertEqual(repeated.sceneID,second.id);XCTAssertEqual(repeated.scene.pixels,second.pixels)
    XCTAssertEqual(images.prompt,prompt);XCTAssertEqual(images.style,style);XCTAssertEqual(images.references,references);XCTAssertEqual(images.options,expected)
    XCTAssertEqual(images.history.first{$0.id==previous.id},previous)
    XCTAssertEqual(try Data(contentsOf:images.imageURL(assetID:oldCapture.inputAssetID)),inputBytes)
    XCTAssertEqual(try Data(contentsOf:images.imageURL(assetID:oldOutput)),outputBytes);XCTAssertEqual(try Data(contentsOf:record),recordBytes)
    XCTAssertEqual(store.project,source);XCTAssertEqual(composition.draft,draft);XCTAssertEqual(composition.stage.camera,camera);XCTAssertEqual(store.engine.undoStack.count,undo)
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
