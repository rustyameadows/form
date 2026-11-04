import Foundation
import XCTest
@testable import FormCore

final class ConstructionArtworkProjectionTests:XCTestCase {
  private func fixture()throws->(OperationEngine,UUID,UUID,UUID) {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:directory)}
    let engine=OperationEngine(repository:try ProjectRepository(root:directory))
    let front=UUID(),back=UUID()
    var component=PlanarComponentDefinition(id:"material",name:"Physical material",rootPanelID:"upright",anchor:.init(50,60),position:.init(),rotationDegrees:.init(-90,0,0))
    component.front = .init(sourceObjectID:front,sourceOriginMM:.init(17,23));component.back = .init(sourceObjectID:back,sourceOriginMM:.init(31,35))
    var definition=PlanarConstructionDefinition(name:"Offset readable material",parameters:[],size:.init(140,80),stockThickness:0.7,panels:[
      .init(id:"upright",name:"Readable face",polygon:[.init(50,20),.init(130,20),.init(130,60),.init(50,60)],artworkRotationDegrees:90)],rootPanelID:"upright",components:[component])
    definition.version=4
    let original=ArtworkElement(kind:"text",x:20,y:26,text:"Retained source",fontSize:9)
    var project=Project(name:"Canonical piece frames")
    let starter=ConstructionStarter(id:"offset-material",name:"Offset material",definition:definition,stock:.init(thicknessMM:0.7),artworkSources:[
      .init(id:front,name:"Front source",width:150,height:120,artwork:.init(elements:[original])),
      .init(id:back,name:"Reverse source",width:150,height:120,artwork:.init())])
    let imported=try project.importConstructionStarter(starter);engine.project=project
    let object=try XCTUnwrap(project.objects.first{$0.id==imported.objectID}),part=try XCTUnwrap(object.paperConstruction?.authored?.components?.first)
    return(engine,object.id,try XCTUnwrap(part.front?.sourceObjectID),try XCTUnwrap(part.back?.sourceObjectID))
  }
  private func art(_ value:Any)throws->Artwork {try JSONDecoder.form.decode(Artwork.self,from:JSONSerialization.data(withJSONObject:value))}
  func testUprightMCPWritesActualSourceAndInverseRoundTripsInOneUndo()throws {
    let (engine,id,front,back)=try fixture(),before=engine.project!,history=engine.undoStack.count
    let frame:[String:Any]=["surface_id":"upright","side":"outside"]
    let context=try PhysicalArtworkFrameContext.resolve(in:before,objectID:id,raw:frame)
    XCTAssertEqual(context.sourceObjectID,front)
    XCTAssertEqual(context.frame.size.x,40,accuracy:1e-8);XCTAssertEqual(context.frame.size.y,80,accuracy:1e-8)
    let layer=ArtworkElement(kind:"text",x:7,y:9,width:30,height:12,text:"READABLE",color:"#184636",fontSize:11)
    _=try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":frame,"command":"add","elements":[try jsonObject(layer)]])
    XCTAssertEqual(engine.undoStack.count,history+1)
    let canonical=try XCTUnwrap(engine.project?.objects.first{$0.id==front}?.artwork),saved=try XCTUnwrap(canonical.elements.first{$0.id==layer.id})
    let actual=canonical.worldTransform(saved).apply(.init(0,0)),expected=try XCTUnwrap(context.frame.sourceToLocal.inverse).apply(.init(7,9))
    XCTAssertEqual(actual.x,expected.x,accuracy:1e-8);XCTAssertEqual(actual.y,expected.y,accuracy:1e-8)
    let displayed=try art(engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":frame]))
    let visible=try XCTUnwrap(displayed.elements.first{$0.id==layer.id}),transform=visible.affine ?? .init()
    XCTAssertEqual(transform.a,1,accuracy:1e-8);XCTAssertEqual(transform.d,1,accuracy:1e-8)
    XCTAssertEqual(transform.tx,0,accuracy:1e-8);XCTAssertEqual(transform.ty,0,accuracy:1e-8)
    XCTAssertEqual(engine.project?.objects.first{$0.id==id},before.objects.first{$0.id==id});XCTAssertEqual(engine.project?.objects.first{$0.id==back},before.objects.first{$0.id==back})
    engine.undo();XCTAssertEqual(engine.project?.objects,before.objects)
  }
  func testIndependentReverseAndWholePatternUseTheSameCanonicalProjection()throws {
    let (engine,id,front,back)=try fixture(),project=engine.project!,object=try XCTUnwrap(project.objects.first{$0.id==id}),paper=try PaperConstruction.definition(for:object),net=try paper.net()
    let projections=try ConstructionArtworkProjection.resolveAll(in:project,object:object,paper:paper,net:net)
    for descriptor in projections {
      var request:[String:Any]=["component_id":descriptor.componentID,"side":descriptor.inside ? "inside":"outside"]
      if let panel=descriptor.panelID {request["surface_id"]=panel}
      let context=try PhysicalArtworkFrameContext.resolve(in:project,objectID:id,raw:request)
      XCTAssertEqual(context.sourceObjectID,descriptor.inside ? back:front);XCTAssertEqual(context.frame,descriptor.frame)
      XCTAssertFalse(context.requiresInsideSource)
    }
    let local=ArtworkElement(kind:"text",x:5,y:6,text:"BACK")
    _=try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":["component_id":"material","side":"inside"],"command":"add","elements":[try jsonObject(local)]])
    XCTAssertTrue(engine.project!.objects.first{$0.id==back}!.artwork!.elements.contains{$0.id==local.id})
    XCTAssertFalse(engine.project!.objects.first{$0.id==front}!.artwork!.elements.contains{$0.id==local.id})
  }
  func testEmbeddedRegisteredReverseReadIsPureAndEditMigratesInSameUndo()throws {
    let (engine,id,_,_)=try fixture()
    let reference=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(ConstructionCommands.example())]) as? [String:Any])
    let referenceID=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(reference["object_id"] as? String)))
    let retained=ArtworkElement(kind:"text",x:20,y:25,text:"Embedded reverse",fontSize:10)
    try engine.edit("Retain embedded reverse") {project in
      let source=try XCTUnwrap(project.objects.firstIndex{$0.id==referenceID}),target=try XCTUnwrap(project.objects.firstIndex{$0.id==id})
      project.objects[source].paperConstruction!.insideArtwork = .init(background:"#F0E0CC",elements:[retained])
      project.objects[target].paperConstruction!.authored!.components![0].back = .init(sourceObjectID:referenceID,sourceSide:.inside,sourceOriginMM:.init(17,23))
    }
    let before=engine.project!,history=engine.undoStack.count,frame:[String:Any]=["surface_id":"upright","side":"inside"]
    let read=try art(engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":frame]))
    XCTAssertEqual(read.elements.first?.id,retained.id);XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,history)
    let layer=ArtworkElement(kind:"text",x:4,y:7,text:"New reverse")
    _=try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":frame,"command":"add","elements":[try jsonObject(layer)]])
    let migrated=try XCTUnwrap(engine.project?.objects.first{$0.id==referenceID}?.paperConstruction?.insideArtworkSourceID)
    XCTAssertEqual(engine.project!.objects.count,before.objects.count+1);XCTAssertEqual(engine.undoStack.count,history+1)
    XCTAssertNil(engine.project?.objects.first{$0.id==referenceID}?.paperConstruction?.insideArtwork)
    XCTAssertEqual(engine.project?.objects.first{$0.id==migrated}?.artwork?.elements.first{$0.id==retained.id},retained)
    XCTAssertTrue(try art(engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":frame])).elements.contains{$0.id==layer.id})
    engine.undo();XCTAssertEqual(engine.project?.objects,before.objects)
  }
  func testMissingReverseAndWrongComponentDoNotCreateOrEditSources()throws {
    let (engine,id,_,_)=try fixture()
    let index=try XCTUnwrap(engine.project?.objects.firstIndex{$0.id==id});engine.project!.objects[index].paperConstruction!.authored!.components![0].back=nil
    let before=engine.project!,history=engine.undoStack.count
    XCTAssertThrowsError(try engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":["surface_id":"upright","side":"inside"]])) {error in XCTAssertTrue(error.localizedDescription.contains("create_part_artwork"));XCTAssertFalse(error.localizedDescription.contains("ensure_inside"))}
    XCTAssertThrowsError(try engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":["surface_id":"upright","component_id":"missing"]]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,history)
  }
}
