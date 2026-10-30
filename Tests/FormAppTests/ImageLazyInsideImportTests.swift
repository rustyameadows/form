import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class ImageLazyInsideImportTests:XCTestCase {
  private func fixture() throws -> (StudioStore,UUID,URL) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("image-lazy-inside-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=Project(name:"Reflected image placement")
    let made=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(ConstructionCommands.example())]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(made["object_id"] as? String)))
    let index=try XCTUnwrap(store.engine.project?.objects.firstIndex{$0.id==id})
    let outside=ArtworkElement(kind:"text",x:5,y:7,width:30,height:12,text:"Top retained")
    store.engine.project!.objects[index].artwork = .init(background:"#FFFFFF",elements:[outside])
    store.engine.project!.objects[index].paperConstruction!.finishes=[.init(name:"Top ink",kind:.flatInk,elementIDs:[outside.id],color:"#243E4B")]
    let rep=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:8,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    for y in 0..<8 {for x in 0..<16 {rep.setColor(x<5 ? .red:.blue,atX:x,y:y)}}
    let image=root.appendingPathComponent("asymmetric.png")
    try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:image)
    store.showingHome=false;store.mode = .artwork;store.select(id)
    addTeardownBlock { @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root) }
    return(store,id,image)
  }
  private func activateInsideProof(_ store:StudioStore,_ id:UUID) throws -> CanvasSourceProjection {
    let frame=try XCTUnwrap(store.artworkSession.frames.first{
      $0.projection?.constructionID==id && $0.projection?.inside==true && $0.projection?.isProof==true
    })
    store.artworkSession.activate(frame.id)
    return try XCTUnwrap(frame.projection)
  }
  private func assertUpright(_ session:ArtworkSession,point:Point2,file:StaticString=#filePath,line:UInt=#line) throws {
    let image=try XCTUnwrap(session.primary,file:file,line:line)
    XCTAssertEqual(image.kind,"image",file:file,line:line)
    let transform=session.art.worldTransform(image)
    XCTAssertEqual(transform.a,1,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(transform.d,1,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(transform.b,0,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(transform.c,0,accuracy:1e-8,file:file,line:line)
    let bounds=session.art.bounds(of:image)
    XCTAssertEqual(bounds.center.x,point.x,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(bounds.center.y,point.y,accuracy:1e-8,file:file,line:line)
  }
  func testBlankInsideWholeNetDropCreatesOneSourceAndInverseMapsWithoutChangingTop() throws {
    let(store,id,url)=try fixture(),view=try activateInsideProof(store,id),session=store.artworkSession
    XCTAssertTrue(view.requiresInsideSource)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count,point=Point2(53,67)
    XCTAssertTrue(session.placeImages([url],point:point));XCTAssertNil(store.error)
    let after=try XCTUnwrap(store.project),physical=try XCTUnwrap(after.objects.first{$0.id==id})
    let insideID=try XCTUnwrap(physical.paperConstruction?.insideArtworkSourceID)
    let inside=try XCTUnwrap(after.objects.first{$0.id==insideID}),art=try XCTUnwrap(inside.artwork)
    XCTAssertEqual(after.objects.count,before.objects.count+1)
    XCTAssertEqual(physical.artwork,before.objects.first{$0.id==id}?.artwork)
    XCTAssertEqual(physical.paperConstruction?.finishes,before.objects.first{$0.id==id}?.paperConstruction?.finishes)
    XCTAssertEqual(art.backgroundOpacity,0);XCTAssertTrue(inside.canvasSourceOnly==true)
    XCTAssertEqual(session.objectID,insideID);XCTAssertEqual(session.activeFrameID,view.id);XCTAssertTrue(store.paperInside)
    try assertUpright(session,point:point)
    let element=try XCTUnwrap(art.elements.last),matrix=try XCTUnwrap(element.affine)
    XCTAssertLessThan(matrix.a*matrix.d-matrix.b*matrix.c,0)
    let asset=try XCTUnwrap(element.asset)
    XCTAssertEqual(try Data(contentsOf:session.assets.appendingPathComponent(asset)),try Data(contentsOf:url))
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testExistingInsideWholeNetDropRejectsPhysicalLockAndRetainsSourceOnSuccess() throws {
    let(store,id,url)=try fixture()
    _ = try store.engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString])
    let view=try activateInsideProof(store,id),session=store.artworkSession
    XCTAssertFalse(view.requiresInsideSource)
    let index=try XCTUnwrap(store.engine.project?.objects.firstIndex{$0.id==id})
    store.engine.project!.objects[index].locked=true
    let locked=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let folder=store.repository.url(for:locked.id).appendingPathComponent("Assets")
    let files=Set((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? [])
    XCTAssertFalse(session.placeImages([url],point:.init(61,42)))
    XCTAssertEqual(store.project,locked);XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []),files)
    store.engine.project!.objects[index].locked=false;store.error=nil
    let before=try XCTUnwrap(store.project),insideID=try XCTUnwrap(before.objects[index].paperConstruction?.insideArtworkSourceID)
    XCTAssertTrue(session.placeImages([url],point:.init(61,42)));XCTAssertNil(store.error)
    XCTAssertEqual(store.project?.objects.count,before.objects.count)
    XCTAssertEqual(store.project?.objects[index].paperConstruction?.insideArtworkSourceID,insideID)
    XCTAssertEqual(store.project?.objects[index].artwork,before.objects[index].artwork)
    try assertUpright(session,point:.init(61,42))
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
}
