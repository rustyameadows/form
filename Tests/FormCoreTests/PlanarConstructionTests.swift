import Foundation
import XCTest
import FormCADModel
@testable import FormCore

final class PlanarConstructionTests: XCTestCase {
  private func engine() throws -> OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("authored-construction-"+UUID().uuidString)
    let e=OperationEngine(repository:try ProjectRepository(root:root));e.project=Project(name:"Construction test")
    addTeardownBlock{try? FileManager.default.removeItem(at:root)};return e
  }
  private func create(_ e:OperationEngine,_ definition:PlanarConstructionDefinition = ConstructionCommands.example())throws->UUID {
    let response=try e.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)])
    let result=try XCTUnwrap(response as? [String:Any])
    return try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["object_id"] as? String)))
  }
  func testUnregisteredConstructionCreatesStableGeometryAndEditableControls() throws {
    let e=try engine(),id=try create(e),object=try XCTUnwrap(e.project!.objects.first{$0.id==id})
    XCTAssertEqual(object.paperConstruction?.kind,.authored)
    XCTAssertFalse(Recipe.builtins.contains{$0.id==object.recipeID})
    let net=try PaperConstruction.definition(for:object).net()
    XCTAssertEqual(net.panels.map(\.id),["base","left","right","top"])
    XCTAssertEqual(net.folds.count,3);XCTAssertEqual(net.size,.init(160,110))
    XCTAssertEqual(net.panels[1].artworkRotationDegrees,90)
    XCTAssertEqual(try object.paperConstruction!.resolvedPanels().count,4)
    let inspect=try XCTUnwrap(e.call("form_construction",arguments:["command":"inspect","object_id":id.uuidString]) as? [String:Any])
    _ = try e.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["width":140],"expected_revision":inspect["revision"]!])
    let updated=e.project!.objects.first{$0.id==id}!
    XCTAssertEqual(try PaperConstruction.definition(for:updated).net().size.x,200)
    XCTAssertEqual(e.project!.recipe(object.recipeID)?.parameters.first{$0.id=="width"}?.value,140)
    e.undo();XCTAssertEqual(e.project!.objects.first{$0.id==id},object)
  }
  func testParameterCasesAndRequirementsLeaveAcceptedSourceUntouched() throws {
    let e=try engine();var d=ConstructionCommands.example()
    d.requirements=[.init(id:"relative-depth",lhs:"depth",relation:.lessThan,rhs:"width/2",message:"Depth must fit width")]
    let id=try create(e,d),before=e.project!,undo=e.undoStack.count
    let result=try XCTUnwrap(e.call("form_construction",arguments:["command":"validate_cases","object_id":id.uuidString,
      "cases":[["name":"valid","values":["width":160]],["name":"invalid","values":["width":40,"depth":30]]]]) as? [String:Any])
    XCTAssertEqual(result["passed"] as? Bool,false)
    let cases=try XCTUnwrap(result["cases"] as? [[String:Any]])
    XCTAssertEqual(cases[1]["requirement_id"] as? String,"relative-depth")
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    XCTAssertThrowsError(try e.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["width":40]]))
    XCTAssertEqual(e.project,before)
  }
  func testAuthoredSourceAndCanvasPositionsPersistAndStaleEditsReject() throws {
    let e=try engine(),id=try create(e)
    try e.edit("Positioned projection"){p in p.objects[0].canvasProjectionPositions=["panel:base":.init(-120,70)]}
    try e.flush();let loaded=try e.repository.load(e.project!.id)
    XCTAssertEqual(loaded.objects,e.project!.objects);XCTAssertEqual(loaded.schemaVersion,55)
    XCTAssertThrowsError(try e.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["width":120],"expected_revision":"stale"]))
    XCTAssertThrowsError(try e.edit("Bad position"){p in p.objects[0].canvasProjectionPositions=["panel:base":.init(.infinity,0)]})
    XCTAssertEqual(e.project!.objects,loaded.objects)
  }
  func testInvalidHingesAndCrossingPanelsRejectBeforePublication() throws {
    var d=ConstructionCommands.example();d.hinges[0].parentPanelID="left"
    XCTAssertThrowsError(try d.net())
    d=ConstructionCommands.example();d.hinges[0].start = .init(0,0)
    XCTAssertThrowsError(try d.net())
    d=ConstructionCommands.example();d.panels[0].polygon = [.init(30,30),.init(130,110),.init(130,30),.init(30,110)]
    XCTAssertThrowsError(try d.net())
    let e=try engine(),before=e.project!;XCTAssertThrowsError(try create(e,d));XCTAssertEqual(e.project,before)
  }
  func testHingesNeverBecomeCutsAndFoldChangesPreserveArtwork() throws {
    let e=try engine(),id=try create(e)
    var art=Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:40,y:50,text:"Keep upright",fontSize:12)])
    art.canvasPosition = .init(-100,0)
    try e.edit("Artwork"){p in p.objects[0].artwork=art}
    let before=e.project!.objects[0],net=try PaperConstruction.definition(for:before).net()
    for hinge in net.folds {
      XCTAssertFalse(net.cutEdges.contains{($0.start==hinge.start && $0.end==hinge.end)||($0.end==hinge.start && $0.start==hinge.end)})
    }
    _ = try e.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":["fold":0]])
    let after=e.project!.objects[0];XCTAssertEqual(after.artwork,art)
    XCTAssertNotEqual(try PaperConstruction.definition(for:before).resolvedPanels(),try PaperConstruction.definition(for:after).resolvedPanels())
  }
  func testFabricRecipesShareTheSameParameterRequirementValidation() throws {
    let requirement=CADModelRequirement(id:"allowance-fit",lhs:"allowance*2",relation:.lessThan,rhs:"width",message:"Allowance must fit the source piece")
    let recipe=Recipe("authored-fabric","Fabric piece","square","Shared parameter checks",[
      .init("width","Width",100,10...200),.init("allowance","Seam allowance",10,1...40)],requirements:[requirement])
    XCTAssertNoThrow(try recipe.validate(["width":100,"allowance":10]))
    XCTAssertThrowsError(try recipe.validate(["width":10,"allowance":10]))
    let restored=try JSONDecoder.form.decode(Recipe.self,from:JSONEncoder.form.encode(recipe))
    XCTAssertEqual(restored,recipe)
  }
  private func pair(_ first:[CADExpressionPoint2],_ second:[CADExpressionPoint2],start:CADExpressionPoint2,end:CADExpressionPoint2)->PlanarConstructionDefinition {
    .init(name:"Authored pair",size:.init(20,30),panels:[
      .init(id:"parent",name:"Parent",polygon:first),.init(id:"child",name:"Child",polygon:second)
    ],hinges:[.init(id:"hinge",parentPanelID:"parent",childPanelID:"child",start:start,end:end,angleDegrees:90)],rootPanelID:"parent")
  }
  func testPositiveAreaOverlapRejectsContainedStripAndCoincidentSubdividedPolygons() throws {
    let square:[CADExpressionPoint2]=[.init(0,0),.init(10,0),.init(10,10),.init(0,10)]
    let strip:[CADExpressionPoint2]=[.init(0,0),.init(10,0),.init(10,5),.init(0,5)]
    let subdivided:[CADExpressionPoint2]=[.init(0,0),.init(5,0),.init(10,0),.init(10,10),.init(0,10)]
    for other in [strip,subdivided] {
      XCTAssertThrowsError(try pair(square,other,start:.init(0,0),end:.init(10,0)).net()) {error in
        XCTAssertTrue(error.localizedDescription.contains("overlap"),error.localizedDescription)
      }
    }
  }
  func testFullHingeBoundaryCoverageRejectsGapsThatEndpointsAndMidpointMiss() throws {
    let notched:[CADExpressionPoint2]=[
      .init(0,10),.init(2,10),.init(2,12),.init(4,12),.init(4,10),.init(6,10),
      .init(6,12),.init(8,12),.init(8,10),.init(10,10),.init(10,20),.init(0,20)
    ]
    let child:[CADExpressionPoint2]=[.init(0,0),.init(10,0),.init(10,10),.init(0,10)]
    XCTAssertThrowsError(try pair(notched,child,start:.init(0,10),end:.init(10,10)).net()) {error in
      XCTAssertTrue(error.localizedDescription.contains("both panel boundaries"))
    }
  }
  func testHingeAcrossSubdividedCollinearEdgesDoesNotCreateCuts() throws {
    let parent:[CADExpressionPoint2]=[.init(0,10),.init(5,10),.init(10,10),.init(10,20),.init(0,20)]
    let child:[CADExpressionPoint2]=[.init(0,0),.init(10,0),.init(10,10),.init(6,10),.init(3,10),.init(0,10)]
    let net=try pair(parent,child,start:.init(0,10),end:.init(10,10)).net()
    XCTAssertEqual(net.folds.count,1)
    XCTAssertFalse(net.cutEdges.contains{abs($0.start.y-10)<1e-7 && abs($0.end.y-10)<1e-7})
  }
  func testCaseValidationUsesRequestedPoseAndRejectsInvalidOrUnknownValues() throws {
    let e=try engine(),id=try create(e),before=e.project!,undo=e.undoStack.count
    let report=try XCTUnwrap(e.call("form_construction",arguments:["command":"validate_cases","object_id":id.uuidString,"cases":[
      ["name":"flat","values":["fold":0]], ["name":"assembled","values":["fold":100]],
      ["name":"open","values":["fold":100,"opening":100]], ["name":"invalid","values":["fold":500]],
      ["name":"unknown","values":["notAParameter":1]], ["name":"default","values":[:]]
    ]]) as? [String:Any])
    let cases=try XCTUnwrap(report["cases"] as? [[String:Any]])
    XCTAssertEqual(cases.compactMap{$0["passed"] as? Bool},[true,true,true,false,false,true])
    func matrices(_ index:Int)throws->[[Double]] {
      try XCTUnwrap(cases[index]["poses"] as? [[String:Any]]).map{try XCTUnwrap($0["flatToWorld"] as? [Double])}
    }
    XCTAssertNotEqual(try matrices(0),try matrices(1))
    XCTAssertNotEqual(try matrices(1),try matrices(2))
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    var definition=ConstructionCommands.example();let original=definition
    XCTAssertThrowsError(try definition.setParameters(["width":120,"fold":500]))
    XCTAssertEqual(definition,original)
    XCTAssertThrowsError(try definition.setParameters(["width":120,"unknown":2]))
    XCTAssertEqual(definition,original)
  }
  func testUnknownDefinitionFieldsRejectRecursivelyBeforePublication() throws {
    let e=try engine(),before=e.project!
    let definition=try XCTUnwrap(jsonObject(ConstructionCommands.example()) as? [String:Any])
    var examples:[[String:Any]]=[]
    var raw=definition;raw["stockThikness"]=1;examples.append(raw)
    raw=definition;var size=try XCTUnwrap(raw["size"] as? [String:Any]);size["z"]=1;raw["size"]=size;examples.append(raw)
    raw=definition;var panels=try XCTUnwrap(raw["panels"] as? [[String:Any]]);panels[0]["artworkRotation"]=90;raw["panels"]=panels;examples.append(raw)
    raw=definition;panels=try XCTUnwrap(raw["panels"] as? [[String:Any]]);var polygon=try XCTUnwrap(panels[0]["polygon"] as? [[String:Any]]);polygon[0]["z"]=1;panels[0]["polygon"]=polygon;raw["panels"]=panels;examples.append(raw)
    raw=definition;var hinges=try XCTUnwrap(raw["hinges"] as? [[String:Any]]);hinges[0]["layerOffset"]=1;raw["hinges"]=hinges;examples.append(raw)
    raw=definition;var parameters=try XCTUnwrap(raw["parameters"] as? [[String:Any]]);parameters[0]["max"]=999;raw["parameters"]=parameters;examples.append(raw)
    for value in examples {
      XCTAssertThrowsError(try e.call("form_construction",arguments:["command":"create","definition":value])) {error in
        XCTAssertTrue(error.localizedDescription.contains("Unknown"),error.localizedDescription)
      }
      XCTAssertEqual(e.project,before)
    }
  }
  func testMeasuredFoldAndGlueContactUsesRequestedPoseAndRepairsWithoutEditingAcceptedSource() throws {
    let e=try engine(),id=try create(e,ConstructionCommands.foldAndGlueExample()),before=e.project!,undo=e.undoStack.count
    let inspect=try XCTUnwrap(e.call("form_construction",arguments:["command":"inspect","object_id":id.uuidString]) as? [String:Any])
    XCTAssertEqual(inspect["connections_passed"] as? Bool,true)
    let measured=try XCTUnwrap(inspect["connection_checks"] as? [[String:Any]])
    XCTAssertEqual(measured.count,1);XCTAssertEqual(measured[0]["id"] as? String,"side-contact")
    XCTAssertEqual(try XCTUnwrap(measured[0]["gapMM"] as? Double),0.4,accuracy:1e-7)
    let report=try XCTUnwrap(e.call("form_construction",arguments:["command":"validate_cases","object_id":id.uuidString,"cases":[
      ["name":"closed","values":["fold":100]], ["name":"flat","values":["fold":0]],
      ["name":"bad-angle","values":["seamAngle":-70]], ["name":"repair","values":["seamAngle":-90]]
    ]]) as? [String:Any])
    XCTAssertEqual(report["source_revision"] as? String,inspect["revision"] as? String)
    let cases=try XCTUnwrap(report["cases"] as? [[String:Any]])
    XCTAssertEqual(cases.compactMap{$0["passed"] as? Bool},[true,false,false,true])
    let failed=try XCTUnwrap(cases[2]["connection_checks"] as? [[String:Any]])
    XCTAssertGreaterThan(try XCTUnwrap(failed[0]["gapMM"] as? Double),0.8)
    XCTAssertEqual(e.project,before);XCTAssertEqual(e.undoStack.count,undo)
    var invalid=ConstructionCommands.foldAndGlueExample();invalid.connections![0].firstPoint = .init(0,0)
    XCTAssertThrowsError(try invalid.net())
  }
  private func assertSameGeometry(_ legacy:PaperConstruction,_ authored:PaperConstruction,file:StaticString=#filePath,line:UInt=#line)throws {
    let a=try legacy.net(),b=try authored.net()
    XCTAssertEqual(a.size.x,b.size.x,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(a.size.y,b.size.y,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(a.panels.map(\.id),b.panels.map(\.id),file:file,line:line)
    XCTAssertEqual(a.cutEdges.map(\.id),b.cutEdges.map(\.id),file:file,line:line)
    XCTAssertEqual(a.folds.map(\.id),b.folds.map(\.id),file:file,line:line)
    XCTAssertEqual(a.joins,b.joins,file:file,line:line)
    for (left,right) in zip(a.panels,b.panels) {
      XCTAssertEqual(left.polygon.count,right.polygon.count,file:file,line:line)
      for (p,q) in zip(left.polygon,right.polygon) {
        XCTAssertEqual(p.x,q.x,accuracy:1e-7,file:file,line:line)
        XCTAssertEqual(p.y,q.y,accuracy:1e-7,file:file,line:line)
      }
    }
    for (left,right) in zip(try legacy.resolvedPanels(),try authored.resolvedPanels()) {
      XCTAssertEqual(left.panelID,right.panelID,file:file,line:line)
      for (p,q) in zip(left.flatToWorld,right.flatToWorld){XCTAssertEqual(p,q,accuracy:1e-7,file:file,line:line)}
    }
  }
  func testOrdinaryLegacyExamplesRemainParametricAtChangedDimensionsAndZeroRadius() throws {
    for recipe in ["paperEnvelope","tuckCarton"] {
      let initial=PaperConstructionEngine.defaults(recipeID:recipe)
      let definition=try ConstructionExamples.legacyDefinition(initial)
      XCTAssertFalse(definition.derived?.isEmpty ?? true)
      for edits:[String:Double] in [[:],["width":180,"height":240,"depth":22,"cornerRadius":7],["width":180,"height":240,"depth":22,"cornerRadius":0]] {
        var legacy=PaperConstructionEngine.applying(edits,to:initial),authored=initial
        authored.kind = .authored;authored.authored=definition
        authored=PaperConstructionEngine.applying(edits,to:authored)
        for (fold,opening) in [(0.0,0.0),(45,25),(100,0),(100,100)] {
          legacy.foldPercent=fold;legacy.openingPercent=opening;authored.foldPercent=fold;authored.openingPercent=opening
          try assertSameGeometry(legacy,authored)
        }
      }
    }
  }
  func testExplicitConversionPreservesSourceIDsArtworkAnnotationsAndUndo() throws {
    let e=try engine();var project=e.project!
    var original=try project.makeObject(recipeID:"tuckCarton")
    original.parameters["fold"]=63;original.parameters["opening"]=27
    original.artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:12,y:16,text:"Keep source",fontSize:12)])
    original.canvasProjectionPositions=["panel:front":.init(-200,15),"dieline":.init(40,80)]
    var source=try PaperConstruction.definition(for:original)
    source.annotations=[.init(text:"Preserve the exact edge",panelID:"front",edgeID:"front.cut.0.0",position:.init(3,7))]
    source.insideArtwork = .init(background:"#EEEEEE");source.artworkReferenceSize=try source.net().size
    original.paperConstruction=source;project.objects=[original];e.project=project
    let undo=e.undoStack.count
    _ = try e.call("form_construction",arguments:["command":"convert","object_id":original.id.uuidString])
    let converted=e.project!.objects[0]
    XCTAssertEqual(converted.id,original.id);XCTAssertEqual(converted.designID,original.designID)
    XCTAssertEqual(converted.artwork,original.artwork);XCTAssertEqual(converted.artworkSourceID,original.artworkSourceID)
    XCTAssertEqual(converted.canvasProjectionPositions,original.canvasProjectionPositions)
    XCTAssertEqual(converted.paperConstruction?.annotations,source.annotations)
    XCTAssertEqual(converted.paperConstruction?.insideArtwork,source.insideArtwork)
    XCTAssertEqual(converted.paperConstruction?.artworkReferenceSize,source.artworkReferenceSize)
    XCTAssertEqual(converted.paperConstruction?.artworkReviewRequired,source.artworkReviewRequired)
    XCTAssertEqual(converted.parameters,original.parameters);XCTAssertEqual(e.undoStack.count,undo+1)
    XCTAssertEqual(converted.paperConstruction?.kind,.authored)
    try assertSameGeometry(source,try PaperConstruction.definition(for:converted))
    e.undo();XCTAssertEqual(e.project,project)
    e.redo();XCTAssertEqual(e.project!.objects[0],converted)
  }
}
