import Foundation
import FormCADModel
import XCTest
@testable import FormCore

@MainActor final class LayeredPanelAuthoringTests:XCTestCase {
  private func engine()throws->OperationEngine {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("panel-authoring-"+UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Generic panel primitives");return engine
  }
  private func definition(_ features:SheetPanelFeatures)->PlanarConstructionDefinition {
    .init(name:"Layered display panel",size:.init(128,168),stockThickness:2,
      panels:[.init(id:"panel",name:"Display face",polygon:[.init(14,14),.init(114,14),.init(114,154),.init(14,154)],features:features)],rootPanelID:"panel")
  }
  func testPublicAuthoringAcceptsGenericFeatureDataAndRejectsMisspelledNestedFieldsAtomically()throws {
    let e=try engine(),features=SheetPanelFeatures(wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:10))
    let d=definition(features)
    let result=try XCTUnwrap(e.call("form_construction",arguments:["command":"create","definition":try jsonObject(d)]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["object_id"] as? String)))
    XCTAssertEqual(e.project?.objects.first{$0.id==id}?.paperConstruction?.authored?.panels.first?.features,features)
    let capability=try XCTUnwrap(e.call("form_construction",arguments:["command":"capabilities"]) as? [String:Any])
    XCTAssertTrue((capability["panel_optional_fields"] as? [String] ?? []).contains("features"))
    let accepted=e.project,undo=e.undoStack.count
    var raw=try XCTUnwrap(try jsonObject(d) as? [String:Any])
    var panels=try XCTUnwrap(raw["panels"] as? [[String:Any]])
    panels[0]["features"]=["wrap":["stock":try jsonObject(PaperStock(thicknessMM:0.1)),"turnInMM":10,"cornerRadiusMM":0,"wrong_depth":2]]
    raw["panels"]=panels
    XCTAssertThrowsError(try e.call("form_construction",arguments:["command":"configure","object_id":id.uuidString,"definition":raw]))
    XCTAssertEqual(e.project,accepted);XCTAssertEqual(e.undoStack.count,undo)
  }
  func testExternalInsetSourceCropOwnershipAndLiveViewCyclesValidateBeforePublishing()throws {
    let e=try engine()
    let sourceResult=try XCTUnwrap(e.call("form_add_object",arguments:["recipe_id":"artboard","parameters":["width":60,"depth":70]]) as? [String:Any])
    let sourceID=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(sourceResult["id"] as? String)))
    let sourceArtwork=Artwork(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:2,y:3,width:25,height:35,color:"#336699")],bleed:0)
    _ = try e.call("form_set_artwork",arguments:["object_id":sourceID.uuidString,"artwork":try jsonObject(sourceArtwork)])
    var features=SheetPanelFeatures(recesses:[.init(id:"seat",origin:.init(20,30),size:.init(30,40),depthMM:0.5,
      insert:.init(stock:.init(thicknessMM:0.2),face:.init(sourceObjectID:sourceID)))])
    let result=try XCTUnwrap(e.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition(features))]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(result["object_id"] as? String)))
    let accepted=e.project,undo=e.undoStack.count
    features.recesses![0].insert!.face!.sourceOriginMM = .init(40,50)
    XCTAssertThrowsError(try e.call("form_construction",arguments:["command":"configure","object_id":id.uuidString,"definition":try jsonObject(definition(features))]))
    XCTAssertEqual(e.project,accepted);XCTAssertEqual(e.undoStack.count,undo)
    var image=ArtworkElement(kind:"image",x:0,y:0,width:20,height:20,asset:"existing.png")
    image.objectView = .init(sourceID:id,style:"rendered",linked:true)
    XCTAssertThrowsError(try e.edit("Invalid live inset feedback") {project in
      project.objects[project.objects.firstIndex{$0.id==sourceID}!].artwork!.elements=[image]
    })
    XCTAssertEqual(e.project,accepted)
    image.objectView?.linked=false
    XCTAssertNoThrow(try e.edit("Frozen inset source") {project in
      project.objects[project.objects.firstIndex{$0.id==sourceID}!].artwork!.elements=[image]
    })
  }
  func testOriginalPlyInterfacesAndRecessDepthsShareBoundedPhysicalLayers()throws {
    let stock=PaperStock(thicknessMM:2,plies:[.init(name:"Back",color:"#2244AA",thicknessMM:0.3),.init(name:"Front",color:"#CC4422",thicknessMM:1.7)])
    func resolve(_ depth:Double)throws {
      let feature=SheetPanelFeatures(recesses:[.init(id:"seat",origin:.init(10,10),size:.init(30,40),depthMM:CADScalar(depth))])
      _ = try feature.resolved(size:.init(100,140),stock:stock,variables:[:]){_,_ in nil}
    }
    XCTAssertNoThrow(try resolve(1.7),"A seat at the original ply interface does not create an extra zero-thickness layer.")
    XCTAssertNoThrow(try resolve(1.71),"An exact 0.01 mm remaining colored slice is supported.")
    XCTAssertThrowsError(try resolve(1.705),"A recess cannot demand a subminimum physical slice at a bonded ply interface.")
  }
}
