import Foundation
import XCTest
import FormCADModel
import FormCADKernel
import FormCADModeling

final class CADModelingTests:XCTestCase {
  private func fixture()->CADModelDefinition {
    let b=CADFeatureNode(name:"Base",operation:.init(.box,values:["width":"width","height":"height","depth":"depth"]))
    let h=CADFeatureNode(name:"Shaft tool",operation:.init(.cylinder,values:["radius":"bore/2","height":"height+2"]))
    let m=CADFeatureNode(name:"Centered tool",operation:.init(.transform,inputs:[h.id],matrix:[1,0,0,"width/2",0,1,0,-1,0,0,1,"depth/2",0,0,0,1]))
    let c=CADFeatureNode(name:"Cut",operation:.init(.subtract,inputs:[b.id,m.id]))
    let f=CADFeatureNode(name:"Fillet",operation:.init(.fillet,inputs:[c.id],values:["radius":"edge"],selection:.allEdges))
    return .init(name:"Exact feature graph",parameters:[.init("width",80,60...160),.init("height",20,10...80),.init("depth",50,30...90),.init("bore",20,5...30),.init("edge",2,0.2...100),.init("unused",1,0...10)],features:[b,h,m,c,f],outputs:[f.id])
  }
  private func folder()throws->URL{let p=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true);addTeardownBlock{try? FileManager.default.removeItem(at:p)};return p}
  func testBoundedExpressionsGraphTopologyAndPortableSourceModel()throws {
    XCTAssertEqual(try CADExpression.evaluate("(width - wall*2)/2 + 1e-3",variables:["width":80,"wall":3]),37.001,accuracy:1e-12)
    for expression in ["system('rm')","1/0","nan","1e999","missing+1",String(repeating:"(",count:100)+"1"+String(repeating:")",count:100)]{XCTAssertThrowsError(try CADExpression.evaluate(expression,variables:[:]))}
    var model=fixture();XCTAssertEqual(try model.validatedOrder().count,5)
    let data=try JSONEncoder().encode(model),reopened=try JSONDecoder().decode(CADModelDefinition.self,from:data);XCTAssertEqual(model,reopened)
    model.features[0].operation.values["unexpected"]=1;XCTAssertThrowsError(try model.validatedOrder())
    let a=UUID(),b=UUID(),matrix:[CADScalar]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
    let cycle=CADModelDefinition(name:"Cycle",features:[.init(id:a,name:"A",operation:.init(.transform,inputs:[b],matrix:matrix)),.init(id:b,name:"B",operation:.init(.transform,inputs:[a],matrix:matrix))],outputs:[a]);XCTAssertThrowsError(try cycle.validatedOrder())
  }
  func testOnlyAffectedDownstreamFeaturesRebuildAndFailureRetainsPriorValidModel() async throws {
    let evaluator=CADModelEvaluator();var model=fixture();let first=try await evaluator.evaluate(model);XCTAssertEqual(first.rebuiltFeatureIDs.count,5)
    try model.setParameter("unused",value:2);let unused=try await evaluator.evaluate(model);XCTAssertTrue(unused.rebuiltFeatureIDs.isEmpty)
    try model.setParameter("width",value:100);let wider=try await evaluator.evaluate(model);XCTAssertEqual(wider.rebuiltFeatureIDs.count,4);XCTAssertFalse(wider.rebuiltFeatureIDs.contains(model.features[1].id))
    XCTAssertEqual(try XCTUnwrap(wider.outputs[model.outputs[0]]).info.size.x,100,accuracy:1e-6)
    try model.setParameter("edge",value:100)
    do{_=try await evaluator.evaluate(model);XCTFail("Impossible fillet accepted.")}catch let error as CADModelEvaluationFailure{XCTAssertEqual(error.featureID,model.outputs[0]);XCTAssertEqual(error.previousValidRevisionHash,wider.revisionHash)}
    let retained=await evaluator.lastValid(modelID:model.id);XCTAssertEqual(retained?.revisionHash,wider.revisionHash)
  }
  func testOrdinalSelectionRejectsUpstreamRegenerationWhileSemanticShellRemainsEditable() async throws {
    let evaluator=CADModelEvaluator(),base=CADFeatureNode(name:"Box",operation:.init(.box,values:["width":"width","height":30,"depth":40]))
    var model=CADModelDefinition(name:"Pinned topology",parameters:[.init("width",60,40...100)],features:[base],outputs:[base.id])
    let initial=try await evaluator.evaluate(model),topology=try await evaluator.featureTopology(modelID:model.id,featureID:base.id,modelRevisionHash:initial.revisionHash)
    let fillet=CADFeatureNode(name:"Selected edge",operation:.init(.fillet,inputs:[base.id],values:["radius":1],selection:.edges(revisionHash:topology.fingerprint,indices:[1])))
    model.features.append(fillet);model.outputs=[fillet.id];let valid=try await evaluator.evaluate(model)
    try model.setParameter("width",value:80)
    do{_=try await evaluator.evaluate(model);XCTFail("Old edge ordinal silently remapped.")}catch let error as CADModelEvaluationFailure{XCTAssertTrue(error.message.contains("reinspection"))}
    let retained=await evaluator.lastValid(modelID:model.id);XCTAssertEqual(retained?.revisionHash,valid.revisionHash)
    let shell=CADFeatureNode(name:"Top opening",operation:.init(.shell,inputs:[base.id],values:["thickness":2],selection:.faceAtMaximum(axis:"y")))
    model.features=[base,shell];model.outputs=[shell.id];let open=try await evaluator.evaluate(model);XCTAssertTrue(try XCTUnwrap(open.outputs[shell.id]).info.closed)
    try model.setParameter("width",value:90);let wider=try await evaluator.evaluate(model);XCTAssertEqual(try XCTUnwrap(wider.outputs[shell.id]).info.size.x,90,accuracy:1e-6)
  }
  func testExclusiveExactAssetsRoundtripAndCorruptPinnedSourceAreDetectedEvenWithCache() async throws {
    let evaluator=CADModelEvaluator(),model=fixture(),root=try folder(),evaluation=try await evaluator.evaluate(model)
    let destination=root.appendingPathComponent("revision"),manifest=try await evaluator.stageSources(evaluation,to:destination,quality:.inspection)
    let output=try XCTUnwrap(manifest.outputs.first);XCTAssertTrue(manifest.files.keys.contains(output.brep));XCTAssertTrue(manifest.files.keys.contains(output.mesh))
    let mesh=try await evaluator.mesh(for:evaluation,outputID:model.outputs[0]),decoded=try CADMeshArchive.decode(Data(contentsOf:destination.appendingPathComponent(output.mesh)));XCTAssertTrue(mesh==decoded,"Exact mesh archive values must survive round trip at the same tessellation quality.")
    let node=CADFeatureNode(name:"Pinned source",operation:.init(.importedBRep,source:.init(path:output.brep,sha256:manifest.files[output.brep]!)))
    let imported=CADModelDefinition(name:"Imported exact source",features:[node],outputs:[node.id]);let restored=try await evaluator.evaluate(imported,resourcesAt:destination)
    XCTAssertEqual(try XCTUnwrap(restored.outputs[node.id]).info.volumeMM3,try XCTUnwrap(evaluation.outputs[model.outputs[0]]).info.volumeMM3,accuracy:1e-4)
    try Data("corrupt".utf8).write(to:destination.appendingPathComponent(output.brep))
    do{_=try await evaluator.evaluate(imported,resourcesAt:destination);XCTFail("Changed pinned source accepted from cache.")}catch let error as CADModelEvaluationFailure{XCTAssertTrue(error.message.contains("digest changed"))}
    do{_=try await evaluator.stageSources(evaluation,to:destination,quality:.inspection);XCTFail("Existing revision overwritten.")}catch{}
  }
  func testStaleAndCancelledRequestsKeepAcceptedRevisionAndBoundedMeshDecodeRejectsTruncation() async throws {
    let evaluator=CADModelEvaluator(),model=fixture(),valid=try await evaluator.evaluate(model)
    do{_=try await evaluator.evaluate(model,expectedRevisionHash:"wrong-revision");XCTFail("Stale revision accepted.")}catch{}
    let task=Task{try await evaluator.evaluate(model)};task.cancel();do{_=try await task.value;XCTFail("Cancelled model published.")}catch is CancellationError{}
    let retained=await evaluator.lastValid(modelID:model.id);XCTAssertEqual(retained?.revisionHash,valid.revisionHash)
    let mesh=try await evaluator.mesh(for:valid,outputID:model.outputs[0]),data=try CADMeshArchive.encode(mesh)
    XCTAssertThrowsError(try CADMeshArchive.decode(data.dropLast()))
    var corrupt=data;corrupt[8]=99;XCTAssertThrowsError(try CADMeshArchive.decode(corrupt))
  }
  func testAllNativeConstructionExamplesHaveRealClosedOutputsAndEditableMajorDimensions() async throws {
    let evaluator=CADModelEvaluator()
    for name in CADModelExamples.names {
      var model=try CADModelExamples.make(name)
      let initial=try await evaluator.evaluate(model)
      XCTAssertFalse(initial.outputs.isEmpty)
      XCTAssertTrue(initial.outputs.values.allSatisfy{$0.info.valid&&$0.info.closed&&$0.info.volumeMM3>0})
      let parameter=name=="clockEnclosure" ? "diameter":name=="enclosure" ? "width":"height"
      let old=try XCTUnwrap(model.parameters.first{$0.name==parameter}).value
      try model.setParameter(parameter,value:old+10)
      let modified=try await evaluator.evaluate(model)
      XCTAssertFalse(modified.rebuiltFeatureIDs.isEmpty)
      XCTAssertTrue(modified.outputs.values.allSatisfy{$0.info.valid&&$0.info.closed})
    }
  }

  func testNamedHoleSlotPocketBossOffsetAndOccurrenceOperationsExecuteExactKernel()async throws {
    let evaluator=CADModelEvaluator();var features:[CADFeatureNode]=[]
    func add(_ name:String,_ operation:CADFeatureOperation)->UUID{let f=CADFeatureNode(name:name,operation:operation);features.append(f);return f.id}
    func plane(_ x:CADScalar,_ y:CADScalar,_ z:CADScalar)->CADPlaneDefinition{.init(origin:.init(x,y,z),u:.xAxis,v:.init(0,0,-1))}
    let base=add("Blank",.init(.box,values:["width":100,"height":20,"depth":80]))
    let hole=add("Hole",.init(.hole,inputs:[base],values:["radius":4,"depth":22],plane:plane(20,-1,20)))
    let slot=add("Slot",.init(.slot,inputs:[hole],values:["length":24,"width":8,"depth":22],plane:plane(65,-1,20)))
    let pocketProfile=add("Pocket profile",.init(.circleProfile,values:["radius":10],plane:plane(25,16,55)))
    let pocket=add("Pocket",.init(.pocket,inputs:[slot,pocketProfile],values:["distance":5]))
    let bossProfile=add("Boss profile",.init(.circleProfile,values:["radius":7],plane:plane(65,19,55)))
    let boss=add("Boss",.init(.boss,inputs:[pocket,bossProfile],values:["distance":9]))
    let copy=add("Copy",.init(.copy,inputs:[boss])),pattern=add("Pattern",.init(.linearPattern,inputs:[copy],values:["count":2],vector:.init(130,0,0)))
    let mirror=add("Mirror",.init(.mirror,inputs:[boss],plane:.yz)),circular=add("Circular",.init(.circularPattern,inputs:[boss],values:["count":3,"angleStepDegrees":120]))
    let circle=add("Circle",.init(.circleProfile,values:["radius":10])),offset=add("Offset",.init(.offsetProfile,inputs:[circle],values:["distance":2])),extruded=add("Offset extrusion",.init(.extrude,inputs:[offset],values:["distance":5]))
    let model=CADModelDefinition(name:"Exact vocabulary",features:features,outputs:[boss,pattern,mirror,circular,extruded]),result=try await evaluator.evaluate(model)
    let slotArea=128+Double.pi*16,expected=160000-Double.pi*16*20-slotArea*20-Double.pi*100*4+Double.pi*49*8
    XCTAssertEqual(try XCTUnwrap(result.outputs[boss]).info.volumeMM3,expected,accuracy:1e-4)
    XCTAssertEqual(try XCTUnwrap(result.outputs[extruded]).info.volumeMM3,Double.pi*144*5,accuracy:1e-4)
    XCTAssertEqual(try XCTUnwrap(result.outputs[pattern]).info.solids,2);XCTAssertEqual(try XCTUnwrap(result.outputs[circular]).info.solids,3)
    XCTAssertTrue(result.outputs.values.allSatisfy{$0.info.valid&&$0.info.closed})
    let kernel=await evaluator.kernel,source=try await kernel.circleProfile(radius:10)
    do{_ = try await kernel.offsetProfile(source,distance:-20);XCTFail("Collapsed offset accepted.")}catch{}
  }

  func testExactModelCacheEvictsInactiveModelsAndBudgetFailureRetainsCurrentValidRevision()async throws {
    let evaluator=CADModelEvaluator(maximumCachedModels:3,topologyCacheBudgetBytes:1_000_000);var ids:[UUID]=[]
    for i in 0..<12{let box=CADFeatureNode(name:"Box",operation:.init(.box,values:["width":CADScalar(Double(20+i)),"height":10,"depth":10])),model=CADModelDefinition(name:"Cache \(i)",features:[box],outputs:[box.id]);ids.append(model.id);_ = try await evaluator.evaluate(model)}
    let diagnostics=await evaluator.diagnostics;XCTAssertEqual(diagnostics["models"],3);XCTAssertEqual(diagnostics["model_cache_evictions"],9);XCTAssertLessThanOrEqual(diagnostics["feature_cache_estimated_bytes"]!,diagnostics["feature_cache_budget_bytes"]!)
    let evicted=await evaluator.lastValid(modelID:ids[0]);XCTAssertNil(evicted);await evaluator.forget(modelID:ids.last!);let afterForget=await evaluator.diagnostics;XCTAssertEqual(afterForget["models"],2)
    let bounded=CADModelEvaluator(topologyCacheBudgetBytes:80_000),box=CADFeatureNode(name:"Source",operation:.init(.box,values:["width":10,"height":10,"depth":10]))
    let pattern=CADFeatureNode(name:"Pattern",operation:.init(.linearPattern,inputs:[box.id],values:["count":"count"],vector:.init(20,0,0)))
    var model=CADModelDefinition(name:"Budget",parameters:[.init("count",1,1...30)],features:[box,pattern],outputs:[pattern.id]);let valid=try await bounded.evaluate(model)
    try model.setParameter("count",value:30)
    do{_ = try await bounded.evaluate(model);XCTFail("Unbounded exact topology was retained.")}catch let error as CADModelEvaluationFailure{XCTAssertTrue(error.message.contains("memory budget"));XCTAssertEqual(error.previousValidRevisionHash,valid.revisionHash)}
    let retained=await bounded.lastValid(modelID:model.id);XCTAssertEqual(retained?.revisionHash,valid.revisionHash)
  }

}
