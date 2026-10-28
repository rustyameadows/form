import AppKit
import AVFoundation
import CryptoKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class EnvironmentUIWorkflowTests:XCTestCase {
  private func fixture(_ paper:Bool=false)throws->StudioStore {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("environment-ui-"+UUID().uuidString),repository=try ProjectRepository(root:root)
    var p=paper ? Samples.cyanotype():Project(name:"Multi-purpose function")
    if !paper {p.objects=[try p.makeObject(recipeID:"lamp"),try p.makeObject(recipeID:"box")]}
    p.camera.viewportAspect=1.5;try repository.save(p)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(p.id);store.showingHome=false;store.select(p.objects[0].id)
    addTeardownBlock{@MainActor in store.studioComposition.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)};return store
  }
  func testGuideRequiresExplicitProcessMaterialAndRejectsStaleOrDirtyStock()throws {
    let store=try fixture(true),g=store.fabricationGuide,original=store.project!;g.reconcile();XCTAssertFalse(g.materialConfirmed);g.step = .process;XCTAssertFalse(g.canContinue)
    g.choose(.paper);g.next();XCTAssertEqual(g.step,.material);XCTAssertFalse(g.canContinue);XCTAssertEqual(store.project,original)
    g.confirmMaterial();XCTAssertTrue(g.materialConfirmed);XCTAssertEqual(store.project!.objects[0].artwork,original.objects[0].artwork)
    let confirmed=store.project!;g.caliper="0.44";XCTAssertFalse(g.materialConfirmed);g.confirmMaterial();XCTAssertTrue(g.materialConfirmed);XCTAssertEqual(try PaperConstruction.definition(for:store.primary!).stock.thicknessMM,0.44)
    store.undo();g.reconcile();XCTAssertFalse(g.materialConfirmed);XCTAssertEqual(store.project,confirmed)
    g.reloadMaterial();g.stockName="My stock";store.update(store.primary!,["parameters":["stock":0.55]]);let changed=store.project!;g.confirmMaterial();XCTAssertNotNil(g.issue);XCTAssertEqual(store.project,changed)
  }
  func testLampAndFabricRoutesRemainSpecificWithoutClaimingPaperOrPrintForFabric()throws {
    let store=try fixture(),before=store.project!;store.showEnvironment(.function);XCTAssertEqual(store.project,before)
    let lamp=store.primary!;XCTAssertTrue(GuidedProcess.available(object:lamp,project:before).contains(.print3D));XCTAssertFalse(GuidedProcess.available(object:lamp,project:before).contains(.paper))
    let fabric=try PatternAssemblySamples.project();let assembly=try XCTUnwrap(fabric.objects.first{$0.patternAssembly != nil})
    XCTAssertTrue(FabricEnvironmentContext.applies(to:assembly,in:fabric));let routes=GuidedProcess.available(object:assembly,project:fabric);XCTAssertTrue(routes.contains(.pattern));XCTAssertTrue(routes.contains(.layout));XCTAssertFalse(routes.contains(.print3D))
    let paper=Samples.cyanotype();XCTAssertEqual(GuidedProcess.available(object:paper.objects[0],project:paper),[.paper])
  }
  func testPreparationSheetDimensionsRemainEditableWithoutLosingConfirmedStock()throws {
    let store=try fixture(true),g=store.fabricationGuide;g.reconcile();g.choose(.paper);g.confirmMaterial();g.step = .prepare;let before=store.project!
    g.sheetWidth="650";XCTAssertTrue(g.materialConfirmed);try g.applyLayout();XCTAssertEqual(store.paperSheetWidth,650);XCTAssertEqual(store.project,before)
    g.sheetWidth="701";XCTAssertThrowsError(try g.applyLayout());XCTAssertEqual(store.paperSheetWidth,650);XCTAssertEqual(store.project,before)
  }
  func testPrintMaterialNeedsExplicitFilamentAndPrinterAndPreservesDesign()throws {
    let store=try fixture(),g=store.fabricationGuide,before=store.project!;g.reconcile();g.choose(.print3D);g.confirmMaterial();XCTAssertFalse(g.materialConfirmed);XCTAssertEqual(store.project,before)
    g.printerID=store.library.printers[0].id;g.filamentID=store.library.filaments[0].id;g.confirmMaterial();XCTAssertTrue(g.materialConfirmed);XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.project!.camera,before.camera);XCTAssertFalse(store.showingPrint)
    XCTAssertEqual(store.project!.printSetups?[before.objects[0].id.uuidString]?.filamentID,g.filamentID)
    g.filamentID=store.library.filaments.last!.id;XCTAssertFalse(g.materialConfirmed)
  }
  func testStudioDraftUndoSaveAndPresentationCameraNeverMoveDesignObjects()throws {
    let store=try fixture(),c=store.studioComposition,before=store.project!;store.showEnvironment(.studio);c.reconcile()
    c.selectedInstanceID=c.draft!.instances[0].id;c.duplicateInstance();c.changeInstance{$0.positionMM = .init(100,35,60);$0.sourceObjectID=before.objects[1].id};c.addShelf()
    XCTAssertEqual(store.project,before);XCTAssertEqual(c.draft!.instances.count,4);XCTAssertTrue(c.undoDraft());XCTAssertEqual(c.draft!.instances.count,3);XCTAssertTrue(c.redoDraft())
    c.stage.camera.azimuth+=0.3;c.cameraEdited();XCTAssertEqual(store.project!.camera,before.camera)
    c.save();XCTAssertNil(c.error);XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.project!.camera,before.camera);XCTAssertEqual(store.project!.studioPresentation?.scenes?.count,1)
    store.undo();c.reconcile();XCTAssertNil(store.project!.studioPresentation);XCTAssertEqual(store.project,before)
  }
  func testDuplicateSceneClearsPreviousDraftHistoryAndUsesDocumentUndo()throws {
    let store=try fixture(),c=store.studioComposition;store.showEnvironment(.studio);c.reconcile();c.save()
    let original=try XCTUnwrap(c.draft);c.selectedInstanceID=original.instances[0].id;c.duplicateInstance();XCTAssertTrue(c.undoDraft());XCTAssertFalse(c.dirty);XCTAssertTrue(c.canRedoDraft)
    c.duplicateScene();XCTAssertNil(c.error);XCTAssertNotEqual(c.draft?.id,original.id);XCTAssertFalse(c.canUndoDraft);XCTAssertFalse(c.canRedoDraft);XCTAssertFalse(c.dirty)
    store.undo();c.reconcile();XCTAssertEqual(c.scenes.count,1);XCTAssertEqual(c.draft?.id,original.id)
  }
  func testStageClickAtScrubbedFrameDoesNotRebaseSavedCameraButDragDoes()throws {
    let store=try fixture(),c=store.studioComposition;c.reconcile();c.scrub(0.5);let before=c.draft
    let view=TableSceneView(frame:.init(x:0,y:0,width:900,height:600)),window=NSWindow(contentRect:view.frame,styleMask:[.borderless],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=view;view.controller=c.stage;c.stage.view=view
    defer{c.stage.view=nil;window.close()}
    view.onCameraInteraction={c.cameraEdited()}
    func event(_ type:NSEvent.EventType,_ p:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:view.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!}
    let start=NSPoint(x:300,y:300),end=NSPoint(x:400,y:300)
    view.mouseDown(with:event(.leftMouseDown,start));view.mouseUp(with:event(.leftMouseUp,start))
    XCTAssertEqual(c.draft,before);XCTAssertEqual(c.time,0.5)
    view.mouseDown(with:event(.leftMouseDown,start));view.mouseDragged(with:event(.leftMouseDragged,end));view.mouseUp(with:event(.leftMouseUp,end))
    XCTAssertNotEqual(c.draft?.camera,before?.camera);XCTAssertEqual(c.time,0);XCTAssertEqual(c.draft?.camera.elevation,before?.camera.elevation)
  }
  func testActualCameraVideoHasRealFramesDurationProvenanceAndExclusiveOutput()async throws {
    let store=try fixture(),c=store.studioComposition,before=store.project!;c.reconcile();var scene=c.draft!;scene.pixels = .init(width:320,height:240);scene.motion.seconds=0.5;scene.motion.fps=12;scene.motion.orbitDegrees=45
    let output=store.repository.root.appendingPathComponent("test.motion")
    // Exports cannot replace project/source storage, including arbitrary library children.
    await XCTAssertThrowsAsync{_ = try await c.export(scene,to:output,video:true)}
    let external=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".motion");defer{try? FileManager.default.removeItem(at:external)}
    let video=try await c.export(scene,to:external,video:true),asset=AVURLAsset(url:video),tracks=try await asset.loadTracks(withMediaType:.video)
    XCTAssertEqual(tracks.count,1);let duration=try await asset.load(.duration);XCTAssertEqual(CMTimeGetSeconds(duration),0.5,accuracy:0.01)
    let generator=AVAssetImageGenerator(asset:asset);generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    let first=try await generator.image(at:.zero).image,last=try await generator.image(at:CMTime(value:5,timescale:12)).image
    XCTAssertEqual(first.width,320);XCTAssertEqual(first.height,240);XCTAssertNotEqual(first.dataProvider?.data as Data?,last.dataProvider?.data as Data?)
    let record=try JSONSerialization.jsonObject(with:Data(contentsOf:external.appendingPathComponent("render.json"))) as! [String:Any]
    XCTAssertEqual(record["frames"] as? Int,6);XCTAssertEqual(record["mp4_sha256"] as? String,StudioRenderFolder.hash(try Data(contentsOf:video)));XCTAssertEqual(store.project,before)
    let bytes=try Data(contentsOf:video);await XCTAssertThrowsAsync{_ = try await c.export(scene,to:external,video:true)};XCTAssertEqual(try Data(contentsOf:video),bytes)
  }
  func testVideoSourceInvalidationAndCancellationLeaveNoPartialDelivery()async throws {
    let store=try fixture(),project=store.project!,assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    var scene=StudioComposition.fromProject(project);scene.pixels = .init(width:160,height:120);scene.motion.seconds=0.5;scene.motion.fps=12
    let parent=FileManager.default.temporaryDirectory.appendingPathComponent("cancel-video-"+UUID().uuidString);try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false);defer{try? FileManager.default.removeItem(at:parent)}
    var current=true
    await XCTAssertThrowsAsync{_ = try await StudioSceneMedia.export(project:project,scene:scene,assets:assets,renderer:StudioShotRenderer(),to:parent.appendingPathComponent("stale.motion"),video:true,isCurrent:{current},progress:{if $0>0 {current=false}})}
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty)
    let task=Task{_ = try await StudioSceneMedia.export(project:project,scene:scene,assets:assets,renderer:StudioShotRenderer(),to:parent.appendingPathComponent("cancelled.motion"),video:true,isCurrent:{true},progress:{_ in})};task.cancel()
    do{try await task.value;XCTFail("Cancelled export delivered output.")}catch{XCTAssertTrue(error is CancellationError)}
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty);XCTAssertEqual(store.project,project)
  }
  private func XCTAssertThrowsAsync(_ body:()async throws->Void)async {do{try await body();XCTFail("Expected a rejected output.")}catch{}}
}
