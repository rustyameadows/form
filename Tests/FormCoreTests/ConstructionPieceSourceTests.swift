import Foundation
import FormCADModel
import XCTest
@testable import FormCore

@MainActor final class ConstructionPieceSourceTests:XCTestCase {
  private func fixture()throws->(OperationEngine,UUID,UUID) {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try .init(root:directory))
    let sourceID=UUID(),layer=ArtworkElement(kind:"text",x:3,y:4,width:25,height:10,text:"Keep physical type",fontSize:11)
    var component=PlanarComponentDefinition(id:"facing",name:"Facing",rootPanelID:"face",anchor:.init(0,0),stockThickness:0.6)
    component.front = .init(sourceObjectID:sourceID)
    component.finishes=[.init(name:"Lettering",kind:.foil,elementIDs:[layer.id],color:"#C4A66F")]
    var definition=PlanarConstructionDefinition(name:"Independent facing",parameters:[.init("show",1,0...1),.init("span",40,20...100)],
      size:.init("span",30),stockThickness:0.6,panels:[.init(id:"face",name:"Face",polygon:[.init(0,0),.init("span",0),.init("span",30),.init(0,30)])],rootPanelID:"face",components:[component])
    definition.version=4
    let starter=ConstructionStarter(id:"independent-facing",name:"Independent facing",definition:definition,stock:.init(thicknessMM:0.6),
      artworkSources:[.init(id:sourceID,name:"Original lettering",width:40,height:30,artwork:.init(background:"#FFFFFF",elements:[layer]))])
    var project=Project(name:"Physical source guards")
    let imported=try project.importConstructionStarter(starter)
    try project.validateArtworkLinks();engine.project=project
    return(engine,imported.objectID,imported.artworkSourceIDs[0])
  }
  func testPieceCropAndRemovingItsCanonicalSourceRejectAtomically()throws {
    let(engine,owner,source)=try fixture(),before=engine.project,history=engine.undoStack.count
    XCTAssertThrowsError(try engine.call("form_construction",arguments:["command":"parameter","object_id":owner.uuidString,"values":["span":80]]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,history)
    XCTAssertThrowsError(try engine.call("form_delete_objects",arguments:["object_ids":[source.uuidString]]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,history)
  }
  func testMissingFinishMasksRejectAndDisabledPieceRestoresItsSameSources()throws {
    let(engine,owner,source)=try fixture()
    let original=try XCTUnwrap(engine.project),object=try XCTUnwrap(original.objects.first{$0.id==owner})
    var broken=original
    let index=try XCTUnwrap(broken.objects.firstIndex{$0.id==source});broken.objects[index].artwork!.elements=[]
    XCTAssertThrowsError(try broken.validateArtworkLinks())
    var off=try XCTUnwrap(object.paperConstruction?.authored)
    off.components![0].enabled="show"
    // Retained disabled declarations remain typed and keep canonical identities.
    // A live construction must still have an active root, so use a second part.
    off.panels.append(.init(id:"support",name:"Support",polygon:[.init(50,0),.init(60,0),.init(60,10),.init(50,10)]))
    off.size = .init(100,30)
    off.components!.append(.init(id:"support",name:"Support",rootPanelID:"support",anchor:.init(50,0)))
    off.rootPanelID="support"
    _=try engine.call("form_construction",arguments:["command":"configure","object_id":owner.uuidString,"definition":try jsonObject(off)])
    let accepted=try XCTUnwrap(engine.project)
    _=try engine.call("form_construction",arguments:["command":"parameter","object_id":owner.uuidString,"values":["show":0]])
    let disabled=try XCTUnwrap(engine.project?.objects.first{$0.id==owner}?.paperConstruction)
    XCTAssertEqual(try disabled.net().panels.map(\.id),["support"])
    XCTAssertEqual(engine.project?.objects.first{$0.id==source},accepted.objects.first{$0.id==source})
    _=try engine.call("form_construction",arguments:["command":"parameter","object_id":owner.uuidString,"values":["show":1]])
    XCTAssertEqual(engine.project?.objects.first{$0.id==owner}?.paperConstruction?.authored?.components,off.components)
    XCTAssertEqual(engine.project?.objects.first{$0.id==source},accepted.objects.first{$0.id==source})
  }
}
