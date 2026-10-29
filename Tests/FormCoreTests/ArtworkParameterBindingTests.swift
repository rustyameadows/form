import Foundation
import XCTest
import FormCADModel
@testable import FormCore

@MainActor final class ArtworkParameterBindingTests:XCTestCase {
  private final class Gate {
    var visits=0,entered=false
    var continuation:CheckedContinuation<Void,Never>?
    func wait()async {visits+=1;guard visits==2 else{return};entered=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
  }
  private struct Fixture {let engine:OperationEngine,source:UUID,assembly:UUID,attachment:UUID}
  private func fixture()throws->Fixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("authored-sewn-controls-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Unfamiliar authored sewn form")
    let recipe=Recipe("unregisteredWingStudy","Paired curved wing study","scissors","Existing source fields with saved numeric controls",[
      .init("width","Source width",350,200...600),.init("depth","Source height",160,80...250),
      .init("span","Panel span",85,35...130),.init("rise","Panel rise",65,40...100),
      .init("allowance","Cut allowance",8,2...12),.init("mismatch","Back span offset",0,0...12)])
    _ = try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe)])
    let added=try XCTUnwrap(engine.call("form_add_object",arguments:["recipe_id":recipe.id]) as? [String:Any])
    let source=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(added["id"] as? String)))
    func piece(_ name:String,x:Double)throws->ArtworkElement {
      var e=ArtworkElement(kind:"path",x:x,y:20,width:85,height:65,color:"#367385")
      var contour=VectorContour([.init(.init(0,0)),.init(.init(100,0),outgoing:.init(102,28)),
        .init(.init(92,70),incoming:.init(103,45),outgoing:.init(71,86)),.init(.init(18,78),incoming:.init(40,83),outgoing:.init(2,61))]);contour.id=UUID()
      e.path = .init(width:100,height:80,contours:[contour])
      var annotation=SewingPatternPiece(name:name);annotation.seamAllowance=8
      e.sewingPiece=try SewingPatterns.bindingStableEdges(annotation,to:e);e.fillEnabled=false
      return e
    }
    let front=try piece("Front wing",x:20),back=try piece("Back wing",x:140)
    var art=Artwork(background:"#FFFFFF",elements:[front,back])
    var seam=SewingSeam(name:"Shared straight opening",first:.init(elementID:front.id,edge:0),second:.init(elementID:back.id,edge:0));seam.tolerance=0.2
    _ = try SewingPatternCommands.edit("seam_pair",artwork:&art,ids:[],arguments:["seam":try jsonObject(seam)])
    _ = try engine.call("form_set_artwork",arguments:["object_id":source.uuidString,"artwork":try jsonObject(art)])
    let bindings:[ArtworkParameterBinding]=[
      .init(id:"front-span",elementID:front.id,property:.width,value:"span"),.init(id:"back-span",elementID:back.id,property:.width,value:"span+mismatch"),
      .init(id:"front-rise",elementID:front.id,property:.height,value:"rise"),.init(id:"back-rise",elementID:back.id,property:.height,value:"rise"),
      .init(id:"back-position",elementID:back.id,property:.x,value:"span+55"),
      .init(id:"front-allowance",elementID:front.id,property:.seamAllowance,value:"allowance"),.init(id:"back-allowance",elementID:back.id,property:.seamAllowance,value:"allowance")]
    _ = try engine.call("form_update_object",arguments:["object_id":source.uuidString,"artwork_parameter_bindings":try jsonObject(bindings)])
    var assembly=UUID(),attachment=UUID()
    try engine.edit("Declared rest assembly and physical anchor"){p in
      let material=try XCTUnwrap(Material.presets.first{$0.category=="Fabric"})
      let a=PatternPanelID(elementID:front.id,copy:1),b=PatternPanelID(elementID:back.id,copy:1)
      let definition=PatternAssemblyDefinition(sourceObjectID:source,panels:[
        .init(panel:a,pose:.init(originMm:.init(0,0,0),uAxis:.init(1,0,0),vAxis:.init(0,1,0),materialFront:1),material:material,densityGSM:220,textureOriginMm:.init(3,7)),
        .init(panel:b,pose:.init(originMm:.init(0,0,20),uAxis:.init(1,0,0),vAxis:.init(0,1,0),materialFront:1),material:material,densityGSM:220,textureOriginMm:.init(3,7))],seamIDs:[seam.id],maximumEdgeMm:20)
      assembly=try p.addPatternAssembly(definition,name:"Unregistered paired rest panels")
      var decoration=try p.makeObject(recipeID:"artboard",name:"Physical material anchor")
      decoration.patternAssemblyAttachment = .init(surfaceObjectID:assembly,anchor:.init(panel:a,materialPointMm:.init(45,20),normalOffsetMm:1))
      attachment=decoration.id;p.objects.append(decoration)
    }
    return .init(engine:engine,source:source,assembly:assembly,attachment:attachment)
  }
  private func source(_ f:Fixture)throws->ProductObject {try XCTUnwrap(f.engine.project?.objects.first{$0.id==f.source})}
  private func request(_ f:Fixture,_ cases:[PlanarParameterCase])throws->ArtworkConstructionValidationRequest {
    try .init(project:try XCTUnwrap(f.engine.project),objectID:f.source,cases:cases)
  }
  func testExistingRecipeAndObjectToolsResolveOneCanonicalSourceWithStableEdgesUndoAndReopen()throws {
    let f=try fixture(),before=try XCTUnwrap(f.engine.project),old=try source(f),undo=f.engine.undoStack.count
    XCTAssertTrue(try XCTUnwrap(before.recipe(old.recipeID)).parts.isEmpty,"An artwork owner needs no fake solid or product registration")
    let ids=old.artwork!.elements.flatMap{$0.path!.contours.flatMap(\.nodes).map(\.id)}
    let edges=try old.artwork!.elements.flatMap{try SewingCurves.boundaries($0,in:old.artwork!).flatMap(\.edges).compactMap(\.id)}
    _ = try f.engine.call("form_update_object",arguments:["object_id":f.source.uuidString,"parameters":["span":110.0,"allowance":11.0]])
    let changed=try source(f)
    XCTAssertEqual(changed.artwork?.elements[0].width,110);XCTAssertEqual(changed.artwork?.elements[1].x,165)
    XCTAssertEqual(changed.artwork?.elements[0].sewingPiece?.seamAllowance,11)
    XCTAssertEqual(changed.artwork!.elements.flatMap{$0.path!.contours.flatMap(\.nodes).map(\.id)},ids)
    XCTAssertEqual(try changed.artwork!.elements.flatMap{try SewingCurves.boundaries($0,in:changed.artwork!).flatMap(\.edges).compactMap(\.id)},edges)
    XCTAssertEqual(f.engine.undoStack.count,undo+1);XCTAssertEqual(changed.id,old.id)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id==f.assembly}?.patternAssembly,before.objects.first{$0.id==f.assembly}?.patternAssembly)
    try f.engine.flush();let reopened=try f.engine.repository.load(before.id)
    XCTAssertEqual(reopened.minimumSchemaVersion,56);XCTAssertEqual(reopened.objects,f.engine.project?.objects)
    f.engine.undo();XCTAssertEqual(f.engine.project?.objects,before.objects)
    f.engine.redo();XCTAssertEqual(try source(f),changed)
  }
  func testBoundFieldEditsMissingTargetsAndInvalidExpressionsFailClosedAndExplicitRemovalWorks()throws {
    let f=try fixture(),before=f.engine.project,undo=f.engine.undoStack.count,original=try source(f)
    XCTAssertThrowsError(try f.engine.edit("Conflicting direct edit"){p in p.objects[0].artwork!.elements[0].width+=1}){error in
      let failure=error as? ArtworkParameterBindingFailure;XCTAssertEqual(failure?.bindingID,"front-span");XCTAssertEqual(failure?.elementID,original.artwork?.elements[0].id)
    }
    for expression in ["missingControl","-1","1/0"] {
      var bindings=try XCTUnwrap(original.artworkParameterBindings);bindings[0].value=CADScalar(expression)
      XCTAssertThrowsError(try f.engine.call("form_update_object",arguments:["object_id":f.source.uuidString,"artwork_parameter_bindings":try jsonObject(bindings)]))
    }
    XCTAssertThrowsError(try f.engine.edit("Removed bound target"){p in p.objects[0].artwork!.elements.removeFirst()})
    var misspelled=try XCTUnwrap(jsonObject(original.artworkParameterBindings!) as? [[String:Any]])
    misspelled[0]["expression"]="span"
    XCTAssertThrowsError(try f.engine.call("form_update_object",arguments:["object_id":f.source.uuidString,"artwork_parameter_bindings":misspelled]))
    XCTAssertEqual(f.engine.project,before);XCTAssertEqual(f.engine.undoStack.count,undo)
    _ = try f.engine.call("form_update_object",arguments:["object_id":f.source.uuidString,"artwork_parameter_bindings":NSNull()])
    try f.engine.edit("Explicitly unbound field"){p in p.objects[0].artwork!.elements[0].width+=1}
    XCTAssertNil(try source(f).artworkParameterBindings)
  }
  func testReadOnlyCasesMeasureChangedCurvesAllowancesSeamsRestUVsAndAttachmentFailuresThenRepair()async throws {
    let f=try fixture(),before=f.engine.project,undo=f.engine.undoStack.count,selection=f.engine.selection
    let cases:[PlanarParameterCase]=[.init(name:"small",values:["span":60,"allowance":4]),.init(name:"large",values:["span":110,"allowance":11]),
      .init(name:"bad-seam",values:["mismatch":8]),.init(name:"anchor-outside",values:["span":35])]
    let input=try request(f,cases),report=try await input.run()
    XCTAssertEqual(report.cases.map(\.outcome),[.passed,.passed,.failed,.failed]);XCTAssertFalse(report.passed)
    let small=report.cases[0],large=report.cases[1]
    XCTAssertGreaterThan(large.pieces[0].stitchBoundsMM.width,small.pieces[0].stitchBoundsMM.width+40)
    XCTAssertGreaterThan(large.pieces[0].cutAreaMM2,small.pieces[0].cutAreaMM2)
    XCTAssertEqual(small.pieces[0].seamAllowanceMM,4);XCTAssertEqual(large.pieces[0].seamAllowanceMM,11)
    XCTAssertEqual(small.pieces[0].edgeIDs,large.pieces[0].edgeIDs)
    XCTAssertGreaterThan(large.assemblies[0].panels[0].materialSizeMM.x,small.assemblies[0].panels[0].materialSizeMM.x)
    XCTAssertNotEqual(large.assemblies[0].sourceDigest,small.assemblies[0].sourceDigest)
    XCTAssertEqual(small.assemblies[0].panels.map(\.textureOriginMM),large.assemblies[0].panels.map(\.textureOriginMM))
    XCTAssertEqual(small.attachments[0].objectID,f.attachment);XCTAssertEqual(large.attachments[0].anchor,small.attachments[0].anchor)
    XCTAssertEqual(large.attachments[0].placement.positionMm.x,small.attachments[0].placement.positionMm.x,accuracy:1e-7,"A physical material point retains its millimeter phase after remeshing")
    XCTAssertGreaterThan(report.cases[2].seams[0].differenceMM,7.9)
    XCTAssertTrue(report.cases[3].error?.contains(f.attachment.uuidString)==true)
    XCTAssertEqual(f.engine.project,before);XCTAssertEqual(f.engine.undoStack.count,undo);XCTAssertEqual(f.engine.selection,selection)
    var bindings=try XCTUnwrap(source(f).artworkParameterBindings);let back=try XCTUnwrap(bindings.firstIndex{$0.id=="back-span"});bindings[back].value="span"
    _ = try f.engine.call("form_update_object",arguments:["object_id":f.source.uuidString,"artwork_parameter_bindings":try jsonObject(bindings)])
    try f.engine.edit("Repair the declared material anchor"){p in let i=p.objects.firstIndex{$0.id==f.attachment}!;p.objects[i].patternAssemblyAttachment!.anchor.materialPointMm = .init(20,20)}
    let repaired=try await request(f,cases).run();XCTAssertTrue(repaired.passed)
    XCTAssertEqual(repaired.cases.map(\.outcome),[.passed,.passed,.passed,.passed])
  }
  func testCancelledAndDeadlineCasesRetainEveryRequestedValueWithoutHistoryMutation()async throws {
    let f=try fixture(),before=f.engine.project,undo=f.engine.undoStack.count,input=try request(f,[.init(name:"one",values:["span":60]),.init(name:"two",values:["span":110]),.init(name:"three",values:["rise":85])])
    let work=Task{try await input.run()};work.cancel()
    do{_ = try await work.value;XCTFail("Cancelled source cases passed")}
    catch let error as ArtworkConstructionValidationInterrupted {XCTAssertEqual(error.reason,.cancelled);XCTAssertEqual(error.report.cases.map(\.outcome),[.notRun,.notRun,.notRun]);XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)})}
    do{_ = try await input.run(maximumDurationSeconds:0.2,checkpoint:{try await Task.sleep(nanoseconds:2_000_000_000)});XCTFail("Deadline source cases passed")}
    catch let error as ArtworkConstructionValidationInterrupted {XCTAssertEqual(error.reason,.budgetExceeded);XCTAssertFalse(error.report.passed);XCTAssertEqual(error.report.cases.map(\.name),["one","two","three"]);XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)});XCTAssertEqual(error.report.cases.map(\.outcome),[.budgetExceeded,.notRun,.notRun])}
    let gate=Gate(),partial=Task{try await input.run(checkpoint:{await gate.wait()})}
    for _ in 0..<3000 {if gate.entered{break};try await Task.sleep(nanoseconds:1_000_000)}
    XCTAssertTrue(gate.entered);partial.cancel();gate.release()
    do{_ = try await partial.value;XCTFail("Partially cancelled source batch passed")}
    catch let error as ArtworkConstructionValidationInterrupted {
      XCTAssertEqual(error.report.cases.map(\.outcome),[.passed,.cancelled,.notRun])
      XCTAssertEqual(error.report.cases.map(\.values),input.cases.map{input.caseValues($0)})
      XCTAssertFalse(error.report.cases[0].assemblies.isEmpty,"Completed rest geometry evidence must be retained")
      XCTAssertFalse(error.report.cases[0].attachments.isEmpty)
      XCTAssertTrue(error.report.cases[2].pieces.isEmpty)
    }
    XCTAssertEqual(f.engine.project,before);XCTAssertEqual(f.engine.undoStack.count,undo)
  }
  func testSharedVariantsResolveTogetherAndIndependentIterationsRetainTheirOwnBindings()throws {
    let f=try fixture(),original=try source(f)
    let variant=try XCTUnwrap(f.engine.call("form_duplicate_object",arguments:["object_id":f.source.uuidString,"mode":"variant"]) as? [String:Any])
    let variantID=try XCTUnwrap(variant["id"] as? String)
    let before=try XCTUnwrap(f.engine.project),undo=f.engine.undoStack.count
    _ = try f.engine.call("form_update_object",arguments:["object_id":variantID,"parameters":["span":110.0]])
    XCTAssertEqual(try source(f)["span"],110)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.parameters["span"],110)
    XCTAssertEqual(try source(f).artwork?.elements[0].width,110)
    XCTAssertEqual(f.engine.undoStack.count,undo+1)
    let resolved=try XCTUnwrap(f.engine.project)
    f.engine.undo();XCTAssertEqual(f.engine.project?.objects,before.objects)
    f.engine.redo();XCTAssertEqual(f.engine.project?.objects,resolved.objects)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.artwork?.elements[0].width,110)
    try f.engine.edit("Shared appearance, separate parameter geometry"){p in var art=p.objects.first{$0.id==f.source}!.artwork!;art.elements[0].color="#FF0000";try p.setArtwork(art,for:f.source)}
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.artwork?.elements[0].width,110)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.artwork?.elements[0].color,"#FF0000")
    var ownBindings=try XCTUnwrap(original.artworkParameterBindings);ownBindings[0].value="span+2"
    _ = try f.engine.call("form_update_object",arguments:["object_id":variantID,"artwork_parameter_bindings":try jsonObject(ownBindings)])
    XCTAssertEqual(try source(f)["span"],110);XCTAssertEqual(try source(f).artwork?.elements[0].width,110)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.parameters["span"],110)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.artwork?.elements[0].width,112,"Each member's explicit saved expression remains authoritative")
    let iteration=try XCTUnwrap(f.engine.call("form_duplicate_object",arguments:["object_id":f.source.uuidString,"mode":"iteration"]) as? [String:Any])
    XCTAssertEqual(try XCTUnwrap(iteration["artworkParameterBindings"] as? [[String:Any]]).count,original.artworkParameterBindings?.count)
    let iterationID=try XCTUnwrap(iteration["id"] as? String)
    _ = try f.engine.call("form_update_object",arguments:["object_id":iterationID,"parameters":["span":70.0]])
    let independent=try XCTUnwrap(f.engine.project?.objects.first{$0.id.uuidString==iterationID})
    XCTAssertEqual(independent["span"],70);XCTAssertEqual(independent.artwork?.elements[0].width,70)
    XCTAssertEqual(independent.artworkParameterBindings,original.artworkParameterBindings)
    XCTAssertEqual(try source(f)["span"],110);XCTAssertEqual(try source(f).artwork?.elements[0].width,110)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id.uuidString==variantID}?.artwork?.elements[0].width,112)
  }
  func testCombinedEvidenceBudgetRejectsOversizedBatchesAndActualMaximumSimpleBatchFitsBridge()async throws {
    let f=try fixture(),cases=(0..<64).map{PlanarParameterCase(name:"case-\($0)",values:[:])}
    var simple=try XCTUnwrap(f.engine.project);simple.objects.removeAll{$0.id != f.source}
    let report=try await ArtworkConstructionValidationRequest(project:simple,objectID:f.source,cases:cases).run(maximumDurationSeconds:30)
    XCTAssertTrue(report.passed);XCTAssertEqual(report.cases.count,64)
    XCTAssertLessThan(try JSONEncoder.form.encode(report).count,8*1024*1024)
    var large=try XCTUnwrap(f.engine.project),art=large.objects[0].artwork!
    for i in 2..<64 {
      var piece=art.elements[0];piece.id=UUID();piece.sewingPiece!.name="Independent repeated panel \(i)"
      for c in piece.path!.contours.indices {
        piece.path!.contours[c].id=UUID()
        for n in piece.path!.contours[c].nodes.indices {piece.path!.contours[c].nodes[n].id=UUID()}
      }
      art.elements.append(piece)
    }
    try validateArtwork(art);large.objects[0].artwork=art
    XCTAssertThrowsError(try ArtworkConstructionValidationRequest(project:large,objectID:f.source,cases:cases)){error in
      XCTAssertTrue(error.localizedDescription.contains("evidence"));XCTAssertTrue(error.localizedDescription.contains("fewer cases"))
    }
  }
  func testCustomCanonicalSourceUsesExistingPaperAndExactSurfaceLinksWithoutARecipeNameSpecialCase()throws {
    let f=try fixture(),original=try source(f),hash=String(repeating:"a",count:64)
    let feature=CADFeatureNode(name:"Body",operation:.init(.box,values:["width":100,"height":20,"depth":50]))
    let surface=CADPlanarSurface(id:"top",name:"Top",outputFeatureID:feature.id,selection:.faceAtMaximum(axis:"y"),origin:.init(0,20,50),uAxis:.xAxis,vAxis:.init(0,0,-1),width:100,height:50)
    let definition=CADModelDefinition(name:"Existing exact source",features:[feature],outputs:[feature.id],surfaces:[surface])
    var component=CADComponentRepresentation(id:feature.id,name:"Body",brepAsset:"body.brep",brepSHA256:hash,meshAsset:"body.mesh",meshSHA256:hash,
      minimum:.init(),maximum:.init(100,20,50),volumeMM3:100000,valid:true,closed:true,solidCount:1,faceCount:6,edgeCount:12,vertexCount:8,triangleCount:12)
    component.featureFingerprint=hash
    var representation=CADRepresentation(modelID:definition.id,definitionSHA256:try CADRepresentation.definitionHash(definition),kernelVersion:"test",components:[component])
    var resolved=try surface.resolved(using:[:]);resolved.faceIndex=1;resolved.fingerprint=hash;representation.resolvedSurfaces=[resolved]
    var exact=ProductObject(name:"Exact consumer",recipeID:"cadModel",parameters:[:]);exact.cadModel=definition;exact.cadRepresentation=representation
    var paperID=UUID()
    try f.engine.edit("Existing physical consumers"){p in
      let paper=try p.makeObject(recipeID:"paperEnvelope");paperID=paper.id;p.objects += [paper,exact]
      XCTAssertTrue(p.isIndependentFlatArtworkSource(original))
    }
    _ = try f.engine.call("form_link_artwork",arguments:["object_id":paperID.uuidString,"source_object_id":f.source.uuidString,"fit":"actual"])
    _ = try f.engine.call("form_surface",arguments:["command":"bind","object_id":exact.id.uuidString,"surface_id":"top","source_object_id":f.source.uuidString])
    XCTAssertEqual(f.engine.project?.objects.first{$0.id==paperID}?.artworkSourceID,f.source)
    XCTAssertEqual(f.engine.project?.objects.first{$0.id==exact.id}?.surfaceArtworkBindings?.first?.sourceObjectID,f.source)
    var paper=try PaperConstruction.definition(for:XCTUnwrap(f.engine.project?.objects.first{$0.id==paperID}));paper.insideArtworkSourceID=f.source;paper.insideArtwork=nil
    _ = try f.engine.call("form_paper",arguments:["command":"configure","object_id":paperID.uuidString,"definition":try jsonObject(paper)])
    XCTAssertEqual(f.engine.project?.objects.first{$0.id==paperID}?.paperConstruction?.insideArtworkSourceID,f.source)
    XCTAssertEqual(try source(f),original,"Consumers retain exactly the original canonical program and artwork")
    XCTAssertNoThrow(try f.engine.project!.validateArtworkLinks())
    let before=f.engine.project
    XCTAssertThrowsError(try f.engine.edit("A solid is not a flat source"){p in
      let i=p.recipes.firstIndex{$0.id==original.recipeID}!;p.recipes[i].parts=[.init("box",["width":"width","height":"2","depth":"depth"])]
    })
    XCTAssertEqual(f.engine.project,before)
    var generated=original;generated.cadModel=definition
    XCTAssertFalse(f.engine.project!.isIndependentFlatArtworkSource(generated))
    generated=original;generated.asset="imported-reference.obj"
    XCTAssertFalse(f.engine.project!.isIndependentFlatArtworkSource(generated))
  }
}
