import AppKit
import Foundation
import XCTest
import FormCore
import FormCADModel
import FormCADKernel
import FormCADModeling
import LabRendering
import simd
@testable import FormApp

@MainActor final class CADModelCoordinatorTests:XCTestCase {
  private func fixture()throws->StudioStore {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("CAD-native-tests-"+UUID().uuidString),repository=try ProjectRepository(root:root),project=Project(name:"Exact CAD test")
    try repository.save(project);let store=StudioStore(repository:repository,seedLibrary:false);try store.engine.open(project.id);store.showingHome=false
    addTeardownBlock{try? FileManager.default.removeItem(at:root)};return store
  }
  private func settled(_ job:CADModelReview)async throws {
    for _ in 0..<1000 {if !["preparing","publishing"].contains(job.state){return};try await Task.sleep(nanoseconds:20_000_000)}
    XCTFail("CAD job timed out: \(job.state)");throw FormError.invalid("CAD test timed out.")
  }
  func testNativeExactPreviewPublishesOnceAndUndoRetainsOriginalSourceAssets()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let before=try XCTUnwrap(store.project),job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job);try await settled(job)
    XCTAssertEqual(job.state,"ready",job.issue ?? "");XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    // Camera-only changes do not invalidate a design preview.
    store.engine.project!.camera.azimuth+=0.5
    try store.cad.commit(job);try await settled(job);XCTAssertEqual(job.state,"committed",job.issue ?? "");XCTAssertEqual(store.engine.undoStack.count,1)
    let object=try XCTUnwrap(store.project?.objects.first),model=try XCTUnwrap(object.cadModel);XCTAssertEqual(model.name,"Structured enclosure")
    let assets=store.repository.url(for:before.id).appendingPathComponent("Assets"),scene=try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value
    XCTAssertEqual(scene.count,1);XCTAssertGreaterThan(scene[0].mesh.triangleCount,100)
    store.engine.undo();XCTAssertTrue(try XCTUnwrap(store.project).objects.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath:assets.appendingPathComponent(object.cadRepresentation!.components[0].brepAsset).path))
  }
  func testDesignChangeAndUnpreviewedDraftCannotCommit()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job);try await settled(job);XCTAssertEqual(job.state,"ready",job.issue ?? "")
    try job.definition.setParameter("width",value:130);XCTAssertThrowsError(try store.cad.commit(job));XCTAssertTrue(store.project!.objects.isEmpty)
    job.definition=job.prepared!.definition
    try store.engine.edit("Changed source"){p in p.name="Changed design"}
    XCTAssertThrowsError(try store.cad.commit(job));XCTAssertTrue(store.project!.objects.isEmpty)
  }
  func testCancelledAndReopenedProjectCannotPublishLateWorker()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.clockEnclosure());store.cad.preview(job);store.cad.cancel(job);try await Task.sleep(nanoseconds:100_000_000)
    XCTAssertEqual(job.state,"cancelled");XCTAssertTrue(store.project!.objects.isEmpty)
    let second=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(second);try await settled(second);XCTAssertEqual(second.state,"ready",second.issue ?? "")
    let id=store.project!.id;try store.engine.open(id);XCTAssertThrowsError(try store.cad.commit(second));XCTAssertTrue(store.project!.objects.isEmpty)
  }
  func testDisplayLoadsPreserveBodyOriginAndDetectCorruptExactSource()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(job);try await settled(job);try store.cad.commit(job);try await settled(job)
    var object=try XCTUnwrap(store.project?.objects.first);object.position = .init(15,25,35);object.rotation=90
    let assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets"),payload=try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value
    XCTAssertEqual(payload[0].transform.translationMM.x,15);XCTAssertEqual(payload[0].transform.translationMM.y,25);XCTAssertEqual(payload[0].transform.translationMM.z,35)
    let source=assets.appendingPathComponent(object.cadRepresentation!.components[0].brepAsset);try Data("corrupt exact source".utf8).write(to:source)
    do{_ = try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value;XCTFail("Corrupt exact source was displayed as verified CAD.")}catch{XCTAssertTrue(error.localizedDescription.contains("SHA-256"))}
  }
  func testMalformedCADArgumentsNeverFallBackToCreatingDefaultGeometry()throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let inputs:[[String:Any]]=[
      ["command":"create","object_id":"bad"],["command":"create","job_id":"bad"],["command":"create","job_id":UUID().uuidString],
      ["command":"parameter","name":"width","value":true],["command":"parameter","values":["width":true]],
      ["command":"parameter","values":"bad"],["command":"create","quality":true],["command":"create","definition":[:],"unexpected":1],
      ["command":"create","object_id":UUID().uuidString,"template":"vase"],["command":1]]
    for args in inputs{XCTAssertThrowsError(try store.cad.call("form_cad",args))}
    XCTAssertTrue(store.project!.objects.isEmpty);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testSharedCADFamilyEditsPreserveVariantAppearanceAndNewModelsDoNotOverlap()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let first=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(first);try await settled(first);try store.cad.commit(first);try await settled(first)
    let original=try XCTUnwrap(store.project?.objects.first)
    _ = try store.engine.call("form_duplicate_object",arguments:["object_id":original.id.uuidString,"mode":"variant","material_id":"aluminum"])
    let variant=try XCTUnwrap(store.project?.objects.last),oldPosition=variant.position
    var definition=try XCTUnwrap(original.cadModel);try definition.setParameter("width",value:150)
    let edit=try store.cad.begin(definition,target:original.id);store.cad.preview(edit);try await settled(edit);try store.cad.commit(edit);try await settled(edit)
    XCTAssertEqual(edit.state,"committed",edit.issue ?? "");let family=store.project!.objects
    XCTAssertEqual(family[0].cadModel,family[1].cadModel);XCTAssertEqual(family[1].materialID,"aluminum");XCTAssertEqual(family[1].position,oldPosition)
    let second=try store.cad.begin(CADModelExamples.vase());store.cad.preview(second);try await settled(second);try store.cad.commit(second);try await settled(second)
    let added=try XCTUnwrap(store.project?.objects.last);XCTAssertGreaterThan(added.position.x,oldPosition.x)
    XCTAssertGreaterThan(added.position.x+added.cadRepresentation!.minimum.x,family.map{$0.position.x+$0.cadRepresentation!.maximum.x}.max()!)
  }

  func testSTEPAssemblyReviewPreservesPinnedBytesHierarchyFaceColorsAndReopens()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("FormCADKernelTests/Fixtures/colored-assembly.step")
    let job=try store.cad.begin(CADModelExamples.enclosure());job.sourceUpAxis="z";store.cad.preview(job,importURL:source);try await settled(job)
    XCTAssertEqual(job.state,"ready",job.issue ?? "");let ready=try XCTUnwrap(job.prepared),assembly=try XCTUnwrap(ready.definition.importedAssemblies?.first)
    XCTAssertEqual(ready.representation.components.count,3);XCTAssertEqual(assembly.nodes.count,5);XCTAssertEqual(assembly.sourceUpAxis,"z")
    XCTAssertTrue(assembly.nodes.filter{!$0.assembly}.allSatisfy{$0.outputFingerprint != nil})
    XCTAssertTrue(ready.scene.contains{$0.materials.count>1&&$0.materials.contains{$0.baseColor.z>0.8}})
    // Re-preview uses staged pinned bytes after the original read, not an absent project asset.
    store.cad.preview(job);try await settled(job);XCTAssertEqual(job.state,"ready",job.issue ?? "")
    try store.cad.commit(job);try await settled(job);XCTAssertEqual(job.state,"committed",job.issue ?? "")
    try store.engine.flush();let object=try XCTUnwrap(store.project?.objects.first),reopened=try store.repository.load(store.project!.id)
    XCTAssertEqual(reopened.objects.first?.cadModel,object.cadModel)
    let assets=store.repository.url(for:reopened.id).appendingPathComponent("Assets"),original=try Data(contentsOf:assets.appendingPathComponent(assembly.source.path));let expected=try Data(contentsOf:source);XCTAssertTrue(original==expected)
    let prepared=try await Task.detached{try CADSceneAdapter.prepare(for:object,assets:assets)}.value
    XCTAssertEqual(prepared.renderables.count,3)
    for payload in prepared.renderables{XCTAssertEqual(payload.mesh.parts.reduce(0){$0+$1.triangleIndices.count/3},payload.mesh.triangleCount)}
    var recolored=object;recolored.color="#CC3300";let appearance=CADSceneAdapter.renderables(prepared,for:recolored)
    XCTAssertEqual(appearance.map{$0.mesh.revision},prepared.renderables.map{$0.mesh.revision});XCTAssertTrue(appearance.allSatisfy{$0.materials.allSatisfy{$0.baseColor.x>0.7&&$0.baseColor.z==0}})
    // The same source mesh can acquire new material parts. Picking must use
    // the current representation's map, not an older cached partition.
    try await eventually{store.cad.resolvedScene(for:object,assets:assets) != nil}
    var changed=object;for a in changed.cadModel!.importedAssemblies!.indices{for n in changed.cadModel!.importedAssemblies![a].nodes.indices{changed.cadModel!.importedAssemblies![a].nodes[n].faceColors=[]}}
    changed.cadModel!.revision+=1;changed.cadRepresentation!.definitionSHA256=try CADRepresentation.definitionHash(changed.cadModel!)
    try store.engine.edit("Changed imported face appearance"){project in project.objects[0]=changed}
    try await eventually{store.cad.resolvedScene(for:changed,assets:assets) != nil}
    let current=try XCTUnwrap(store.cad.resolvedScene(for:changed,assets:assets)?.first),renderer=try RealityKitSceneRenderer(frame:.init(x:0,y:0,width:300,height:200));defer{renderer.reset()}
    try await renderer.upsertAsync(current)
    var minimum=SIMD3<Double>(repeating:.infinity),maximum=SIMD3<Double>(repeating:-.infinity);for p in current.mesh.positionsMM{minimum=simd_min(minimum,p);maximum=simd_max(maximum,p)}
    let target=(minimum+maximum)/2;try renderer.setCamera(.looking(from:target+SIMD3(0,0,250),at:target))
    let pick=try XCTUnwrap(renderer.pick(atTopLeft:.init(x:150,y:100),viewport:.init(width:300,height:200))),part=try XCTUnwrap(pick.partID)
    let currentMap=try XCTUnwrap(CADSceneAdapter.prepare(for:changed,assets:assets).triangleFaces[current.componentID+"|"+part]),expectedFace=try XCTUnwrap(currentMap.indices.contains(pick.triangle) ? currentMap[pick.triangle]:nil)
    XCTAssertEqual(store.cad.face(for:pick,object:changed)?["face_index"] as? Int,Int(expectedFace))
    let oldMap=prepared.triangleFaces[current.componentID+"|"+part],oldFace=oldMap.flatMap{$0.indices.contains(pick.triangle) ? $0[pick.triangle]:nil}
    XCTAssertNotEqual(oldFace,expectedFace)
    let external=source.deletingLastPathComponent().appendingPathComponent("external-reference.step"),bad=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(bad,importURL:external);try await settled(bad);XCTAssertEqual(bad.state,"failed");XCTAssertEqual(store.project?.objects.count,1)
  }

  private func eventually(_ condition:()->Bool)async throws {
    for _ in 0..<1000{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
    XCTFail("CAD scene outcome timed out.");throw FormError.invalid("CAD scene test timed out.")
  }
  func testRegeneratedFamilyRecoversFromOldMissingResourceWithoutManualRetry()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let initial=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(initial);try await settled(initial);try store.cad.commit(initial);try await settled(initial)
    let original=try XCTUnwrap(store.project?.objects.first)
    _ = try store.engine.call("form_duplicate_object",arguments:["object_id":original.id.uuidString,"mode":"variant"])
    let oldFamily=store.project!.objects,assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets")
    try FileManager.default.removeItem(at:assets.appendingPathComponent(original.cadRepresentation!.components[0].brepAsset))
    for object in oldFamily{XCTAssertNil(store.cad.resolvedScene(for:object,assets:assets))}
    try await eventually{oldFamily.allSatisfy{store.cad.issue(for:$0) != nil}}
    var definition=original.cadModel!;try definition.setParameter("width",value:132)
    let repaired=try store.cad.begin(definition,target:original.id);store.cad.preview(repaired);try await settled(repaired);XCTAssertEqual(repaired.state,"ready",repaired.issue ?? "")
    try store.cad.commit(repaired);try await settled(repaired);XCTAssertEqual(repaired.state,"committed",repaired.issue ?? "")
    let family=store.project!.objects;XCTAssertTrue(family.allSatisfy{store.cad.issue(for:$0)==nil})
    try await eventually{family.allSatisfy{store.cad.resolvedScene(for:$0,assets:assets) != nil}}
    XCTAssertTrue(family.allSatisfy{store.cad.issue(for:$0)==nil});XCTAssertEqual(family[0].cadModel,family[1].cadModel)
  }
  func testLateOldRevisionLoadFailureCannotPoisonRegeneratedScene()async throws {
    let store=try fixture();var suspended:CheckedContinuation<Void,Never>?,checkpointReached=false
    defer{store.cad.sceneLoadCheckpoint=nil;suspended?.resume();store.cad.reset();store.engine.project=nil}
    let initial=try store.cad.begin(CADModelExamples.enclosure());store.cad.preview(initial);try await settled(initial);try store.cad.commit(initial);try await settled(initial)
    let old=try XCTUnwrap(store.project?.objects.first),oldHash=old.cadRepresentation!.definitionSHA256,assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets")
    try FileManager.default.removeItem(at:assets.appendingPathComponent(old.cadRepresentation!.components[0].brepAsset))
    store.cad.sceneLoadCheckpoint={object in if object.cadRepresentation?.definitionSHA256==oldHash{await withCheckedContinuation{continuation in suspended=continuation;checkpointReached=true}}}
    _ = store.cad.resolvedScene(for:old,assets:assets);try await eventually{checkpointReached}
    var definition=old.cadModel!;try definition.setParameter("width",value:144)
    let repaired=try store.cad.begin(definition,target:old.id);store.cad.preview(repaired);try await settled(repaired);try store.cad.commit(repaired);try await settled(repaired);XCTAssertEqual(repaired.state,"committed",repaired.issue ?? "")
    let continuation=suspended;suspended=nil;continuation?.resume()
    let current=try XCTUnwrap(store.project?.objects.first)
    try await eventually{store.cad.resolvedScene(for:current,assets:assets) != nil}
    XCTAssertNil(store.cad.issue(for:current));XCTAssertNil(store.cad.failures[current.id])
  }

  private func loopFixture()->CADModelDefinition {
    let box=CADFeatureNode(name:"Body",operation:.init(.box,values:["width":"width","height":20,"depth":30]))
    let fillet=CADFeatureNode(name:"Edge finish",operation:.init(.fillet,inputs:[box.id],values:["radius":"radius"],selection:.allEdges))
    return .init(name:"Agent-authored loop fixture",parameters:[.init("width",40,30...80),.init("radius",1,0.1...100)],features:[box,fillet],outputs:[fillet.id])
  }

  func testPreviewKeepsExactGeometryInMemoryUntilPublication()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(loopFixture());store.cad.preview(job);try await settled(job)
    XCTAssertEqual(job.state,"ready",job.issue ?? "")
    let preview=try XCTUnwrap(job.prepared)
    XCTAssertFalse(preview.durable);XCTAssertTrue(preview.files.isEmpty);XCTAssertFalse(preview.scene.isEmpty)
    let files=FileManager.default.enumerator(at:preview.stage,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
    XCTAssertFalse(files.contains{["brep","step","mesh"].contains($0.pathExtension)})
    XCTAssertGreaterThanOrEqual(preview.timings["evaluation"] ?? -1,0)
    try store.cad.commit(job);try await settled(job)
    XCTAssertEqual(job.state,"committed",job.issue ?? "")
    let object=try XCTUnwrap(store.project?.objects.first),component=try XCTUnwrap(object.cadRepresentation?.components.first)
    XCTAssertFalse(component.brepAsset.hasPrefix("preview-"))
    let assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets")
    XCTAssertTrue(FileManager.default.fileExists(atPath:assets.appendingPathComponent(component.brepAsset).path))
    XCTAssertFalse((try FileManager.default.contentsOfDirectory(at:assets,includingPropertiesForKeys:nil)).contains{$0.pathExtension=="step"})
    XCTAssertEqual(store.engine.undoStack.count,1)
  }

  func testAtomicPatchRepairsFailedDraftAndRejectsStaleOrBrokenBatches()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let definition=loopFixture(),job=try store.cad.begin(definition);store.cad.preview(job);try await settled(job)
    let initial=try XCTUnwrap(job.prepared),revision=try CADModelEvaluator.revisionHash(job.definition)
    try store.cad.patch(job,expectedRevision:revision,patches:[["action":"parameters","values":["radius":99]]])
    try await settled(job);XCTAssertEqual(job.state,"failed")
    XCTAssertEqual(job.diagnostic?["feature_id"] as? String,definition.outputs[0].uuidString)
    XCTAssertEqual(job.prepared?.evaluation.revisionHash,initial.evaluation.revisionHash)
    XCTAssertFalse(job.scene.isEmpty);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let failedRevision=try CADModelEvaluator.revisionHash(job.definition)
    XCTAssertThrowsError(try store.cad.patch(job,expectedRevision:revision,patches:[["action":"parameters","values":["radius":0.5]]]))
    XCTAssertEqual(try CADModelEvaluator.revisionHash(job.definition),failedRevision)
    let unchanged=job.definition
    XCTAssertThrowsError(try store.cad.patch(job,expectedRevision:failedRevision,patches:[
      ["action":"parameters","values":["width":60]],
      ["action":"remove","feature_id":definition.features[0].id.uuidString]
    ]))
    XCTAssertEqual(job.definition,unchanged)
    var preparations=0;store.cad.preparationCheckpoint={preparations+=1}
    try store.cad.patch(job,expectedRevision:failedRevision,patches:[
      ["action":"parameters","values":["width":60]],
      ["action":"parameters","values":["radius":0.5]]
    ])
    try await settled(job);store.cad.preparationCheckpoint=nil
    XCTAssertEqual(preparations,1);XCTAssertEqual(job.state,"ready",job.issue ?? "")
    XCTAssertEqual(job.definition.revision,unchanged.revision+1)
    try store.cad.commit(job);try await settled(job)
    XCTAssertEqual(job.state,"committed",job.issue ?? "");XCTAssertEqual(store.engine.undoStack.count,1)
    XCTAssertEqual(store.project?.objects.first?.cadModel?.parameterValues["width"],60)
  }

  func testEvidenceRequestsAreIndependentAndPinnedWithoutChangingProject()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let before=store.project,job=try store.cad.begin(loopFixture());store.cad.preview(job);try await settled(job)
    let token=job.token,revision=try XCTUnwrap(job.prepared?.evaluation.revisionHash)
    let first=try store.cad.startEvidence(job,requests:[["kind":"summary"],["kind":"topology","feature_id":job.definition.features[0].id.uuidString,"limit":3]])
    let second=try store.cad.startEvidence(job,requests:[["kind":"summary"]])
    try await eventually{first.state != "pending" && second.state != "pending"}
    XCTAssertEqual(first.state,"complete",first.issue ?? "");XCTAssertEqual(second.state,"complete",second.issue ?? "")
    XCTAssertEqual(first.results.count,2);XCTAssertEqual(second.results.count,1)
    XCTAssertEqual(first.revision,revision);XCTAssertEqual(second.revision,revision);XCTAssertEqual(job.token,token)
    XCTAssertEqual((first.results[1]["faces"] as? [Any])?.count,3)
    XCTAssertEqual(first.results[1]["truncated"] as? Bool,true)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testParameterValidationUsesIsolatedEvaluationAndReportsFailedCases()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(loopFixture());store.cad.preview(job);try await settled(job)
    let original=try XCTUnwrap(job.prepared?.evaluation.revisionHash),definition=job.definition,before=store.project
    let request=try store.cad.startParameterValidation(job,args:["cases":[
      ["name":"nominal","values":[:]],
      ["name":"impossible finish","values":["radius":99]]
    ]])
    try await eventually{request.state != "pending"}
    XCTAssertEqual(request.state,"complete",request.issue ?? "")
    let report=try XCTUnwrap(request.results.first?["report"] as? [String:Any]),cases=try XCTUnwrap(report["cases"] as? [[String:Any]])
    XCTAssertEqual(report["allPassed"] as? Bool,false);XCTAssertEqual(cases.count,2)
    XCTAssertEqual(cases[0]["passed"] as? Bool,true);XCTAssertEqual(cases[1]["passed"] as? Bool,false)
    XCTAssertEqual(job.definition,definition);XCTAssertEqual(job.prepared?.evaluation.revisionHash,original)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    let topology=try store.cad.startEvidence(job,requests:[["kind":"topology","feature_id":definition.features[0].id.uuidString]])
    try await eventually{topology.state != "pending"};XCTAssertEqual(topology.state,"complete")
  }

  func testAuthoredRequirementFailureIsARepairableDraft()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    var definition=loopFixture();definition.version=2
    definition.requirements=[.init(id:"wall-fit",lhs:"width",relation:.lessThan,rhs:35,message:"Width must fit the declared opening")]
    let job=try store.cad.begin(definition);store.cad.preview(job);try await settled(job)
    XCTAssertEqual(job.state,"failed");XCTAssertEqual(job.diagnostic?["requirement_id"] as? String,"wall-fit")
    try store.cad.patch(job,expectedRevision:CADModelEvaluator.revisionHash(job.definition),patches:[["action":"parameters","values":["width":32]]])
    try await settled(job);XCTAssertEqual(job.state,"ready",job.issue ?? "")
  }

  func testNamedSurfaceArtworkUsesPhysicalUVsWithoutRebuildingGeometryAndBlocksLostBindings()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let box=CADFeatureNode(name:"Authored solid",operation:.init(.box,values:["width":40,"height":20,"depth":30]))
    let top=CADPlanarSurface(id:"top",name:"Readable top",outputFeatureID:box.id,selection:.faceAtMaximum(axis:"y"),origin:.init(0,20,0),uAxis:.xAxis,vAxis:.zAxis,width:40,height:30)
    let front=CADPlanarSurface(id:"front",name:"Readable front",outputFeatureID:box.id,selection:.faceAtMaximum(axis:"z"),origin:.init(0,20,30),uAxis:.xAxis,vAxis:.init(0,-1,0),width:40,height:20)
    let model=CADModelDefinition(name:"Agent-authored mapped solid",features:[box],outputs:[box.id],surfaces:[top,front])
    let job=try store.cad.begin(model);store.cad.preview(job);try await settled(job)
    XCTAssertEqual(job.state,"ready",job.issue ?? "")
    let preview=try XCTUnwrap(job.prepared),payload=try XCTUnwrap(preview.scene.first),slots=try XCTUnwrap(preview.display.surfaceSlots[payload.componentID]),topSlot=try XCTUnwrap(slots.first(where:{$0.value=="top"})?.key),topPart=try XCTUnwrap(payload.mesh.parts.first(where:{$0.materialIndex==topSlot}))
    for index in topPart.triangleIndices {
      let p=payload.mesh.positionsMM[Int(index)],uv=payload.mesh.uvs[Int(index)]
      XCTAssertEqual(Double(uv.x),p.x/40,accuracy:1e-6);XCTAssertEqual(Double(uv.y),p.z/30,accuracy:1e-6)
    }
    try store.cad.commit(job);try await settled(job)
    let original=try XCTUnwrap(store.project?.objects.first)
    var artboard=try store.project!.makeObject(recipeID:"artboard",name:"Shared physical source",parameters:["width":40,"depth":30])
    artboard.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:2,y:3,width:30,height:10,text:"UPRIGHT",fontSize:12)])
    try store.engine.edit("Added source"){p in p.objects.append(artboard)}
    _ = try PhysicalSurfaceCommands.call(engine:store.engine,arguments:["command":"bind","object_id":original.id.uuidString,"surface_id":"top","source_object_id":artboard.id.uuidString],source:"Test")
    let object=try XCTUnwrap(store.project?.objects.first),assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets"),display=try CADSceneAdapter.prepare(for:object,assets:assets)
    let first=try CADSurfaceAppearance.apply(display,object:object,project:store.project!,assets:assets,materials:store.materials)
    XCTAssertEqual(first.map{$0.mesh.revision},display.renderables.map{$0.mesh.revision})
    let firstTextures=first.flatMap(\.materials).compactMap(\.baseColorTexture)
    XCTAssertEqual(firstTextures.count,1)
    let textureBuilds=CADSurfaceAppearance.textureBuilds
    let identicalDisplay=try CADSceneAdapter.prepare(for:object,assets:assets)
    let repeated=try CADSurfaceAppearance.apply(identicalDisplay,object:object,project:store.project!,assets:assets,materials:store.materials)
    XCTAssertEqual(repeated.map{$0.mesh.revision},first.map{$0.mesh.revision})
    XCTAssertEqual(CADSurfaceAppearance.textureBuilds,textureBuilds)
    try store.engine.edit("Edited shared type"){p in let i=p.objects.firstIndex{$0.id==artboard.id}!;p.objects[i].artwork!.elements[0].text="CHANGED"}
    let second=try CADSurfaceAppearance.apply(display,object:object,project:store.project!,assets:assets,materials:store.materials)
    XCTAssertEqual(second.map{$0.mesh.revision},first.map{$0.mesh.revision})
    XCTAssertNotEqual(second.flatMap(\.materials).compactMap(\.baseColorTexture).first?.revision,firstTextures.first?.revision)
    let beforeResize=store.project
    var resized=try XCTUnwrap(object.cadModel)
    resized.surfaces![0].width=30;resized.revision+=1
    let resizeReview=try store.cad.begin(resized,target:object.id);store.cad.preview(resizeReview);try await settled(resizeReview)
    XCTAssertEqual(resizeReview.state,"ready",resizeReview.issue ?? "")
    XCTAssertEqual(store.cad.surfacePlacementIssues(resizeReview).map(\.code),["source_exceeds_surface"])
    XCTAssertTrue(resizeReview.prepared!.evaluation.rebuiltFeatureIDs.isEmpty)
    XCTAssertEqual(resizeReview.prepared!.representation.components.map(\.meshSHA256),object.cadRepresentation!.components.map(\.meshSHA256))
    XCTAssertEqual(store.project,beforeResize)
    XCTAssertEqual(store.project?.objects.first?.surfaceArtworkBindings?.first?.sourceObjectID,artboard.id)
    let statusIssues=try XCTUnwrap(store.cad.status(resizeReview)["surface_artwork_issues"] as? [[String:Any]])
    XCTAssertEqual(statusIssues.first?["surfaceID"] as? String,"top")
    let evidence=try store.cad.startEvidence(resizeReview,requests:[["kind":"summary"]])
    try await eventually{evidence.state != "pending"}
    XCTAssertEqual(evidence.state,"complete",evidence.issue ?? "")
    let evidenceIssues=try XCTUnwrap(evidence.results.first?["surface_artwork_issues"] as? [[String:Any]])
    XCTAssertEqual(evidenceIssues.first?["code"] as? String,"source_exceeds_surface")
    store.cad.cancel(resizeReview)
    var removed=try XCTUnwrap(object.cadModel);removed.surfaces=[];removed.revision+=1
    let edit=try store.cad.begin(removed,target:object.id);store.cad.preview(edit);try await settled(edit)
    XCTAssertEqual(edit.state,"ready",edit.issue ?? "")
    XCTAssertThrowsError(try store.cad.commit(edit))
    XCTAssertEqual(store.project?.objects.first?.surfaceArtworkBindings?.first?.surfaceID,"top")
  }

  func testActualTableCaptureIncludesNamedSurfaceArtworkAndSourceColorRevisions()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let body=CADFeatureNode(name:"Capture body",operation:.init(.box,values:["width":100,"height":10,"depth":80]))
    let top=CADPlanarSurface(id:"top",name:"Upright top",outputFeatureID:body.id,selection:.faceAtMaximum(axis:"y"),origin:.init(0,10,0),uAxis:.xAxis,vAxis:.zAxis,width:100,height:80)
    let model=CADModelDefinition(name:"Named artwork capture",features:[body],outputs:[body.id],surfaces:[top])
    let job=try store.cad.begin(model);store.cad.preview(job);try await settled(job)
    try store.cad.commit(job);try await settled(job)
    let object=try XCTUnwrap(store.project!.objects.first)
    var source=try store.project!.makeObject(recipeID:"artboard",parameters:["width":100,"depth":80])
    source.artwork = .init(background:"#FFFFFF",elements:[
      .init(kind:"rectangle",x:10,y:10,width:80,height:60,color:"#EE0033"),
      .init(kind:"text",x:15,y:18,width:70,height:20,text:"UPRIGHT",fontSize:14)
    ])
    try store.engine.edit("Added original physical artwork"){p in p.objects.append(source)}
    let controller=TableSceneController();defer{controller.renderer?.reset()}
    let assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets")
    let camera=SceneCameraPayload.looking(from:.init(50,180,40),at:.init(50,10,40),up:.init(0,0,-1),projection:.orthographic(verticalSpanMM:120))
    func capture()async throws->NSImage {
      controller.sync(store.project!,selection:[],isolated:[object.id],showGrid:false,studio:true,preset:"Daylight",assets:assets,renderObjectIDs:[object.id])
      return try await controller.snapshot(size:.init(width:320,height:240),camera:camera)
    }
    func coloredPixels(_ image:NSImage,red:Bool)throws->Int {
      let bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
      var count=0
      for y in stride(from:0,to:bitmap.pixelsHigh,by:2) {for x in stride(from:0,to:bitmap.pixelsWide,by:2) {
        guard let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else{continue}
        let primary=red ? color.redComponent:color.blueComponent,other=red ? color.blueComponent:color.redComponent
        if primary>0.3,primary>other*1.5,primary>color.greenComponent*1.5 {count+=1}
      }}
      return count
    }
    let plain=try await capture(),meshRevision=controller.extraRenderables.map{$0.mesh.revision}
    XCTAssertLessThan(try coloredPixels(plain,red:true),20)
    _ = try PhysicalSurfaceCommands.call(engine:store.engine,arguments:["command":"bind","object_id":object.id.uuidString,"surface_id":"top","source_object_id":source.id.uuidString],source:"Test")
    let red=try await capture()
    XCTAssertGreaterThan(try coloredPixels(red,red:true),300,"The actual capture omitted the named artwork texture.")
    XCTAssertEqual(controller.extraRenderables.map{$0.mesh.revision},meshRevision)
    try store.engine.edit("Changed shared source color"){p in let i=p.objects.firstIndex{$0.id==source.id}!;p.objects[i].artwork!.elements[0].color="#0033EE"}
    let blue=try await capture()
    XCTAssertGreaterThan(try coloredPixels(blue,red:false),300)
    XCTAssertLessThan(try coloredPixels(blue,red:true),20)
    XCTAssertEqual(controller.extraRenderables.map{$0.mesh.revision},meshRevision)
  }
  func testSharedModelCannotRemoveASurfaceBoundOnlyOnASiblingVariant()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let body=CADFeatureNode(name:"Variant body",operation:.init(.box,values:["width":40,"height":20,"depth":30]))
    let surface=CADPlanarSurface(id:"top",name:"Top",outputFeatureID:body.id,selection:.faceAtMaximum(axis:"y"),origin:.init(0,20,0),uAxis:.xAxis,vAxis:.zAxis,width:40,height:30)
    let model=CADModelDefinition(name:"Shared mapped model",features:[body],outputs:[body.id],surfaces:[surface])
    let initial=try store.cad.begin(model);store.cad.preview(initial);try await settled(initial)
    try store.cad.commit(initial);try await settled(initial)
    let original=try XCTUnwrap(store.project!.objects.first)
    _ = try store.engine.call("form_duplicate_object",arguments:["object_id":original.id.uuidString,"mode":"variant"])
    let sibling=try XCTUnwrap(store.project!.objects.last)
    var source=try store.project!.makeObject(recipeID:"artboard",parameters:["width":40,"depth":30])
    source.artwork = .init(background:"#FFFFFF")
    try store.engine.edit("Added sibling artwork source"){p in p.objects.append(source)}
    _ = try PhysicalSurfaceCommands.call(engine:store.engine,arguments:["command":"bind","object_id":sibling.id.uuidString,"surface_id":"top","source_object_id":source.id.uuidString],source:"Test")
    let before=store.project,undoCount=store.engine.undoStack.count
    var removed=model;removed.surfaces=[];removed.revision+=1
    let edit=try store.cad.begin(removed,target:original.id);store.cad.preview(edit);try await settled(edit)
    XCTAssertEqual(edit.state,"ready",edit.issue ?? "")
    let issues=store.cad.surfacePlacementIssues(edit)
    XCTAssertEqual(issues.first?.objectID,sibling.id);XCTAssertEqual(issues.first?.surfaceID,"top")
    XCTAssertEqual(issues.first?.code,"unresolved_surface")
    XCTAssertThrowsError(try store.cad.commit(edit)){error in
      XCTAssertTrue(error.localizedDescription.contains(sibling.id.uuidString+"/top"),error.localizedDescription)
    }
    XCTAssertEqual(edit.state,"ready");XCTAssertFalse(edit.prepared!.durable)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undoCount)
  }

  func testValidationCancelWaitsForAllCaseOutcomesWithoutChangingAcceptedSource()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let job=try store.cad.begin(loopFixture());store.cad.preview(job);try await settled(job)
    let before=store.project,definition=job.definition
    let cases=(0..<128).map{["name":"cancel-\($0)","values":[:]] as [String:Any]}
    let request=try store.cad.startParameterValidation(job,args:["cases":cases,"maximum_cases":128])
    let pending=try XCTUnwrap(store.cad.loopCall("evidence_cancel",["request_id":request.id.uuidString]) as? [String:Any])
    XCTAssertEqual(pending["state"] as? String,"pending")
    XCTAssertEqual(pending["cancellation_requested"] as? Bool,true)
    try await eventually{request.state != "pending"}
    XCTAssertEqual(request.state,"cancelled",request.issue ?? "")
    let report=try XCTUnwrap(request.results.first?["report"] as? [String:Any])
    let outcomes=try XCTUnwrap(report["cases"] as? [[String:Any]])
    XCTAssertEqual(outcomes.count,128)
    XCTAssertEqual(outcomes.compactMap{$0["name"] as? String},(0..<128).map{"cancel-\($0)"})
    XCTAssertEqual(outcomes.compactMap{$0["outcome"] as? String}.count,128)
    XCTAssertEqual(report["interruption"] as? String,"cancelled")
    XCTAssertEqual(report["allPassed"] as? Bool,false)
    XCTAssertEqual(store.project,before);XCTAssertEqual(job.definition,definition)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }

  func testOlderNumericMetadataRemainsReadableUntilExplicitEvaluationAndUndoableCommit()async throws {
    let store=try fixture();defer{store.cad.reset();store.engine.project=nil}
    let body=CADFeatureNode(name:"Box",operation:.init(.box,values:["width":20,"height":30,"depth":40]))
    let model=CADModelDefinition(name:"Saved numeric provenance",features:[body],outputs:[body.id])
    let initial=try store.cad.begin(model);store.cad.preview(initial);try await settled(initial)
    XCTAssertEqual(initial.state,"ready",initial.issue ?? "")
    try store.cad.commit(initial);try await settled(initial)
    var legacy=try XCTUnwrap(store.project),object=try XCTUnwrap(legacy.objects.first)
    object.cadRepresentation!.kernelVersion="8.0.1"
    object.cadRepresentation!.components[0].volumeMM3=12345
    legacy.objects[0]=object
    let assets=store.repository.url(for:legacy.id).appendingPathComponent("Assets"),component=try XCTUnwrap(object.cadRepresentation?.components.first)
    let exact=assets.appendingPathComponent(component.brepAsset),mesh=assets.appendingPathComponent(component.meshAsset)
    let exactBytes=try Data(contentsOf:exact),meshBytes=try Data(contentsOf:mesh)
    // Simulate an actual older saved project. Clear the current engine value
    // before open(), whose normal flush must not replace this legacy fixture.
    store.cad.reset();store.engine.project=nil
    try store.repository.save(legacy);try store.engine.open(legacy.id)
    let loaded=try XCTUnwrap(store.project),encoded=try JSONEncoder.form.encode(loaded)
    let inspected=try XCTUnwrap(store.cad.call("form_cad",["command":"inspect","object_id":object.id.uuidString]) as? [String:Any])
    let provenance=try XCTUnwrap(inspected["numeric_metadata"] as? [String:Any])
    XCTAssertEqual(inspected["kernel_version"] as? String,CADKernel.version)
    XCTAssertEqual(provenance["recorded_kernel_version"] as? String,"8.0.1")
    XCTAssertEqual(provenance["current_kernel_version"] as? String,"8.0.1+form.gprop1")
    XCTAssertEqual(provenance["state"] as? String,"other_kernel_build")
    XCTAssertEqual(provenance["recomputed_on_load"] as? Bool,false)
    XCTAssertEqual(provenance["reevaluate_to_refresh"] as? Bool,true)
    XCTAssertEqual(store.project?.objects.first?.cadRepresentation?.components.first?.volumeMM3,12345)
    let display=try await Task.detached{try CADSceneAdapter.load(for:object,assets:assets)}.value
    XCTAssertEqual(display.count,1);XCTAssertGreaterThan(display[0].mesh.triangleCount,0)
    XCTAssertEqual(try JSONEncoder.form.encode(try XCTUnwrap(store.project)),encoded)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    let refresh=try store.cad.begin(model,target:object.id);store.cad.preview(refresh);try await settled(refresh)
    XCTAssertEqual(refresh.state,"ready",refresh.issue ?? "")
    let status=store.cad.status(refresh),fresh=try XCTUnwrap(status["numeric_metadata"] as? [String:Any]),saved=try XCTUnwrap(status["saved_numeric_metadata"] as? [String:Any])
    XCTAssertEqual(fresh["state"] as? String,"current_kernel_build")
    XCTAssertEqual(saved["state"] as? String,"other_kernel_build")
    XCTAssertEqual(store.project,loaded,"A preview must not rewrite saved numeric metadata")
    try store.cad.commit(refresh);try await settled(refresh)
    XCTAssertEqual(refresh.state,"committed",refresh.issue ?? "")
    XCTAssertEqual(store.engine.undoStack.count,1)
    let current=try XCTUnwrap(store.project?.objects.first?.cadRepresentation)
    XCTAssertEqual(current.kernelVersion,CADKernel.version)
    XCTAssertEqual(current.components[0].volumeMM3,24000,accuracy:1e-6)
    XCTAssertEqual(try Data(contentsOf:exact),exactBytes);XCTAssertEqual(try Data(contentsOf:mesh),meshBytes)
    store.engine.undo();XCTAssertEqual(store.project,loaded)
  }
}
