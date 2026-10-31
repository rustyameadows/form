import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class StudioImageGenerationTests:XCTestCase {
  @MainActor private final class PausedProvider:StudioImageGenerationProvider {
    var entered=false
    private var continuation:CheckedContinuation<Void,Never>?
    func generate(_ request:StudioGenerationRequest,progress:@escaping(Double)->Void)async throws->[Data] {
      entered=true;progress(0.2)
      await withCheckedContinuation{continuation=$0}
      try Task.checkCancellation()
      return try await LocalStudioImageGenerationProvider(delayNanoseconds:0).generate(request,progress:progress)
    }
    func release(){let value=continuation;continuation=nil;value?.resume()}
  }
  @MainActor private final class Fixture {
    let root:URL,store:StudioStore,library:StudioAssetLibrary,controller:StudioImageGenerationController
    init(provider:(any StudioImageGenerationProvider)?=nil)throws {
      _ = NSApplication.shared
      root=FileManager.default.temporaryDirectory.appendingPathComponent("studio-image-demo-"+UUID().uuidString)
      store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
      var project=Project(name:"Unsaved native composition")
      var object=try project.makeObject(recipeID:"box",parameters:["width":100,"height":90,"depth":70]);object.color="#A95131";project.objects=[object]
      store.engine.project=project;store.showingHome=false;store.studioComposition.reconcile()
      store.studioComposition.stage.fitAll()
      library=StudioAssetLibrary(root:root,projectID:project.id)
      controller=StudioImageGenerationController(store:store,library:library,provider:provider ?? LocalStudioImageGenerationProvider(delayNanoseconds:0),captureLimit:160)
      controller.prompt="A faithful product photograph for the local demo."
      controller.options.size = .small
    }
    func close(){controller.cancel();store.studioComposition.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
  }
  private func waitForProvider(_ value:PausedProvider)async throws {
    for _ in 0..<1000 {if value.entered{return};try await Task.sleep(nanoseconds:1_000_000)}
    XCTFail("Local provider was not reached")
  }
  func testNativeCaptureFreezesUnsavedInstancesAndEffectiveCameraWithoutSavingSource()async throws {
    let f=try Fixture();defer{f.close()};let c=f.store.studioComposition
    c.selectInstance(c.draft!.instances[0].id);c.changeInstance{$0.positionMM = .init(21,35,-15)}
    c.stage.camera.azimuth+=0.23;c.stage.updateCamera()
    let project=f.store.project!,draft=c.draft!,camera=c.stage.camera,undo=f.store.engine.undoStack.count
    await f.controller.captureScene()
    let capture=try XCTUnwrap(f.controller.capture),asset=try XCTUnwrap(f.library.asset(id:capture.inputAssetID))
    XCTAssertEqual(capture.scene.instances,draft.instances);XCTAssertEqual(capture.camera,camera);XCTAssertEqual(capture.scene.camera,camera)
    XCTAssertFalse(asset.isMock);XCTAssertEqual(asset.origin,.exported)
    XCTAssertNotNil(NSBitmapImageRep(data:try Data(contentsOf:f.library.fileURL(for:asset))))
    XCTAssertFalse(f.controller.isCaptureStale);XCTAssertEqual(c.draft,draft)
    XCTAssertEqual(f.store.project,project);XCTAssertEqual(f.store.engine.undoStack.count,undo)
    c.stage.orbit(dx:30,dy:0)
    XCTAssertTrue(f.controller.isCaptureStale);XCTAssertEqual(f.controller.capture,capture)
    await f.controller.generate();XCTAssertEqual(f.controller.currentRun?.status,.succeeded)
    XCTAssertEqual(f.controller.currentRun?.capture,capture);XCTAssertTrue(f.controller.isCaptureStale)
    XCTAssertEqual(f.store.project,project)
  }
  func testDemoResultsAreDeterministicBoundedClearlyProvenancedAndHistoryReopens()async throws {
    let f=try Fixture();defer{f.close()};let before=f.store.project!,undo=f.store.engine.undoStack.count
    await f.controller.captureScene();f.controller.options.count=2
    await f.controller.generate()
    let run=try XCTUnwrap(f.controller.currentRun)
    XCTAssertEqual(run.status,.succeeded);XCTAssertEqual(run.outputAssetIDs.count,2);XCTAssertTrue(run.isMock)
    let output=try run.outputAssetIDs.map{id -> StudioAsset in
      let asset=try XCTUnwrap(f.library.asset(id:id));XCTAssertTrue(asset.isMock);XCTAssertEqual(asset.origin,.generated)
      XCTAssertEqual(asset.metadata.generationID,run.id);XCTAssertEqual(asset.metadata.options?["transport"],"none")
      XCTAssertEqual(asset.metadata.options?["model"],StudioGenerationModel.sunburst.rawValue)
      let bitmap=try XCTUnwrap(NSBitmapImageRep(data:Data(contentsOf:f.library.fileURL(for:asset))))
      XCTAssertEqual(bitmap.pixelsWide,512);XCTAssertEqual(bitmap.pixelsHigh,341)
      return asset
    }
    let input=try Data(contentsOf:f.controller.imageURL(assetID:run.capture.inputAssetID))
    let request=StudioGenerationRequest(inputPNG:input,prompt:run.prompt,style:run.style,references:run.references,options:run.options)
    let repeated=try await LocalStudioImageGenerationProvider(delayNanoseconds:0).generate(request,progress:{_ in})
    for (asset,data) in zip(output,repeated) {XCTAssertEqual(try Data(contentsOf:f.library.fileURL(for:asset)),data)}
    let reopened=StudioImageGenerationController(store:f.store,library:f.library,provider:LocalStudioImageGenerationProvider(delayNanoseconds:0),captureLimit:160)
    XCTAssertEqual(reopened.history.first(where:{$0.id==run.id}),run)
    reopened.prompt="Next form B, already edited";reopened.style="Cool B direction";reopened.options.aspect = .portrait;reopened.options.count=4
    reopened.references=[.init(assetID:output[1].id,role:.subject)]
    await reopened.captureScene();let nextCapture=try XCTUnwrap(reopened.capture),nextOptions=reopened.options
    reopened.selectRun(run.id);reopened.iterate(resultAssetID:output[0].id)
    XCTAssertNil(reopened.currentRun);XCTAssertEqual(reopened.prompt,"Next form B, already edited");XCTAssertEqual(reopened.style,"Cool B direction")
    XCTAssertEqual(reopened.options,nextOptions);XCTAssertEqual(reopened.capture,nextCapture)
    XCTAssertEqual(reopened.references,[.init(assetID:output[1].id,role:.subject),.init(assetID:output[0].id,role:.style)])
    reopened.addReference(assetID:output[0].id,role:.composition);reopened.iterate(resultAssetID:output[0].id)
    XCTAssertEqual(reopened.references.last?.role,.composition,"Adding an existing reference must preserve its role")
    try reopened.saveStylePreset(name:"Warm editorial")
    let restored=StudioImageGenerationController(store:f.store,library:f.library)
    XCTAssertEqual(restored.stylePresets.first(where:{$0.name=="Warm editorial"})?.references,reopened.references)
    XCTAssertTrue(Set(StudioGenerationStylePreset.builtins.map(\.id)).isSubset(of:Set(restored.stylePresets.map(\.id))))
    XCTAssertEqual(f.store.project,before);XCTAssertEqual(f.store.engine.undoStack.count,undo)
  }
  func testFrozenProviderJobSurvivesSameProjectSceneEditsButCannotPublishAfterProjectReset()async throws {
    let provider=PausedProvider(),f=try Fixture(provider:provider);defer{provider.release();f.close()}
    await f.controller.captureScene();let captured=try XCTUnwrap(f.controller.capture),prompt=f.controller.prompt
    let work=Task{await f.controller.generate()};try await waitForProvider(provider)
    f.controller.prompt="Next request only";f.controller.options.count=4
    f.store.studioComposition.selectInstance(f.store.studioComposition.draft!.instances[0].id)
    f.store.studioComposition.changeInstance{$0.positionMM.x+=30}
    XCTAssertTrue(f.controller.isCaptureStale)
    provider.release();await work.value
    let completed=try XCTUnwrap(f.controller.currentRun)
    XCTAssertEqual(completed.status,.succeeded);XCTAssertEqual(completed.outputAssetIDs.count,1)
    XCTAssertEqual(completed.capture,captured);XCTAssertEqual(completed.prompt,prompt);XCTAssertEqual(completed.options.count,1)
    await f.controller.captureScene();provider.entered=false
    let again=Task{await f.controller.generate()};try await waitForProvider(provider)
    let existing=f.library.items.filter{$0.origin == .generated}.count
    f.store.engine.project=Project(name:"Another project");let next=f.store.project!
    f.controller.resetForProjectChange();provider.release();await again.value
    XCTAssertNil(f.controller.capture);XCTAssertNil(f.controller.currentRun);XCTAssertFalse(f.controller.busy)
    XCTAssertEqual(f.library.items.filter{$0.origin == .generated}.count,existing)
    XCTAssertTrue(f.controller.history.isEmpty);XCTAssertEqual(f.store.project,next)
    let records=try FileManager.default.contentsOfDirectory(at:f.root.appendingPathComponent("StudioAssets/GenerationRuns"),includingPropertiesForKeys:nil)
    let saved=records.compactMap{try? JSONDecoder.form.decode(StudioGenerationRun.self,from:Data(contentsOf:$0))}
    XCTAssertEqual(saved.filter{$0.status == .cancelled && $0.capture.projectID==captured.projectID}.count,1)
  }
  func testFailureFixturesRetryAndExplicitCancelPreserveSourceAndNoPartialResults()async throws {
    let f=try Fixture();defer{f.close()};let before=f.store.project!
    await f.controller.captureScene()
    for fixture in StudioGenerationFailureFixture.allCases where fixture != .none {
      f.controller.options.failureFixture=fixture;await f.controller.generate()
      XCTAssertEqual(f.controller.currentRun?.status,.failed);XCTAssertEqual(f.controller.currentRun?.error,fixture.message)
      XCTAssertTrue(f.controller.currentRun?.outputAssetIDs.isEmpty==true)
    }
    f.controller.options.failureFixture = .none;await f.controller.retry()
    XCTAssertEqual(f.controller.currentRun?.status,.succeeded)
    let paused=PausedProvider(),c=StudioImageGenerationController(store:f.store,library:f.library,provider:paused,captureLimit:160)
    c.prompt="Local cancellation fixture";await c.captureScene()
    let count=f.library.items.filter{$0.origin == .generated}.count
    let work=Task{await c.generate()};try await waitForProvider(paused)
    c.cancel();paused.release();await work.value
    XCTAssertEqual(c.currentRun?.status,.cancelled);XCTAssertFalse(c.busy)
    XCTAssertEqual(f.library.items.filter{$0.origin == .generated}.count,count);XCTAssertEqual(f.store.project,before)
  }
  func testConnectionIsLocalPreviewOnlyAndInvalidRequestsOrPersistenceDoNotWriteProjects()async throws {
    let f=try Fixture();defer{f.close()};let before=f.store.project!,connection=f.controller.connection
    connection.useDemoConnection();XCTAssertEqual(connection.state,.demoReady)
    connection.fixture = .authentication;await connection.testPreview();XCTAssertEqual(connection.state,.authenticationFailed)
    connection.reset();XCTAssertEqual(connection.state,.disconnected)
    await f.controller.captureScene();f.controller.options.count=3;await f.controller.generate()
    XCTAssertTrue(f.controller.history.isEmpty);XCTAssertFalse(f.controller.busy)
    f.controller.options.count=1
    let path=f.root.appendingPathComponent("StudioAssets/GenerationRuns")
    try Data("not a directory".utf8).write(to:path)
    await f.controller.generate();XCTAssertTrue(f.controller.history.isEmpty);XCTAssertNotNil(f.controller.error)
    let metadata=try JSONEncoder.form.encode(f.controller.options),text=String(decoding:metadata,as:UTF8.self).lowercased()
    XCTAssertFalse(text.contains("apikey"));XCTAssertFalse(text.contains("credential"));XCTAssertFalse(text.contains("password"))
    XCTAssertEqual(f.store.project,before);XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testInitialCaptureRejectsUnpersistedClothRuntimeWithoutResetOrAssets()async throws {
    let f=try Fixture();defer{f.store.cloth.clear();f.close()}
    var project=f.store.project!,cloth=try project.makeObject(recipeID:"clothPanel",parameters:["resolution":6])
    cloth.cloth!.settings.frameStepSeconds=1/60;project.objects.append(cloth);f.store.engine.project=project
    f.store.studioComposition.reconcile();f.store.studioComposition.add(cloth)
    try f.store.cloth.activate(cloth.id);try f.store.cloth.preview.stepImmediately(frames:1)
    let source=f.store.project!,runtime=try XCTUnwrap(f.store.cloth.preview.frame),draft=f.store.studioComposition.draft
    await f.controller.captureScene()
    XCTAssertNil(f.controller.capture);XCTAssertTrue(f.controller.history.isEmpty);XCTAssertTrue(f.library.items.isEmpty)
    XCTAssertTrue(f.controller.error?.contains("unpersisted cloth") == true)
    XCTAssertEqual(f.store.cloth.preview.frame,runtime);XCTAssertEqual(f.store.project,source);XCTAssertEqual(f.store.studioComposition.draft,draft)
    XCTAssertTrue(f.store.engine.undoStack.isEmpty)
  }
  func testTerminalHistoryWriteFailureKeepsResultLinksAndRecoversExactDurableBatch()async throws {
    let provider=PausedProvider(),f=try Fixture(provider:provider);defer{provider.release();f.close()}
    await f.controller.captureScene();f.controller.options.count=2
    let source=f.store.project!,work=Task{await f.controller.generate()}
    try await waitForProvider(provider)
    let started=try XCTUnwrap(f.controller.currentRun),path=f.root.appendingPathComponent("StudioAssets/GenerationRuns/\(started.id.uuidString).json")
    let original=try Data(contentsOf:path),backup=path.appendingPathExtension("original")
    try FileManager.default.moveItem(at:path,to:backup);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
    provider.release();await work.value
    let completed=try XCTUnwrap(f.controller.currentRun)
    XCTAssertEqual(completed.status,.succeeded);XCTAssertEqual(completed.outputAssetIDs.count,2);XCTAssertFalse(f.controller.busy)
    XCTAssertTrue(f.controller.error?.contains("history") == true)
    for id in completed.outputAssetIDs {XCTAssertNotNil(f.library.asset(id:id));XCTAssertNoThrow(try f.controller.imageURL(assetID:id))}
    // Restore the exact prior atomic-file contents, as retained by a failed
    // terminal overwrite; the Library's committed batch is the recovery proof.
    try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:backup,to:path)
    XCTAssertEqual(try Data(contentsOf:path),original)
    let durableLibrary=StudioAssetLibrary(root:f.root,projectID:f.store.project!.id)
    let reopened=StudioImageGenerationController(store:f.store,library:durableLibrary)
    let recovered=try XCTUnwrap(reopened.history.first{$0.id==started.id})
    XCTAssertEqual(recovered.status,.succeeded);XCTAssertEqual(recovered.outputAssetIDs,completed.outputAssetIDs)
    XCTAssertEqual(recovered.capture,completed.capture);XCTAssertEqual(f.store.project,source)
  }
  func testCancellationHistoryWriteFailureStaysTerminalAndResetClearsOldError()async throws {
    let provider=PausedProvider(),f=try Fixture(provider:provider);defer{provider.release();f.close()}
    await f.controller.captureScene()
    let source=f.store.project!,work=Task{await f.controller.generate()};try await waitForProvider(provider)
    let run=try XCTUnwrap(f.controller.currentRun),path=f.root.appendingPathComponent("StudioAssets/GenerationRuns/\(run.id.uuidString).json"),backup=path.appendingPathExtension("original")
    try FileManager.default.moveItem(at:path,to:backup);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
    f.controller.cancel();provider.release();await work.value
    XCTAssertEqual(f.controller.currentRun?.status,.cancelled);XCTAssertFalse(f.controller.busy)
    XCTAssertTrue(f.controller.error?.contains("history") == true);XCTAssertTrue(f.library.items.filter{$0.origin == .generated}.isEmpty)
    try FileManager.default.removeItem(at:path);try FileManager.default.moveItem(at:backup,to:path)
    let durableLibrary=StudioAssetLibrary(root:f.root,projectID:f.store.project!.id)
    let reopened=StudioImageGenerationController(store:f.store,library:durableLibrary)
    XCTAssertEqual(reopened.history.first(where:{$0.id==run.id})?.status,.cancelled)
    f.controller.resetForProjectChange();XCTAssertNil(f.controller.error);XCTAssertNil(f.controller.capture);XCTAssertNil(f.controller.currentRun)
    XCTAssertEqual(f.store.project,source)
  }
  func testSharedRootHistoryAndOutputActionsStayScopedAndNeverRewriteForeignRuns()async throws {
    let f=try Fixture();defer{f.close()};let projectA=f.store.project!
    await f.controller.captureScene();await f.controller.generate()
    let runA=try XCTUnwrap(f.controller.currentRun),outputA=try XCTUnwrap(runA.outputAssetIDs.first)
    let outputBytes=try Data(contentsOf:f.controller.imageURL(assetID:outputA))
    var projectB=Project(name:"Private B");projectB.objects=[try projectB.makeObject(recipeID:"box")]
    f.store.engine.project=projectB;f.store.studioComposition.reconcile();f.controller.reconcile()
    XCTAssertTrue(f.controller.history.isEmpty);XCTAssertNil(f.controller.currentRun);XCTAssertNil(f.controller.capture)
    XCTAssertThrowsError(try f.controller.imageURL(assetID:outputA),"An inactive cached controller must not expose its old project")
    let libraryB=StudioAssetLibrary(root:f.root,projectID:projectB.id)
    let controllerB=StudioImageGenerationController(store:f.store,library:libraryB,provider:LocalStudioImageGenerationProvider(delayNanoseconds:0),captureLimit:160)
    controllerB.prompt="B local study";controllerB.options.size = .small
    await controllerB.captureScene();await controllerB.generate()
    let runB=try XCTUnwrap(controllerB.currentRun)
    XCTAssertTrue(controllerB.history.allSatisfy{$0.capture.projectID==projectB.id})
    controllerB.selectRun(runA.id);XCTAssertEqual(controllerB.currentRun?.id,runB.id)
    XCTAssertThrowsError(try controllerB.imageURL(assetID:outputA))
    controllerB.addReference(assetID:outputA);XCTAssertTrue(controllerB.references.isEmpty)
    controllerB.iterate(resultAssetID:outputA);XCTAssertEqual(controllerB.currentRun?.id,runB.id)
    let count=controllerB.history.count
    controllerB.references=[.init(assetID:outputA,role:.style)]
    await controllerB.generate();XCTAssertEqual(controllerB.history.count,count)
    XCTAssertThrowsError(try controllerB.saveStylePreset(name:"Foreign references"))
    // Many newer B records must not consume A's128-history allowance. Reading
    // A must also leave B's interrupted records byte-for-byte untouched.
    let directory=f.root.appendingPathComponent("StudioAssets/GenerationRuns")
    var foreign=runB;foreign.status = .running;foreign.outputAssetIDs=[]
    var originals=[URL:Data]()
    for _ in 0..<129 {foreign.id=UUID();let data=try JSONEncoder.form.encode(foreign),url=directory.appendingPathComponent(foreign.id.uuidString+".json");try data.write(to:url);originals[url]=data}
    f.store.engine.project=projectA;f.store.studioComposition.reconcile();f.controller.reconcile();controllerB.reconcile()
    XCTAssertTrue(controllerB.history.isEmpty)
    XCTAssertEqual(f.controller.history.map(\.id),[runA.id])
    for (url,data) in originals {XCTAssertEqual(try Data(contentsOf:url),data)}
    XCTAssertEqual(try Data(contentsOf:f.controller.imageURL(assetID:outputA)),outputBytes)
    XCTAssertEqual(f.store.project,projectA)
  }
  func testProjectStylesAdoptOnlyOwnedLegacyReferencesAndPreserveGlobalBytes()async throws {
    let f=try Fixture();defer{f.close()};let projectA=f.store.project!
    await f.controller.captureScene();await f.controller.generate()
    let assetA=try XCTUnwrap(f.controller.currentRun?.outputAssetIDs.first),png=try Data(contentsOf:f.controller.imageURL(assetID:assetA))
    let projectB=Project(name:"Style owner B"),libraryB=StudioAssetLibrary(root:f.root,projectID:projectB.id)
    let assetB=try libraryB.register(data:png,filename:"b.png",metadata:.init(kind:.image,origin:.uploaded,projectID:projectB.id))
    let legacyA=StudioGenerationStylePreset(id:UUID(),name:"Legacy A",instructions:"A owned style",references:[.init(assetID:assetA,role:.style)])
    let legacyB=StudioGenerationStylePreset(id:UUID(),name:"Legacy B",instructions:"B private style",references:[.init(assetID:assetB.id,role:.style)])
    let unassigned=StudioGenerationStylePreset(id:UUID(),name:"Unassigned",instructions:"Ownership is unknown",references:[])
    let legacyURL=f.root.appendingPathComponent("StudioAssets/GenerationStyles.json"),legacyBytes=try JSONEncoder.form.encode([legacyA,legacyB,unassigned])
    try legacyBytes.write(to:legacyURL)
    let restoredA=StudioImageGenerationController(store:f.store,library:f.library)
    XCTAssertTrue(restoredA.stylePresets.contains{$0.id==legacyA.id})
    XCTAssertFalse(restoredA.stylePresets.contains{$0.id==legacyB.id || $0.id==unassigned.id})
    restoredA.applyStylePreset(legacyA);XCTAssertEqual(restoredA.references,legacyA.references)
    restoredA.applyStylePreset(legacyB);XCTAssertEqual(restoredA.references,legacyA.references)
    try restoredA.saveStylePreset(name:"A private saved")
    let aFile=f.root.appendingPathComponent("StudioAssets/GenerationStyles/\(projectA.id.uuidString).json"),aBytes=try Data(contentsOf:aFile)
    f.store.engine.project=projectB;f.store.studioComposition.reconcile()
    let restoredB=StudioImageGenerationController(store:f.store,library:libraryB)
    XCTAssertTrue(restoredB.stylePresets.contains{$0.id==legacyB.id})
    XCTAssertFalse(restoredB.stylePresets.contains{$0.id==legacyA.id || $0.id==unassigned.id})
    restoredB.applyStylePreset(legacyB);try restoredB.saveStylePreset(name:"B private saved")
    restoredB.references=[.init(assetID:assetA,role:.subject)]
    XCTAssertThrowsError(try restoredB.saveStylePreset(name:"Must not cross scopes"))
    XCTAssertEqual(try Data(contentsOf:legacyURL),legacyBytes);XCTAssertEqual(try Data(contentsOf:aFile),aBytes)
    XCTAssertEqual(f.store.project,projectB)
    f.store.engine.project=projectA;restoredA.reconcile()
    XCTAssertTrue(restoredA.stylePresets.contains{$0.name=="A private saved"});XCTAssertFalse(restoredA.stylePresets.contains{$0.id==legacyB.id})
  }
}
