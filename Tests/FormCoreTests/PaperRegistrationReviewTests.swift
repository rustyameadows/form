import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class PaperRegistrationReviewTests:XCTestCase {
  private func fixture()throws->(OperationEngine,UUID) {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:directory))
    addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
    engine.project=Project(name:"Registered wrapped material")
    let wrap=SheetPanelWrap(stock:.init(name:"Linen sheet",thicknessMM:0.12,profile:.init(texture:.linen,color:"#274C3D")),turnInMM:"turn",stockThickness:"skin")
    let definition=PlanarConstructionDefinition(name:"Generic wrapped panel",parameters:[.init("core",1.2,0.5...3),.init("turn",5,0...12),.init("skin",0.12,0.05...0.3)],size:.init(100,140),stockThickness:"core",panels:[
      .init(id:"face",name:"Editable face",polygon:[.init(0,0),.init(100,0),.init(100,140),.init(0,140)],features:.init(wrap:wrap))
    ],rootPanelID:"face")
    let result=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let id=try XCTUnwrap((result["object_id"] as? String).flatMap(UUID.init(uuidString:)))
    var artwork=Artwork(background:"#FFFFFF",elements:[.init(kind:"text",x:12,y:14,width:70,height:16,text:"Keep the authored ink",color:"#18382D")],bleed:16)
    artwork.backgroundOpacity=0
    _=try engine.call("form_set_artwork",arguments:["object_id":id.uuidString,"artwork":try jsonObject(artwork)])
    return(engine,id)
  }
  func testMaterialAndMetadataChangesDoNotDemandArtworkReviewAndRemainUndoableAndPersistent()throws {
    let(engine,id)=try fixture(),before=try XCTUnwrap(engine.project),object=try XCTUnwrap(before.objects.first{$0.id==id})
    var definition=try XCTUnwrap(object.paperConstruction?.authored)
    definition.panels[0].name="A clearer surface name"
    definition.panels[0].features!.wrap!.stock.name="Reviewed wrapping stock"
    definition.panels[0].features!.wrap!.stock.profile = .init(texture:.cotton,color:"#F3E6A4",roughness:0.4,textureScaleMM:1.2,textureDepthMM:0.02,opacity:0.9)
    _=try engine.call("form_construction",arguments:["command":"configure","object_id":id.uuidString,"definition":try jsonObject(definition)])
    let after=try XCTUnwrap(engine.project),changed=try XCTUnwrap(after.objects.first{$0.id==id})
    XCTAssertFalse(try XCTUnwrap(changed.paperConstruction).artworkReviewRequired)
    XCTAssertNil(changed.paperConstruction?.artworkReferenceSize)
    XCTAssertEqual(changed.paperConstruction?.authored,definition)
    XCTAssertEqual(changed.artwork,object.artwork);XCTAssertEqual(after.camera,before.camera)
    let restored=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(after))
    XCTAssertEqual(restored.objects,after.objects)
    engine.undo();XCTAssertEqual(engine.project,before)
    engine.redo();XCTAssertEqual(engine.project,after)
  }
  func testEffectiveCoreWrapCaliperAndTurnInChangesStillFlagReviewWithoutChangingArtwork()throws {
    let(engine,id)=try fixture(),before=try XCTUnwrap(engine.project),original=try XCTUnwrap(before.objects.first{$0.id==id})
    for values in [["core":1.4],["skin":0.16],["turn":6.0]] {
      _=try engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":values])
      let after=try XCTUnwrap(engine.project),object=try XCTUnwrap(after.objects.first{$0.id==id})
      XCTAssertTrue(try XCTUnwrap(object.paperConstruction).artworkReviewRequired,"Physical print registration changed: \(values)")
      XCTAssertEqual(object.paperConstruction?.artworkReferenceSize,try original.paperConstruction?.net().size)
      XCTAssertEqual(object.artwork,original.artwork)
      var material=try XCTUnwrap(object.paperConstruction?.authored)
      material.panels[0].features!.wrap!.stock.profile?.roughness=0.5
      _=try engine.call("form_construction",arguments:["command":"configure","object_id":id.uuidString,"definition":try jsonObject(material)])
      XCTAssertTrue(try XCTUnwrap(engine.project?.objects.first{$0.id==id}?.paperConstruction).artworkReviewRequired,"A material edit must retain an outstanding registration review.")
      engine.undo();XCTAssertEqual(engine.project,after)
      engine.undo();XCTAssertEqual(engine.project,before)
    }
  }
}
