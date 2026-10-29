import Foundation
import XCTest
@testable import FormCore

final class PhysicalArtworkFrameTests:XCTestCase {
  private func fixture() throws -> (OperationEngine,UUID,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("physical-frame-"+UUID().uuidString)
    let engine=OperationEngine(repository:try ProjectRepository(root:root));engine.project=Project(name:"Shared physical frame")
    let response=try XCTUnwrap(engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(ConstructionCommands.example())]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["object_id"] as? String)))
    _ = try engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString])
    let inside=try XCTUnwrap(engine.project?.objects.first{$0.id==id}?.paperConstruction?.insideArtworkSourceID)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    return (engine,id,inside)
  }
  private func artwork(_ value:Any) throws -> Artwork {
    try JSONDecoder().decode(Artwork.self,from:JSONSerialization.data(withJSONObject:value))
  }
  func testInsideFrameChangesHandednessOnceAndRoundTripsOneContinuousSource() throws {
    let (engine,id,_)=try fixture(),object=try XCTUnwrap(engine.project?.objects.first{$0.id==id})
    let net=try PaperConstruction.definition(for:object).net(),originalNet=net
    let group=ArtworkElement(kind:"group",x:8,y:9,width:100,height:70)
    var child=ArtworkElement(kind:"rectangle",x:0,y:0,width:net.size.x,height:net.size.y,color:"#245BFF");child.parentID=group.id
    var original=Artwork(background:"#FFFFFF",elements:[group,child]);original.canvasPosition = .init(-70,80)
    for panelID in [nil,"base","left","top"] as [String?] {
      let outside=try PhysicalArtworkFrame.paper(net:net,panelID:panelID)
      let inside=try PhysicalArtworkFrame.paper(net:net,panelID:panelID,inside:true)
      XCTAssertGreaterThan(outside.sourceToLocal.a*outside.sourceToLocal.d-outside.sourceToLocal.b*outside.sourceToLocal.c,0)
      XCTAssertLessThan(inside.sourceToLocal.a*inside.sourceToLocal.d-inside.sourceToLocal.b*inside.sourceToLocal.c,0)
      XCTAssertEqual(try inside.source(from:inside.display(original),original:original),original)
      XCTAssertEqual(inside.display(original).elements[1],child,"Only the shared root transform changes; children/source IDs are retained")
      for point in panelID.flatMap({key in net.panels.first{$0.id==key}?.polygon}) ?? [Point2(0,0),net.size] {
        let front=outside.sourceToLocal.apply(point),back=inside.sourceToLocal.apply(point)
        XCTAssertEqual(back.x,inside.size.x-front.x,accuracy:1e-9);XCTAssertEqual(back.y,front.y,accuracy:1e-9)
      }
    }
    XCTAssertEqual(net,originalNet)
  }
  func testExistingArtworkToolUsesFrameCoordinatesInOneCanonicalUndoAndRawAPIIsUnchanged() throws {
    let (engine,id,insideID)=try fixture()
    let spanning=ArtworkElement(kind:"rectangle",x:0,y:35,width:160,height:15,color:"#245BFF")
    try engine.edit("Continuous inside artwork"){p in try p.setArtwork(.init(background:"#FFFFFF",elements:[spanning]),for:insideID)}
    let before=engine.project!,undo=engine.undoStack.count,element=ArtworkElement(kind:"text",x:7,y:6,width:30,height:10,text:"INSIDE R",fontSize:12)
    let context:[String:Any]=["surface_id":"left","side":"inside"]
    _ = try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":context,"command":"add","elements":[try jsonObject(element)]])
    XCTAssertEqual(engine.undoStack.count,undo+1)
    let canonical=try XCTUnwrap(engine.project?.objects.first{$0.id==insideID}?.artwork)
    XCTAssertEqual(canonical.elements.first{$0.id==spanning.id},spanning)
    let saved=try XCTUnwrap(canonical.elements.first{$0.id==element.id}),transform=try XCTUnwrap(saved.affine)
    XCTAssertLessThan(transform.a*transform.d-transform.b*transform.c,0)
    let local=try artwork(engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":context]))
    let displayed=try XCTUnwrap(local.elements.first{$0.id==element.id}),identity=displayed.affine ?? .init()
    XCTAssertEqual(displayed.text,"INSIDE R");XCTAssertEqual(displayed.x,7);XCTAssertEqual(displayed.y,6)
    XCTAssertEqual(identity.a,1,accuracy:1e-9);XCTAssertEqual(identity.d,1,accuracy:1e-9)
    XCTAssertEqual(identity.b,0,accuracy:1e-9);XCTAssertEqual(identity.c,0,accuracy:1e-9)
    XCTAssertEqual(identity.tx,0,accuracy:1e-9);XCTAssertEqual(identity.ty,0,accuracy:1e-9)
    XCTAssertEqual(try artwork(engine.call("form_get_artwork",arguments:["object_id":insideID.uuidString])),canonical)
    XCTAssertEqual(engine.project?.objects.first{$0.id==id},before.objects.first{$0.id==id})
    try engine.flush();let reopened=try engine.repository.load(before.id)
    XCTAssertEqual(reopened.objects,engine.project?.objects,"Only canonical affine/source associations may be persisted")
    XCTAssertEqual(reopened.objects.count,before.objects.count,"A view never becomes a second saved source")
    engine.undo();XCTAssertEqual(engine.project?.objects,before.objects)
    let raw=ArtworkElement(kind:"text",x:8,y:10,text:"RAW R")
    _ = try engine.call("form_edit_artwork",arguments:["object_id":insideID.uuidString,"command":"add","elements":[try jsonObject(raw)]])
    XCTAssertEqual(engine.project?.objects.first{$0.id==insideID}?.artwork?.elements.last,raw)
  }
  func testFrameErrorsRollbackAndFreshExampleExplicitlyAuthorsInsideParity() throws {
    let (engine,id,_)=try fixture(),before=engine.project!,undo=engine.undoStack.count
    let context:[String:Any]=["surface_id":"left","side":"inside"]
    for command in ["page_setup","transfer","pattern_piece","seam_pair","pattern_template","cut_layout","pattern_tiles"] {
      XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":context,"command":command]))
    }
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":context,"command":"transform","scale_x":-1]))
    XCTAssertThrowsError(try engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":["surface_id":"missing","side":"inside"]]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,undo)
    let sample=try PaperSamples.cosmetics(),object=try XCTUnwrap(sample.objects.first{$0.recipeID=="tuckCarton"})
    let source=try XCTUnwrap(sample.paperArtwork(for:object,inside:true)),net=try PaperConstruction.definition(for:object).net()
    let frame=try PhysicalArtworkFrame.paper(net:net,panelID:"top-tuck",inside:true)
    let canonical=try XCTUnwrap(source.elements.first),visible=try XCTUnwrap(frame.display(source).elements.first)
    XCTAssertLessThan((canonical.affine?.a ?? 1)*(canonical.affine?.d ?? 1)-(canonical.affine?.b ?? 0)*(canonical.affine?.c ?? 0),0)
    let t=visible.affine ?? .init();XCTAssertEqual(t.a,1,accuracy:1e-9);XCTAssertEqual(t.d,1,accuracy:1e-9)
    XCTAssertEqual(visible.text,"A small moment,\njust for you.")
  }
  func testExistingPathToolSharesInsideFrameAndPreservesCanonicalSourceAndOneUndo() throws {
    let (engine,id,insideID)=try fixture(),context:[String:Any]=["surface_id":"left","side":"inside"]
    var path=ArtworkElement(kind:"path",x:7,y:9,width:40,height:30,color:"#245BFF")
    path.rotation=13
    path.path = .init(width:40,height:30,contours:[.init([
      .init(.init(2,3),outgoing:.init(8,1)),.init(.init(37,7),incoming:.init(29,12)),.init(.init(11,26))])])
    _ = try engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"physical_frame":context,"command":"add","elements":[try jsonObject(path)]])
    let before=try XCTUnwrap(engine.project),undo=engine.undoStack.count,node=try XCTUnwrap(path.path?.contours.first?.nodes.first?.id)
    func position(_ art:Artwork) throws -> Point2 {
      let element=try XCTUnwrap(art.elements.first{$0.id==path.id}),shape=try XCTUnwrap(element.path)
      let anchor=try XCTUnwrap(shape.contours.flatMap(\.nodes).first{$0.id==node}?.anchor)
      return art.worldTransform(element).followed(by:.scale(element.width/shape.width,element.height/shape.height)).apply(anchor)
    }
    let displayed=try artwork(engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":context])),p=try position(displayed)
    var args:[String:Any]=["object_id":id.uuidString,"physical_frame":context,"element_id":path.id.uuidString,
      "operation":"transform","node_ids":[node.uuidString],"matrix":["tx":2.0,"ty":-1.0]]
    _ = try engine.call("form_edit_path",arguments:args)
    let result=try artwork(engine.call("form_get_artwork",arguments:["object_id":id.uuidString,"physical_frame":context])),q=try position(result)
    XCTAssertEqual(q.x,p.x+2,accuracy:1e-8);XCTAssertEqual(q.y,p.y-1,accuracy:1e-8)
    XCTAssertEqual(result.elements.first?.path?.contours.flatMap(\.nodes).map(\.id),path.path?.contours.flatMap(\.nodes).map(\.id))
    XCTAssertEqual(engine.undoStack.count,undo+1)
    XCTAssertEqual(engine.project?.objects.first{$0.id==id},before.objects.first{$0.id==id})
    let canonical=try artwork(engine.call("form_get_artwork",arguments:["object_id":insideID.uuidString]))
    let transform=try XCTUnwrap(canonical.elements.first?.affine)
    XCTAssertLessThan(transform.a*transform.d-transform.b*transform.c,0)
    try engine.flush();XCTAssertEqual(try engine.repository.load(before.id).objects,engine.project?.objects)
    engine.undo();XCTAssertEqual(engine.project?.objects,before.objects)
    let rawBefore=try artwork(engine.call("form_get_artwork",arguments:["object_id":insideID.uuidString])),r=try position(rawBefore)
    args["object_id"]=insideID.uuidString;args.removeValue(forKey:"physical_frame")
    _ = try engine.call("form_edit_path",arguments:args)
    let rawAfter=try artwork(engine.call("form_get_artwork",arguments:["object_id":insideID.uuidString])),s=try position(rawAfter)
    XCTAssertEqual(s.x,r.x+2,accuracy:1e-8);XCTAssertEqual(s.y,r.y-1,accuracy:1e-8)
    engine.undo();XCTAssertEqual(engine.project?.objects,before.objects)
    args["object_id"]=id.uuidString;args["physical_frame"]=["surface_id":"missing","side":"inside"]
    XCTAssertThrowsError(try engine.call("form_edit_path",arguments:args));XCTAssertEqual(engine.project?.objects,before.objects)
  }
}
