import AppKit
import XCTest
import FormCore
import FormGeometry
@testable import FormApp

@MainActor final class SolidModelCoordinatorTests:XCTestCase {
  private actor Gate {
    struct Call:Sendable {let height:Double,width:Double,preview:Bool,onMain:Bool;let cancellation:OrganicMeshCancellation}
    private var calls:[Call]=[]
    private var continuations:[String:CheckedContinuation<SolidSurface,Error>]=[:]
    private func key(_ height:Double,_ preview:Bool,_ width:Double)->String {"\(height)/\(preview)/\(width)"}
    func build(_ values:[String:Double],preview:Bool,cancellation:OrganicMeshCancellation,onMain:Bool)async throws->SolidSurface {
      let height=values["height"]!,width=values["width"] ?? 12;calls.append(.init(height:height,width:width,preview:preview,onMain:onMain,cancellation:cancellation))
      // Deliberately ignore Task cancellation: ownership checks must reject a
      // late result even from a worker which cannot cooperate immediately.
      return try await withCheckedThrowingContinuation{continuations[key(height,preview,width)]=$0}
    }
    func has(_ height:Double,_ preview:Bool,width:Double=12)->Bool {continuations[key(height,preview,width)] != nil}
    func complete(_ height:Double,_ preview:Bool,width:Double=12,failing:Bool=false) {
      guard let continuation=continuations.removeValue(forKey:key(height,preview,width)) else{return}
      if failing {continuation.resume(throwing:FormError.invalid("Controlled invalid full source"))}
      else {continuation.resume(returning:Self.surface(height,preview))}
    }
    func finishAll() {for continuation in continuations.values {continuation.resume(throwing:CancellationError())};continuations=[:]}
    func records()->[Call] {calls}
    nonisolated static func surface(_ height:Double,_ preview:Bool)->SolidSurface {
      let p:[SIMD3<Double>]=[.init(0,0,0),.init(1,0,0),.init(0,height,0)]
      return .init(positions:p,indices:[0,1,2],normals:Array(repeating:.init(0,0,1),count:3),displayChunks:[.init(positions:p.flatMap{[$0.x/100,$0.y/100,$0.z/100]},normals:[0,0,1,0,0,1,0,0,1],indices:[0,1,2])],isEditingPreview:preview)
    }
  }
  private func definition()->ParametricSolid {
    .init(normalizeHeight:"height",nodes:[.init(kind:"sweep",sweep:.init(samples:"24",variable:"u",values:["x":"sin(pi*u)","y":"height*u","z":"0","radiusX":"3","radiusY":"1"],sides:24))],previewNodes:[.init(kind:"sweep",sweep:.init(samples:"4",variable:"u",values:["x":"sin(pi*u)","y":"height*u","z":"0","radiusX":"3","radiusY":"1"],sides:6))])
  }
  private func fixture(gate:Gate?=nil,height:Double=10,noPreview:Bool=false,maximumBytes:Int=256*1024*1024)throws->(StudioStore,ProductObject) {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("solid-loop-"+UUID().uuidString),repository=try ProjectRepository(root:folder)
    var project=Project(name:"Generic asynchronous solid")
    var source=definition()
    source.normalizeHeight="height+0*\(Int.random(in:1...1_000_000_000))"
    source.nodes[0].sweep?.values["radiusX"]="width/4"
    source.previewNodes?[0].sweep?.values["radiusX"]="width/4"
    if noPreview {source.previewNodes=nil}
    let recipe=Recipe("solid-"+UUID().uuidString,"Authored solid","cube","",[.init("height","Height",height,1...100),.init("width","Width",12,1...100)],solid:source)
    project.recipes=[recipe];let object=try project.makeObject(recipeID:recipe.id);project.objects=[object]
    try repository.save(project)
    let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id)
    if let gate {store.solids=SolidModelCoordinator(store:store,builder:{_,values,preview,cancellation in
      let onMain=Thread.isMainThread
      return try await gate.build(values,preview:preview,cancellation:cancellation,onMain:onMain)
    },maximumBytes:maximumBytes)}
    addTeardownBlock{try? FileManager.default.removeItem(at:folder)}
    return (store,object)
  }
  private func eventually(_ predicate:@MainActor ()async->Bool)async throws {
    for _ in 0..<2000 {if await predicate(){return};try await Task.sleep(nanoseconds:2_000_000)}
    XCTFail("Solid worker did not reach the expected checkpoint");throw FormError.invalid("Solid worker timeout")
  }
  private func prime(_ store:StudioStore,_ object:ProductObject,_ gate:Gate)async throws {
    store.solids.synchronize(store.project)
    try await eventually{await gate.has(object["height"],false)}
    await gate.complete(object["height"],false)
    try await eventually{store.solids.completedBuilds==1}
  }
  func testHeldDraftUsesPreviewLatestWinsAndPublishesOnlyFullReleaseWithOneUndo()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let token=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":20]);try await eventually{await gate.has(20,true)}
    store.solids.set(object,parameters:["height":30]);try await eventually{await gate.has(30,true)}
    await gate.complete(30,true)
    try await eventually{store.solids.display(for:object,project:before)?.parameters["height"]==30}
    XCTAssertTrue(try XCTUnwrap(store.solids.display(for:object,project:before)).surface.isEditingPreview)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    await gate.complete(20,true)
    try await eventually{store.solids.discardedBuilds>0}
    XCTAssertEqual(store.solids.display(for:object,project:before)?.parameters["height"],30)
    store.solids.endGesture(token);try await eventually{await gate.has(30,false)}
    XCTAssertEqual(store.project,before,"Releasing a draft must wait for a valid full mesh")
    await gate.complete(30,false)
    try await eventually{store.project?.objects.first?["height"]==30}
    XCTAssertFalse(try XCTUnwrap(store.solids.display(for:store.project!.objects[0],project:store.project!)).surface.isEditingPreview)
    XCTAssertEqual(store.engine.undoStack.count,undo+1);XCTAssertEqual(store.solids.maximumActiveBuilds,2)
    let records=await gate.records();XCTAssertTrue(records.allSatisfy{!$0.onMain});XCTAssertTrue(try XCTUnwrap(records.first{$0.height==20}).cancellation.isCancelled)
    store.undo();XCTAssertEqual(store.project?.objects,before.objects)
    store.redo();XCTAssertEqual(store.project?.objects.first?["height"],30)
  }
  func testInvalidNativeFullKeepsAcceptedSourceUndoAndLastValidDisplay()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let before=store.project,undo=store.engine.undoStack.count
    let token=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":40]);try await eventually{await gate.has(40,true)}
    await gate.complete(40,true);try await eventually{store.solids.completedBuilds==2}
    store.solids.endGesture(token);try await eventually{await gate.has(40,false)}
    await gate.complete(40,false,failing:true)
    try await eventually{store.solids.issue(for:object.id) != nil}
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo);XCTAssertFalse(store.solids.hasDraft(object.id))
    let display=try XCTUnwrap(store.solids.display(for:object,project:try XCTUnwrap(before)))
    XCTAssertEqual(display.parameters["height"],10);XCTAssertFalse(display.surface.isEditingPreview)
  }
  func testAgentUsesSameSourceRetainsLastValidAndProjectSwitchDiscardsLateResult()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    _ = try store.engine.call("form_update_object",arguments:["object_id":object.id.uuidString,"parameters":["height":55]])
    store.changed();try await eventually{await gate.has(55,false)}
    XCTAssertEqual(store.project?.objects.first?["height"],55)
    XCTAssertEqual(store.solids.display(for:store.project!.objects[0],project:store.project!)?.parameters["height"],10)
    let other=Project(name:"Other document");try store.repository.save(other);try store.engine.open(other.id)
    await gate.complete(55,false)
    try await eventually{store.solids.activeBuilds==0}
    XCTAssertEqual(store.project?.id,other.id);XCTAssertTrue(store.project!.objects.isEmpty);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testNativeEscapeCancelsTransientSliderWithoutPublishing()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let before=store.project,slider=InspectorNativeSlider()
    slider.minValue=1;slider.maxValue=100;slider.doubleValue=10
    var token:UUID?
    slider.editingChanged={editing in if editing {token=store.solids.beginGesture(object)}else if let token {store.solids.endGesture(token)}}
    slider.editingCancelled={store.solids.cancelDraft(object.id)}
    slider.beginEditing();store.solids.set(object,parameters:["height":70]);try await eventually{await gate.has(70,true)}
    let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53))
    slider.keyDown(with:event);slider.endEditing()
    await gate.complete(70,true);try await eventually{store.solids.activeBuilds==0}
    XCTAssertFalse(slider.editing);XCTAssertFalse(store.solids.hasDraft(object.id));XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertEqual(store.solids.value(for:object,parameter:"height"),10)
  }
  func testSecondSliderStartsFromReleasedIntentAndEscapeRestoresItsPendingPublication()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let before=store.project
    let a=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":20]);try await eventually{await gate.has(20,true)}
    await gate.complete(20,true);try await eventually{store.solids.completedBuilds==2}
    store.solids.endGesture(a);try await eventually{await gate.has(20,false)}
    let b=try XCTUnwrap(store.solids.beginGesture(object))
    XCTAssertEqual(store.solids.value(for:object,parameter:"height"),20)
    store.solids.set(object,parameters:["width":24]);try await eventually{await gate.has(20,true,width:24)}
    await gate.complete(20,true,width:24);try await eventually{store.solids.completedBuilds==3}
    await gate.complete(20,false);try await eventually{store.solids.discardedBuilds>0}
    XCTAssertEqual(store.project,before,"A superseded full worker must not interrupt the newer held control")
    store.solids.cancelDraft(object.id);store.solids.endGesture(b)
    XCTAssertEqual(store.solids.value(for:object,parameter:"height"),20);XCTAssertEqual(store.solids.value(for:object,parameter:"width"),12)
    try await eventually{await gate.has(20,false)}
    await gate.complete(20,false)
    try await eventually{store.project?.objects.first?["height"]==20}
    XCTAssertEqual(store.project?.objects.first?["width"],12);XCTAssertEqual(store.engine.undoStack.count,1)
    store.undo();XCTAssertEqual(store.project?.objects,before?.objects)
  }
  func testTwoReleasedControlsCommitAccumulatedIntentInOrderWithTwoUndoSteps()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let a=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":20]);try await eventually{await gate.has(20,true)}
    await gate.complete(20,true);try await eventually{store.solids.completedBuilds==2}
    store.solids.endGesture(a);try await eventually{await gate.has(20,false)}
    let b=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["width":24]);try await eventually{await gate.has(20,true,width:24)}
    await gate.complete(20,true,width:24);try await eventually{store.solids.completedBuilds==3}
    await gate.complete(20,false);try await eventually{store.solids.discardedBuilds>0}
    store.solids.endGesture(b);try await eventually{await gate.has(20,false)}
    await gate.complete(20,false)
    try await eventually{store.project?.objects.first?["height"]==20}
    XCTAssertEqual(store.project?.objects.first?["width"],12);XCTAssertEqual(store.engine.undoStack.count,1)
    try await eventually{await gate.has(20,false,width:24)}
    await gate.complete(20,false,width:24)
    try await eventually{store.project?.objects.first?["width"]==24}
    XCTAssertEqual(store.project?.objects.first?["height"],20);XCTAssertEqual(store.engine.undoStack.count,2)
    store.undo();XCTAssertEqual(store.project?.objects.first?["height"],20);XCTAssertEqual(store.project?.objects.first?["width"],12)
    store.undo();XCTAssertEqual(store.project?.objects.first?["height"],10)
  }
  func testSolidWithoutPreviewKeepsHeldFullTransientEscapeAndReleaseReuseIt()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate,noPreview:true)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let before=store.project
    let a=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":25]);try await eventually{await gate.has(25,false)}
    await gate.complete(25,false);try await eventually{store.solids.completedBuilds==2}
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.solids.display(for:object,project:store.project!)?.parameters["height"],25)
    store.solids.cancelDraft(object.id);store.solids.endGesture(a)
    XCTAssertEqual(store.solids.display(for:object,project:store.project!)?.parameters["height"],10);XCTAssertEqual(store.project,before)
    let b=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":25]);try await eventually{store.solids.display(for:object,project:store.project!)?.parameters["height"]==25}
    XCTAssertEqual(store.project,before)
    store.solids.endGesture(b);try await eventually{store.project?.objects.first?["height"]==25}
    XCTAssertEqual(store.engine.undoStack.count,1)
    let records=await gate.records();XCTAssertEqual(records.filter{$0.height==25}.count,1,"The validated full source can be reused without another CPU build")
  }
  func testRetainedFullAndPreviewBudgetRejectsPreviewButAllowsAuthoritativeRelease()async throws {
    let bytes=Gate.surface(10,false).byteCount
    let gate=Gate(),(store,object)=try fixture(gate:gate,maximumBytes:bytes+bytes/2)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    let token=try XCTUnwrap(store.solids.beginGesture(object))
    store.solids.set(object,parameters:["height":35]);try await eventually{await gate.has(35,true)}
    await gate.complete(35,true);try await eventually{store.solids.issue(for:object.id) != nil}
    XCTAssertLessThanOrEqual(store.solids.retainedBytes,bytes+bytes/2);XCTAssertEqual(store.project?.objects.first?["height"],10)
    XCTAssertEqual(store.solids.display(for:object,project:store.project!)?.parameters["height"],10)
    store.solids.endGesture(token);try await eventually{await gate.has(35,false)}
    await gate.complete(35,false);try await eventually{store.project?.objects.first?["height"]==35}
    XCTAssertLessThanOrEqual(store.solids.retainedBytes,bytes+bytes/2);XCTAssertEqual(store.engine.undoStack.count,1)
  }
  func testUndoRedoReusesAuthoritativeCacheThroughOwnershipGuards()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    try await prime(store,object,gate)
    store.solids.set(object,parameters:["height":27]);try await eventually{await gate.has(27,false)}
    await gate.complete(27,false);try await eventually{store.project?.objects.first?["height"]==27}
    store.undo();try await eventually{store.solids.display(for:store.project!.objects[0],project:store.project!)?.parameters["height"]==10}
    store.redo();try await eventually{store.solids.display(for:store.project!.objects[0],project:store.project!)?.parameters["height"]==27}
    let records=await gate.records();XCTAssertEqual(records.count,2)
  }
  func testRepeatedInstancesShareOneFullBufferUnderAggregateCaptureBudget()async throws {
    let (store,object)=try fixture(height:39.0625)
    defer{store.solids.reset()}
    var project=try XCTUnwrap(store.project),copy=object;copy.id=UUID();project.objects.append(copy)
    let one=try await SolidRecipeGeometry.prepareFullSources(project:project,objectIDs:[object.id]),surface=try XCTUnwrap(one[object.id])
    let all=try await SolidRecipeGeometry.prepareFullSources(project:project,maximumRetainedBytes:surface.byteCount+surface.byteCount/2)
    XCTAssertEqual(all.count,2);XCTAssertEqual(all[object.id]?.storageID,all[copy.id]?.storageID)
  }
  func testNativeSolidInspectAndSTLUseFullSourceAndLeaveDocumentUntouched()async throws {
    let (store,object)=try fixture(height:46.09375)
    defer{store.solids.reset()}
    let before=store.project,path=store.repository.url(for:store.project!.id).appendingPathComponent("full-source.stl")
    let inspection=try await store.solidModelCallAsync(["object_id":object.id.uuidString,"command":"inspect"])
    let result=try XCTUnwrap(inspection as? [String:Any])
    XCTAssertEqual(result["source_quality"] as? String,"full");XCTAssertGreaterThan(try XCTUnwrap(result["triangles"] as? Int),100)
    let export=try await store.solidModelCallAsync(["object_id":object.id.uuidString,"command":"export_stl","path":path.path])
    let exported=try XCTUnwrap(export as? [String:Any])
    let bytes=try Data(contentsOf:path),triangles=try XCTUnwrap(exported["triangles"] as? Int)
    XCTAssertEqual(bytes.count,84+50*triangles);XCTAssertEqual(exported["path"] as? String,path.path)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertThrowsError(try store.engine.call("form_batch",arguments:["operations":[["name":"form_solid","arguments":["object_id":object.id.uuidString,"command":"inspect"]]]]))
  }
  func testColdTableSyncDefersConstructionAndPreservesCameraWhenWorkerFinishes()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate,height:43.3125)
    defer{store.solids.reset();store.scene=nil;Task{await gate.finishAll()}}
    let project=try XCTUnwrap(store.project),definition=try XCTUnwrap(project.recipe(object.recipeID)?.solid)
    XCTAssertNil(try SolidRecipeGeometry.cachedSurface(definition,parameters:object.parameters))
    let table=TableSceneController(store:store);store.scene=table
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    table.sync(project,selection:[],isolated:[],showGrid:false,studio:false,preset:"daylight",assets:assets)
    XCTAssertNil(try SolidRecipeGeometry.cachedSurface(definition,parameters:object.parameters),"The first native sync must never cold-build a solid on the main thread")
    XCTAssertTrue(table.objectRoot.childNodes.first?.childNodes.isEmpty == true)
    table.camera.azimuth=32.75;let camera=table.camera
    try await eventually{await gate.has(43.3125,false)}
    var heartbeat=false;Task{@MainActor in heartbeat=true};try await eventually{heartbeat}
    await gate.complete(43.3125,false)
    try await eventually{store.solids.completedBuilds==1}
    XCTAssertEqual(table.camera,camera)
    XCTAssertFalse(table.objectRoot.childNodes.first?.childNodes.isEmpty ?? true)
  }
  func testAgentEditMarksColdLinkedVectorPendingThenFullCompletionRefreshesWithoutExtraUndo()async throws {
    let gate=Gate(),(store,object)=try fixture(gate:gate,height:37.03125)
    defer{store.solids.reset();Task{await gate.finishAll()}}
    // Use an actual baseline mesh/path; only the delayed replacement is fake.
    var project=try XCTUnwrap(store.project)
    let initial=try await SolidRecipeGeometry.prepareFullSources(project:project,objectIDs:[object.id])
    var view=try ObjectViewProjection.make(object:object,project:project,assets:FileManager.default.temporaryDirectory,azimuth:0,elevation:0,style:"silhouette",solidSurface:initial[object.id])
    view.objectView = .init(sourceID:object.id,style:"silhouette",linked:true)
    let page=ProductObject(name:"Linked source view",recipeID:"artboard",parameters:[:],artwork:.init(elements:[view]))
    project.objects.append(page);store.engine.project=project
    _ = try store.engine.call("form_update_object",arguments:["object_id":object.id.uuidString,"parameters":["height":63.171875]])
    store.changed();let undo=store.engine.undoStack.count
    let pending=try XCTUnwrap(store.project?.objects.first{$0.id==page.id})
    XCTAssertEqual(pending.artwork?.elements.first?.path,view.path)
    XCTAssertEqual(pending.artwork?.elements.first?.objectView?.renderPending,true)
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:store.project!,object:pending))
    try await eventually{await gate.has(63.171875,false)}
    await gate.complete(63.171875,false)
    try await eventually{store.project?.objects.first{$0.id==page.id}?.artwork?.elements.first?.objectView?.renderPending==false}
    let refreshed=try XCTUnwrap(store.project?.objects.first{$0.id==page.id})
    XCTAssertNotEqual(refreshed.artwork?.elements.first?.path,view.path)
    XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:store.project!,object:refreshed))
    store.engine.undo();XCTAssertEqual(store.project?.objects.first?["height"],object["height"])
  }
  func testActualBuilderPreviewAndFullPrewarmKeepExportAuthoritative()async throws {
    let (store,object)=try fixture(height:41.125)
    defer{store.solids.reset()}
    let project=try XCTUnwrap(store.project),definition=try XCTUnwrap(project.recipe(object.recipeID)?.solid)
    let preview=try await Task.detached{try SolidSurfaceBuilder.build(definition,parameters:object.parameters,useEditingPreview:true)}.value
    try SolidRecipeGeometry.remember(preview,definition:definition,parameters:object.parameters)
    let prepared=try await SolidRecipeGeometry.prepareFullSources(project:project,objectIDs:[object.id]),full=try XCTUnwrap(prepared[object.id])
    XCTAssertFalse(full.isEditingPreview);XCTAssertGreaterThan(full.indices.count,preview.indices.count*10)
    let print=try PrintMeshBuilder.mesh(object:object,project:project,assets:FileManager.default.temporaryDirectory,configuration:.init(),solidSurface:full)
    XCTAssertEqual(print.triangles.count,full.indices.count/3)
    XCTAssertThrowsError(try PrintMeshBuilder.mesh(object:object,project:project,assets:FileManager.default.temporaryDirectory,configuration:.init(),solidSurface:preview))
    XCTAssertEqual(store.project,project);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
}
