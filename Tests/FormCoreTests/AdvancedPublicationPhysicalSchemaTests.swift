import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class AdvancedPublicationPhysicalSchemaTests:XCTestCase {
  private func fixture()throws->(OperationEngine,UUID,UUID) {
    var project=Project(name:"Generic source construction")
    var pages=[UUID]()
    for _ in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
      page.artwork = .init(background:"#FFFFFF",elements:[],bleed:0);page.artwork?.backgroundOpacity=0
      project.objects.append(page);pages.append(page.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Ordered document",pages:pages)
    let source=try SheetAssemblyCommands.createArtworkSource(in:&project,name:"Canonical physical source",size:.init(200,200))
    let definition=SheetAssemblyDefinition(publicationID:publication,stock:.init(thicknessMM:0.12),
      enclosure:[.init(id:"board",name:"Generic wrapped layer",size:.init(100,140),stock:.init(thicknessMM:2),front:.init(sourceObjectID:source,sourceOriginMM:.init(12,12)),features:.init(stockThickness:"2",wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:10),flex:.init(widthMM:20,angleDegrees:10),recesses:[.init(id:"seat",origin:.init(20,20),size:.init(30,40),depthMM:0.5,insert:.init(stock:.init(thicknessMM:0.2),face:.init(sourceObjectID:source)))]))],
      binding:.init(style:.sewn,adhesiveMM:0.1,sewingSwellMM:0.2),
      auxiliaryLeaves:[.init(name:"Attached unnumbered sheet",front:.init(sourceObjectID:source),attachment:.init(planeID:"board",widthMM:8))],
      edgeArtwork:.init(head:.init(sourceObjectID:source),foreEdge:.init(sourceObjectID:source)))
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:directory));engine.project=project
    addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
    return(engine,id,source)
  }
  func testAdvancedSchemaMatchesCompleteTypedSourceAndRejectsNestedTyposWithoutUndo()throws {
    let(engine,id,_)=try fixture(),before=try XCTUnwrap(engine.project)
    let definition=try XCTUnwrap(before.objects.first{$0.id==id}?.sheetAssembly)
    let raw=try XCTUnwrap(jsonObject(definition) as? [String:Any])
    XCTAssertNoThrow(try PublicationPhysicalToolSchema.validateFields(raw,schema:PublicationPhysicalToolSchema.assembly,path:"definition"))
    XCTAssertEqual(try JSONDecoder.form.decode(SheetAssemblyDefinition.self,from:JSONSerialization.data(withJSONObject:raw)),definition)
    var invalid=raw,panels=try XCTUnwrap(raw["enclosure"] as? [[String:Any]])
    var features=try XCTUnwrap(panels[0]["features"] as? [String:Any]);features["fakeRecess"] = 1;panels[0]["features"]=features;invalid["enclosure"]=panels
    XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":invalid]))
    XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    let properties=try XCTUnwrap(PublicationPhysicalToolSchema.assembly["properties"] as? [String:Any])
    XCTAssertEqual((properties["auxiliaryLeaves"] as? [String:Any])?["maxItems"] as? Int,16)
    XCTAssertEqual((properties["enclosure"] as? [String:Any])?["maxItems"] as? Int,128)
    let binding=try XCTUnwrap(PublicationPhysicalToolSchema.binding["properties"] as? [String:Any])
    XCTAssertEqual(Set((binding["style"] as? [String:Any])?["enum"] as? [String] ?? []),Set(SheetBindingStyle.allCases.map(\.rawValue)))
  }
  func testInspectionExposesPhysicalSourcesAndResolvedAllowancesWithoutCopyingArtwork()throws {
    let(engine,id,source)=try fixture(),before=try XCTUnwrap(engine.project)
    let object=try XCTUnwrap(before.objects.first{$0.id==id}),resolved=try before.resolvedSheetAssembly(object)
    let result=try PublicationPhysicalInspection.inspect(project:before,object:object,page:.init(limit:10))
    let measurements=try XCTUnwrap(result["resolved"] as? [String:Any])
    XCTAssertEqual(measurements["text_block_thickness_mm"] as? Double,resolved.textBlockThickness)
    XCTAssertEqual(try XCTUnwrap(measurements["binding_allowance_mm"] as? Double),0.3,accuracy:1e-10)
    XCTAssertEqual(measurements["auxiliary_leaf_count"] as? Int,1)
    XCTAssertEqual((result["auxiliary_leaves"] as? [String:Any])?["total"] as? Int,1)
    XCTAssertTrue((result["source_object_ids"] as? [String] ?? []).contains(source.uuidString))
    let planes=try XCTUnwrap((result["enclosure"] as? [String:Any])?["items"] as? [[String:Any]])
    let authored=try XCTUnwrap(planes[0]["authored"] as? [String:Any])
    XCTAssertNotNil(authored["features"]);XCTAssertNil(authored["artwork"])
    XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
  }
  func testAdhesiveAndSewnConfigurationThroughExistingCommandPreservesAllSourceArtAndUndo()throws {
    let(engine,id,_)=try fixture(),before=try XCTUnwrap(engine.project)
    var definition=try XCTUnwrap(before.objects.first{$0.id==id}?.sheetAssembly)
    definition.binding = .init(style:.adhesive,adhesiveMM:0.25,sewingSwellMM:0)
    _=try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":try jsonObject(definition)])
    let accepted=try XCTUnwrap(engine.project)
    XCTAssertEqual(accepted.objects.filter{$0.id != id},before.objects.filter{$0.id != id});XCTAssertEqual(accepted.publications,before.publications)
    XCTAssertEqual(engine.undoStack.count,1)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(accepted))
    XCTAssertEqual(reopened.objects,accepted.objects);XCTAssertEqual(reopened.publications,accepted.publications);XCTAssertEqual(reopened.textStories,accepted.textStories);XCTAssertEqual(reopened.camera,accepted.camera)
    XCTAssertEqual(try JSONEncoder.form.encode(reopened),try JSONEncoder.form.encode(accepted));try reopened.validateSheetAssemblies()
    engine.undo();XCTAssertEqual(engine.project,before);engine.redo();XCTAssertEqual(engine.project,accepted)
  }
  func testNamedDimensionInputsUseTypedDictionarySchemaAndKeepNestedFieldsStrictAndBounded()throws {
    let reference=PhysicalDimensionReference(sourceObjectID:UUID(),measurement:.spineThickness)
    let binding=PhysicalDimensionBinding(parameter:"width",expression:"spine+5",inputs:["spine":reference])
    let raw=try XCTUnwrap(jsonObject([binding]) as? [[String:Any]])
    XCTAssertEqual(try PhysicalDimensionToolSchema.decodeBindings(raw),[binding])
    var unknown=raw
    var input=try XCTUnwrap(jsonObject(reference) as? [String:Any]);input["inventedMeasurement"]=1
    unknown[0]["inputs"]=["spine":input]
    XCTAssertThrowsError(try PhysicalDimensionToolSchema.decodeBindings(unknown))
    var excessive=raw
    let referenceRaw=try jsonObject(reference)
    excessive[0]["inputs"]=Dictionary(uniqueKeysWithValues:(0..<65).map{("source\($0)",referenceRaw)})
    XCTAssertThrowsError(try PhysicalDimensionToolSchema.decodeBindings(excessive))
    var missing=raw;missing[0]["inputs"]=["spine":["sourceObjectID":reference.sourceObjectID.uuidString]]
    XCTAssertThrowsError(try PhysicalDimensionToolSchema.decodeBindings(missing))
  }

  func testProjectControlRecipeAndCustomCanonicalCoverUseExistingPublicCreateAndParameterUndo()throws {
    let(engine,existing,_)=try fixture(),baseline=try XCTUnwrap(engine.project)
    let publication=try XCTUnwrap(baseline.objects.first{$0.id==existing}?.sheetAssembly?.publicationID)
    let controls=Recipe("authoredLayerControls","Authored layer controls","slider.horizontal.3","Project source dimensions",[.init("boardMM","Board caliper",2,0.5...4,step:0.1)])
    let flat=Recipe("authoredFlatSource","Authored flat source","rectangle","Canonical editable layout",[.init("width","Width",200,20...1000),.init("depth","Height",200,20...1000)])
    for recipe in [controls,flat] {_=try engine.call("form_create_recipe",arguments:["recipe":try jsonObject(recipe)])}
    let added=try XCTUnwrap(engine.call("form_add_object",arguments:["recipe_id":flat.id,"name":"Single editable cover"]) as? [String:Any])
    let source=try XCTUnwrap(added["id"] as? String)
    _=try engine.call("form_set_artwork",arguments:["object_id":source,"artwork":try jsonObject(Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:12,y:12,width:70,height:20,text:"Original source")],bleed:0))])
    let definition=SheetAssemblyDefinition(publicationID:publication,enclosure:[.init(id:"layer",name:"Authored physical layer",size:.init(100,140),front:.init(sourceObjectID:UUID(uuidString:source)!),features:.init(stockThickness:"boardMM"))])
    let created=try XCTUnwrap(engine.call("form_publication",arguments:["command":"sheet_assembly_create","recipe_id":controls.id,"definition":try jsonObject(definition)]) as? [String:Any])
    let id=try XCTUnwrap(created["object_id"] as? String),accepted=try XCTUnwrap(engine.project)
    let assembly=try XCTUnwrap(accepted.objects.first{$0.id.uuidString==id})
    XCTAssertEqual(assembly.recipeID,controls.id);XCTAssertEqual(assembly.parameters,["boardMM":2])
    XCTAssertEqual(try accepted.resolvedSheetAssembly(assembly).enclosure[0].stock.resolvedThicknessMM,2)
    let history=engine.undoStack.count
    _=try engine.call("form_update_object",arguments:["object_id":id,"parameters":["boardMM":2.4]])
    let changed=try XCTUnwrap(engine.project),updated=try XCTUnwrap(changed.objects.first{$0.id==assembly.id})
    XCTAssertEqual(try changed.resolvedSheetAssembly(updated).enclosure[0].stock.resolvedThicknessMM,2.4)
    XCTAssertEqual(changed.objects.first{$0.id.uuidString==source},accepted.objects.first{$0.id.uuidString==source})
    XCTAssertEqual(engine.undoStack.count,history+1);engine.undo();XCTAssertEqual(engine.project,accepted)
    let beforeReject=engine.project
    XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"sheet_assembly_create","recipe_id":"artboard","definition":try jsonObject(definition)]))
    XCTAssertEqual(engine.project,beforeReject);XCTAssertEqual(engine.undoStack.count,history)
  }

  func testDerivedExpressionSchemaMatchesStringMapAndPublicEditsRejectCyclesOrMalformedEntriesAtomically()throws {
    let(engine,id,_)=try fixture(),before=try XCTUnwrap(engine.project)
    var definition=try XCTUnwrap(before.objects.first{$0.id==id}?.sheetAssembly)
    definition.derived=["physicalWidth":"width"]
    definition.enclosure![0].size.x="physicalWidth"
    _=try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":try jsonObject(definition)])
    let accepted=try XCTUnwrap(engine.project),count=engine.undoStack.count
    XCTAssertEqual(accepted.objects.first{$0.id==id}?.sheetAssembly?.derived,definition.derived)
    let properties=try XCTUnwrap(PublicationPhysicalToolSchema.assembly["properties"] as? [String:Any])
    let schema=try XCTUnwrap(properties["derived"] as? [String:Any])
    XCTAssertEqual(schema["maxProperties"] as? Int,256)
    XCTAssertEqual((schema["additionalProperties"] as? [String:Any])?["maxLength"] as? Int,256)
    let object=try XCTUnwrap(accepted.objects.first{$0.id==id})
    let inspection=try PublicationPhysicalInspection.inspect(project:accepted,object:object,page:.init())
    XCTAssertEqual((inspection["authored"] as? [String:Any])?["derived"] as? [String:String],definition.derived)
    var raw=try XCTUnwrap(jsonObject(definition) as? [String:Any])
    for invalid:Any in [["physicalWidth":17],["physicalWidth":"physicalWidth"],["physicalWidth":String(repeating:"1",count:257)],["width":"1"]] {
      raw["derived"]=invalid
      XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":raw]))
      XCTAssertEqual(engine.project,accepted);XCTAssertEqual(engine.undoStack.count,count)
    }
    engine.undo();XCTAssertEqual(engine.project,before)
  }

  func testNeutralCurveToolSchemaUsesFourPointsAndRejectsMalformedTypedDataAtomically()throws {
    let(engine,id,_)=try fixture(),before=try XCTUnwrap(engine.project)
    var raw=try XCTUnwrap(jsonObject(before.objects.first{$0.id==id}!.sheetAssembly!) as? [String:Any])
    var panels=try XCTUnwrap(raw["enclosure"] as? [[String:Any]])
    var features=try XCTUnwrap(panels[0]["features"] as? [String:Any])
    var flex=try XCTUnwrap(features["flex"] as? [String:Any])
    let points:[[String:Any]]=[["x":0,"y":0],["x":6,"y":0],["x":14,"y":0],["x":20,"y":0]]
    flex["angleDegrees"]=0;flex["curve"]=["points":points,"fitLength":false]
    var wrap=try XCTUnwrap(features["wrap"] as? [String:Any]);wrap["stockThickness"]="0.1";features["wrap"]=wrap
    features["flex"]=flex;panels[0]["features"]=features;raw["enclosure"]=panels
    XCTAssertNoThrow(try PublicationPhysicalToolSchema.validateFields(raw,schema:PublicationPhysicalToolSchema.assembly,path:"definition"))
    _=try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":raw])
    let accepted=try XCTUnwrap(engine.project),history=engine.undoStack.count
    XCTAssertEqual(accepted.objects.filter{$0.id != id},before.objects.filter{$0.id != id})
    for invalid:[String:Any] in [["points":Array(points.prefix(3)),"fitLength":false],["points":points,"fitLength":"true"],["points":points,"fitLength":false,"inventedCurve":1]] {
      flex["curve"]=invalid;features["flex"]=flex;panels[0]["features"]=features;raw["enclosure"]=panels
      XCTAssertThrowsError(try engine.call("form_publication",arguments:["command":"sheet_assembly_configure","object_id":id.uuidString,"definition":raw]))
      XCTAssertEqual(engine.project,accepted);XCTAssertEqual(engine.undoStack.count,history)
    }
    engine.undo();XCTAssertEqual(engine.project,before)
  }

}
