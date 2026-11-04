import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PaperCutEdgeTests:XCTestCase {
  private func fixture()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("paper-edge-"+UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var project=Project(name:"Independent paper optics");project.objects=[try project.makeObject(recipeID:"paperEnvelope")]
    engine.project=project;addTeardownBlock{try? FileManager.default.removeItem(at:root)};return engine
  }
  private func configure(_ engine:OperationEngine,_ stock:[String:Any])throws {
    _ = try engine.call("form_paper",arguments:["command":"configure","object_id":engine.project!.objects[0].id.uuidString,"stock":stock])
  }
  func testCutEdgeOverrideIsPortableIndependentAndUndoable()throws {
    let engine=try fixture(),before=engine.project!
    try configure(engine,["profile":["appearance":["coat":0.6],"edgeAppearance":["sheen":0.3,"ior":1.46]]])
    let changed=engine.project!,stock=changed.objects[0].paperConstruction!.stock
    XCTAssertEqual(stock.profile?.appearance?.coat,0.6);XCTAssertEqual(stock.profile?.edgeAppearance?.sheen,0.3)
    XCTAssertEqual(changed.minimumSchemaVersion,68);XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(changed.objects[0].parameters,before.objects[0].parameters)
    try engine.flush();XCTAssertEqual(try engine.repository.load(changed.id).objects,changed.objects)
    engine.undo();XCTAssertEqual(engine.project,before);engine.redo();XCTAssertEqual(engine.project,changed)
    try configure(engine,["profile":["edgeAppearance":NSNull()]])
    XCTAssertNil(engine.project!.objects[0].paperConstruction!.stock.profile?.edgeAppearance)
    XCTAssertEqual(engine.project!.objects[0].paperConstruction!.stock.profile?.appearance?.coat,0.6)
  }
  func testNestedUnknownValuesAndUnsupportedUVRejectAtomically()throws {
    let engine=try fixture(),before=engine.project!
    for profile:[String:Any] in [
      ["edgeAppearance":["unknownOptics":1]],
      ["edgeAppearance":["ior":0.1]],
      ["edgeAppearance":["textures":["normal":["asset":"normal.png","sha256":String(repeating:"a",count:64),"colorSpace":"data","uvIndex":1]]]],
      ["edgeAppearance":["textures":["normal":["asset":"normal.png","sha256":String(repeating:"a",count:64),"colorSpace":"data","unknownMapping":1]]]]
    ] {
      XCTAssertThrowsError(try configure(engine,["profile":profile]))
      XCTAssertThrowsError(try configure(engine,["plies":[["name":"Ply","color":"#FFFFFF","thicknessMM":0.35,"profile":profile]]]))
      XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    }
  }
  func testLegacyDecodeAndPlyOverrideDoNotInheritFaceAppearance()throws {
    let old=PaperSurfaceProfile(texture:.cotton,color:"#F4F1E8",roughness:0.8)
    let decoded=try JSONDecoder.form.decode(PaperSurfaceProfile.self,from:JSONEncoder.form.encode(old))
    XCTAssertEqual(old,decoded);XCTAssertNil(decoded.edgeAppearance)
    let engine=try fixture()
    try configure(engine,["profile":["appearance":["coat":0.9],"edgeAppearance":["sheen":0.2]],"plies":[
      ["name":"Back","color":"#222222","thicknessMM":0.15],
      ["name":"Face","color":"#EEEEEE","thicknessMM":0.2,"profile":["edgeAppearance":["sheen":0.7]]]]])
    let stock=engine.project!.objects[0].paperConstruction!.stock
    XCTAssertEqual(stock.resolvedThicknessMM,0.35,accuracy:1e-12)
    XCTAssertNil(stock.plies![0].profile);XCTAssertEqual(stock.plies![1].profile?.edgeAppearance?.sheen,0.7)
    XCTAssertNil(stock.plies![1].profile?.appearance)
    let beforeSave=engine.project!,result=try XCTUnwrap(try engine.call("form_paper",arguments:["command":"save_stock","object_id":engine.project!.objects[0].id.uuidString]) as? [String:Any])
    let saved=try JSONDecoder.form.decode(Material.self,from:JSONSerialization.data(withJSONObject:try XCTUnwrap(result["material"])))
    XCTAssertEqual(saved.paperStock,stock);XCTAssertEqual(result["project_changed"] as? Bool,false)
    XCTAssertEqual(engine.project,beforeSave)
    XCTAssertEqual(StudioLibrary.load(from:engine.repository.root).materials.first{$0.id==saved.id},saved)
    XCTAssertEqual(try JSONDecoder.form.decode(Material.self,from:JSONEncoder.form.encode(saved)),saved)
    XCTAssertEqual(engine.project!.minimumSchemaVersion,68)
  }
  func testMaterialCreationRejectsUnknownNestedEdgeFields()throws {
    let engine=try fixture(),before=engine.project!
    var raw:[String:Any] = ["name":"Reusable cut wall","color":"#EEEEEE","paperStock":["profile":["edgeAppearance":["typo":0.5]]]]
    XCTAssertThrowsError(try engine.call("form_material",arguments:["command":"create","material":raw]))
    XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)
    var stock=PaperStock();stock.profile=PaperSurfaceProfile();stock.profile!.edgeAppearance=PhysicalAppearance();stock.profile!.edgeAppearance!.sheen=0.4
    raw["paperStock"]=try jsonObject(stock);raw["category"]="Paper";raw["thickness"]=stock.resolvedThicknessMM
    _ = try engine.call("form_material",arguments:["command":"create","material":raw])
    XCTAssertEqual(engine.project!.materials.last?.paperStock,stock);XCTAssertEqual(engine.project!.minimumSchemaVersion,68)
  }
  func testCompletePaperDefinitionUsesStrictNestedConstructionAppearanceValidation()throws {
    let engine=try fixture()
    var skin=PaperStock(thicknessMM:0.12,profile:.init());skin.profile!.edgeAppearance=PhysicalAppearance()
    let features=SheetPanelFeatures(wrap:.init(stock:skin,turnInMM:2),recesses:[
      .init(id:"seat",origin:.init(20,20),size:.init(20,20),depthMM:0.5,insert:.init(stock:skin))])
    let source=PlanarConstructionDefinition(name:"Layered source",size:.init(80,60),stockThickness:1,panels:[
      .init(id:"panel",name:"Panel",polygon:[.init(0,0),.init(80,0),.init(80,60),.init(0,60)],features:features)],rootPanelID:"panel")
    _ = try engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(source)])
    let id=try XCTUnwrap(engine.selection.first),before=engine.project!,undo=engine.undoStack.count
    var paper=try PaperConstruction.definition(for:try XCTUnwrap(before.objects.first{$0.id==id}))
    func rawDefinition(invalidInsert:Bool)throws->[String:Any] {
      var raw=try jsonObject(paper) as! [String:Any],authored=raw["authored"] as! [String:Any]
      var panels=authored["panels"] as! [[String:Any]],feature=panels[0]["features"] as! [String:Any]
      var stock=try jsonObject(skin) as! [String:Any],profile=stock["profile"] as! [String:Any]
      profile["edgeAppearance"]=["unknownOptics":1];stock["profile"]=profile
      if invalidInsert {
        var recesses=feature["recesses"] as! [[String:Any]],insert=recesses[0]["insert"] as! [String:Any]
        insert["stock"]=stock;recesses[0]["insert"]=insert;feature["recesses"]=recesses
      }else {var wrap=feature["wrap"] as! [String:Any];wrap["stock"]=stock;feature["wrap"]=wrap}
      panels[0]["features"]=feature;authored["panels"]=panels;raw["authored"]=authored;return raw
    }
    for insert in [false,true] {
      XCTAssertThrowsError(try engine.call("form_paper",arguments:["command":"configure","object_id":id.uuidString,"definition":try rawDefinition(invalidInsert:insert)]))
      XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
    }
    paper.authored!.panels[0].features!.wrap!.stock.profile!.edgeAppearance!.sheen=0.42
    _ = try engine.call("form_paper",arguments:["command":"configure","object_id":id.uuidString,"definition":try jsonObject(paper)])
    let saved=try XCTUnwrap(engine.project!.objects.first{$0.id==id}?.paperConstruction)
    XCTAssertEqual(saved.authored?.panels[0].features?.wrap?.stock.profile?.edgeAppearance?.sheen,0.42)
    XCTAssertEqual(try JSONDecoder.form.decode(PaperConstruction.self,from:JSONEncoder.form.encode(saved)),saved)
    XCTAssertEqual(engine.undoStack.count,undo+1);engine.undo();XCTAssertEqual(engine.project,before)
  }
}
