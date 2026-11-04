import Foundation
import XCTest
@testable import FormCore

final class ConstructionPartCommandsTests:XCTestCase {
  private func engine()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Source editing")
    return engine
  }
  private func fixture()throws->ConstructionStarter {
    var starter=try XCTUnwrap(ConstructionStarterCatalog.bundled().starters.first{$0.id=="independent-cut-parts"})
    let id=UUID(),layer=ArtworkElement(kind:"text",x:4,y:5,text:"Independent ink",color:"#112233",fontSize:9)
    starter.definition.components![0].front = .init(sourceObjectID:id)
    starter.artworkSources=[.init(id:id,name:"Canonical ink",width:"width",height:"height",artwork:.init(background:"#FFFFFF",elements:[layer]))]
    return starter
  }
  func testCatalogIsReadOnlyAndInlineImportIsOneUndoWithFreshSources()throws {
    let engine=try engine(),before=engine.project!,history=engine.undoStack.count
    let catalog=try XCTUnwrap(engine.call("form_construction",arguments:["command":"starters"]) as? [String:Any])
    XCTAssertFalse(try XCTUnwrap(catalog["starters"] as? [[String:Any]]).isEmpty)
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,history)
    let starter=try fixture(),report=try XCTUnwrap(engine.call("form_construction",arguments:["command":"add_starter","starter":try jsonObject(starter),"position":[12,0,18],"name":"New assembly"]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(report["object_id"] as? String)))
    let owner=try XCTUnwrap(engine.project?.objects.first{$0.id==id})
    XCTAssertEqual(owner.name,"New assembly");XCTAssertEqual(owner.position,.init(12,0,18))
    XCTAssertNotEqual(owner.paperConstruction?.authored?.components?.first?.front?.sourceObjectID,starter.artworkSources.first?.id)
    XCTAssertEqual((report["parts"] as? [[String:Any]])?.count,1)
    XCTAssertNotNil(report["closed_envelope"]);XCTAssertEqual(engine.undoStack.count,history+1)
    engine.undo();XCTAssertEqual(engine.project!.objects,before.objects);XCTAssertEqual(engine.project!.recipes,before.recipes)
    engine.redo();XCTAssertEqual(engine.project?.objects.first?.id,id)
  }
  func testUnknownNestedV4FieldsRejectBeforePublication()throws {
    let engine=try engine(),before=engine.project!,raw=try XCTUnwrap(jsonObject(fixture().definition) as? [String:Any])
    var invalid=[[String:Any]]()
    var value=raw;var controls=try XCTUnwrap(value["controls"] as? [String:Any]);var parameters=try XCTUnwrap(controls["parameters"] as? [[String:Any]])
    parameters[0]["stepp"]=1;controls["parameters"]=parameters;value["controls"]=controls;invalid.append(value)
    value=raw;var components=try XCTUnwrap(value["components"] as? [[String:Any]]),stock=try XCTUnwrap(components[0]["stock"] as? [String:Any])
    var profile=try XCTUnwrap(stock["profile"] as? [String:Any]);profile["fiberLength"]=9;stock["profile"]=profile;components[0]["stock"]=stock;value["components"]=components;invalid.append(value)
    value=raw;var groups=try XCTUnwrap(value["groups"] as? [[String:Any]]);groups[0]["positionXYZ"]=[0,0,0];value["groups"]=groups;invalid.append(value)
    value=raw;var production=try XCTUnwrap(value["production"] as? [String:Any]);var materials=try XCTUnwrap(production["materials"] as? [[String:Any]])
    materials[0]["gutterMM"]=10;production["materials"]=materials;value["production"]=production;invalid.append(value)
    value=raw;value["jointAttachments"]=[["id":"review","joinID":"review","tape":["unexpectedTapeProperty":true]]];invalid.append(value)
    value=raw;value["jointAttachments"]=[["id":"review","joinID":"review","staples":[["unexpectedStapleProperty":true]]]];invalid.append(value)
    for definition in invalid {
      XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"create","definition":definition]))
      XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    }
  }
  func testInlineStarterCannotBypassSourceOrArtworkFieldValidation()throws {
    let engine=try engine(),before=engine.project!,raw=try XCTUnwrap(jsonObject(fixture()) as? [String:Any])
    var invalid=[[String:Any]]()
    var value=raw;var definition=try XCTUnwrap(value["definition"] as? [String:Any]);definition["inventedSourceProperty"]=true;value["definition"]=definition;invalid.append(value)
    value=raw;var sources=try XCTUnwrap(value["artworkSources"] as? [[String:Any]]);sources[0]["printScale"]=2;value["artworkSources"]=sources;invalid.append(value)
    value=raw;sources=try XCTUnwrap(value["artworkSources"] as? [[String:Any]]);var artwork=try XCTUnwrap(sources[0]["artwork"] as? [String:Any]);var elements=try XCTUnwrap(artwork["elements"] as? [[String:Any]])
    elements[0]["fontSise"]=10;artwork["elements"]=elements;sources[0]["artwork"]=artwork;value["artworkSources"]=sources;invalid.append(value)
    value=raw;sources=try XCTUnwrap(value["artworkSources"] as? [[String:Any]]);artwork=try XCTUnwrap(sources[0]["artwork"] as? [String:Any]);artwork["inventedNullProperty"]=NSNull();sources[0]["artwork"]=artwork;value["artworkSources"]=sources;invalid.append(value)
    for starter in invalid {
      XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"add_starter","starter":starter]))
      XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    }
    XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"add_starter","starter":raw,"starter_id":"independent-cut-parts"]))
  }
  func testExplicitAdoptionAndNewBackSourceRetainIdentityAndUndo()throws {
    let engine=try engine(),created=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(ConstructionCommands.multiComponentExample())]) as? [String:Any])
    let id=try XCTUnwrap(created["object_id"] as? String),before=engine.project!,owner=try XCTUnwrap(before.objects.first),original=try XCTUnwrap(owner.paperConstruction?.authored)
    XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"adopt_parts","object_id":id,"expected_revision":"stale"]))
    XCTAssertEqual(engine.project,before)
    let adopted=try XCTUnwrap(engine.call("form_construction",arguments:["command":"adopt_parts","object_id":id,"expected_revision":try ConstructionSourceEditing.revision(original)]) as? [String:Any])
    let current=try XCTUnwrap(engine.project?.objects.first{$0.id==owner.id}),definition=try XCTUnwrap(current.paperConstruction?.authored)
    XCTAssertEqual(definition.version,4);XCTAssertEqual(definition.panels.map(\.id),original.panels.map(\.id));XCTAssertEqual(current.id,owner.id);XCTAssertEqual(current.artwork,owner.artwork)
    let prior=engine.project!,history=engine.undoStack.count
    let source=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create_part_artwork","object_id":id,"component_id":"first","side":"inside","expected_revision":adopted["revision"]!]) as? [String:Any])
    XCTAssertNotNil(source["artwork_source_id"]);XCTAssertEqual(engine.project!.objects.count,prior.objects.count+1);XCTAssertEqual(engine.undoStack.count,history+1)
    engine.undo();XCTAssertEqual(engine.project!.objects,prior.objects);engine.undo();XCTAssertEqual(engine.project!.objects,before.objects)
  }
  func testExplosionPoseIsIndependentAndInvalidPoseIsAtomic()throws {
    let engine=try engine(),report=try XCTUnwrap(engine.call("form_construction",arguments:["command":"add_starter","starter":try jsonObject(fixture())]) as? [String:Any])
    let id=try XCTUnwrap(report["object_id"] as? String),before=engine.project!,owner=try XCTUnwrap(before.objects.first)
    _=try engine.call("form_construction",arguments:["command":"parameter","object_id":id,"values":["explosion":65]])
    let changed=try XCTUnwrap(engine.project?.objects.first{$0.id==owner.id})
    XCTAssertEqual(changed.paperConstruction?.explosionPercent,65);XCTAssertEqual(changed.artwork,owner.artwork)
    XCTAssertEqual(changed.paperConstruction?.authored,owner.paperConstruction?.authored)
    let accepted=engine.project!,history=engine.undoStack.count
    XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"parameter","object_id":id,"values":["explosion":101]]))
    XCTAssertEqual(engine.project,accepted);XCTAssertEqual(engine.undoStack.count,history)
  }
  func testLegacyDefinitionsRejectEvenEmptyVersionFourDeclarations()throws {
    let engine=try engine(),before=engine.project!,original=try XCTUnwrap(jsonObject(ConstructionCommands.multiComponentExample()) as? [String:Any])
    var withGroups=original;withGroups["groups"]=[]
    var withStock=original,components=try XCTUnwrap(original["components"] as? [[String:Any]])
    components[0]["stock"]=NSNull();withStock["components"]=components
    for definition in [withGroups,withStock] {
      XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"create","definition":definition]))
      XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    }
  }
  func testNewArtworkUsesOnlyTwoDimensionAliasesAndReusesThemForBack()throws {
    var starter=try XCTUnwrap(ConstructionStarterCatalog.bundled().starters.first{$0.id=="independent-cut-parts"})
    let current=starter.definition.derived?.count ?? 0
    for index in current..<254 {if starter.definition.derived==nil{starter.definition.derived=[:]};starter.definition.derived!["reservedDimension\(index)"] = .init(Double(index))}
    var project=Project(name:"Bounded source dimensions");let result=try project.importConstructionStarter(starter)
    let owner=try XCTUnwrap(project.objects.first{$0.id==result.objectID}),definition=try XCTUnwrap(owner.paperConstruction?.authored),component=try XCTUnwrap(definition.components?.first)
    let front=try project.createConstructionPartArtwork(objectID:owner.id,componentID:component.id,side:.outside,expectedRevision:ConstructionSourceEditing.revision(definition))
    var accepted=try XCTUnwrap(project.objects.first{$0.id==owner.id}?.paperConstruction?.authored)
    XCTAssertEqual(accepted.derived?.count,256)
    let back=try project.createConstructionPartArtwork(objectID:owner.id,componentID:component.id,side:.inside,expectedRevision:ConstructionSourceEditing.revision(accepted))
    accepted=try XCTUnwrap(project.objects.first{$0.id==owner.id}?.paperConstruction?.authored)
    XCTAssertNotEqual(front,back);XCTAssertEqual(accepted.derived?.count,256)
    let before=project;try accepted.setParameters(["width":145])
    if let index=project.objects.firstIndex(where:{$0.id==owner.id}) {project.objects[index].paperConstruction!.authored=accepted;project.objects[index].parameters["width"]=145}
    try project.reconcilePhysicalDimensions(previous:before)
    XCTAssertEqual(project.objects.first{$0.id==front}?.parameters["width"],145)
    XCTAssertEqual(project.objects.first{$0.id==back}?.parameters["width"],145)
  }
}
