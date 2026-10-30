import AppKit
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class SVGLazyInsideImportTests: XCTestCase {
  private func fixture(legacy:Bool=false) throws -> (StudioStore,UUID) {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("svg-lazy-inside-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=Project(name:"Blank reverse import")
    var source=ConstructionCommands.example()
    if let index=source.panels.firstIndex(where:{$0.id=="left"}) {source.panels[index].artworkRotationDegrees=180}
    let made=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(source)]) as? [String:Any])
    let id=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(made["object_id"] as? String)))
    let index=try XCTUnwrap(store.engine.project?.objects.firstIndex(where:{$0.id==id}))
    let outside=ArtworkElement(kind:"text",x:7,y:9,width:30,height:10,text:"Outside retained")
    store.engine.project!.objects[index].artwork = .init(background:"#FFFFFF",elements:[outside])
    store.engine.project!.objects[index].paperConstruction!.finishes=[.init(name:"Outside ink",kind:.flatInk,elementIDs:[outside.id],color:"#204A59")]
    if legacy {
      let retained=ArtworkElement(kind:"text",x:20,y:30,width:35,height:12,text:"Legacy reverse")
      var art=Artwork(background:"#EEDDBB",elements:[retained]);art.backgroundOpacity=0;art.bleed=4
      store.engine.project!.objects[index].paperConstruction!.insideArtwork=art
      store.engine.project!.objects[index].paperConstruction!.finishes?.append(.init(name:"Inside foil",kind:.foil,side:.inside,elementIDs:[retained.id],color:"#C49B48"))
    }
    store.showingHome=false;store.mode = .artwork
    store.select(id);store.paperInside=true
    store.activatePaperArtwork(try XCTUnwrap(store.project?.objects.first{$0.id==id}))
    addTeardownBlock { @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root) }
    return(store,id)
  }
  private func projection(_ store:StudioStore,_ id:UUID) throws -> CanvasSourceProjection {
    try XCTUnwrap(store.artworkSession.frames.first{
      $0.projection?.constructionID==id && $0.projection?.inside==true && $0.projection?.panelID=="left"
    }?.projection)
  }
  private var svg:Data {
    Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="12mm" viewBox="0 0 10 12"><rect width="10" height="12" fill="#2355AA"/></svg>"##.utf8)
  }
  func testBlankReverseImportCreatesOnlyInsideSourceInOneUndoAndKeepsReadableFrame() throws {
    let(store,id)=try fixture(),view=try projection(store,id)
    XCTAssertTrue(view.requiresInsideSource)
    let before=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let imported=try SVGImporter.read(svg,name:"Reverse mark")
    let report=try store.commitSVG(imported,data:svg,name:"Reverse mark",targetID:view.sourceID,projection:view)
    let after=try XCTUnwrap(store.project),physical=try XCTUnwrap(after.objects.first{$0.id==id})
    let insideID=try XCTUnwrap(physical.paperConstruction?.insideArtworkSourceID)
    XCTAssertEqual(report["object_id"] as? String,insideID.uuidString)
    XCTAssertNotEqual(insideID,id)
    XCTAssertEqual(after.objects.count,before.objects.count+1)
    XCTAssertEqual(physical.artwork,before.objects.first{$0.id==id}?.artwork)
    XCTAssertEqual(physical.paperConstruction?.finishes,before.objects.first{$0.id==id}?.paperConstruction?.finishes)
    let inside=try XCTUnwrap(after.objects.first{$0.id==insideID}),art=try XCTUnwrap(inside.artwork)
    XCTAssertTrue(inside.canvasSourceOnly==true)
    XCTAssertEqual(art.backgroundOpacity,0)
    XCTAssertEqual(art.elements.count,imported.artwork.elements.count)
    let display=view.display(art),root=try XCTUnwrap(display.elements.first)
    let bounds=display.bounds(of:root)
    XCTAssertEqual(bounds.width,10,accuracy:1e-8);XCTAssertEqual(bounds.height,12,accuracy:1e-8)
    XCTAssertEqual(bounds.x,(view.size.x-10)/2,accuracy:1e-8)
    XCTAssertEqual(bounds.y,(view.size.y-12)/2,accuracy:1e-8)
    store.artworkSession.reconcile()
    XCTAssertEqual(store.artworkSession.objectID,insideID)
    XCTAssertEqual(store.artworkSession.activeFrameID,view.id)
    XCTAssertTrue(store.paperInside)
    XCTAssertFalse(try projection(store,id).requiresInsideSource)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    try store.engine.flush()
    // The project codec stores dates as whole-second ISO8601, while the live
    // import timestamp retains Date() fractions. Compare every persisted field
    // exactly against that codec's state; live Undo/Redo remain exact below.
    let persisted = try JSONDecoder.form.decode([ProductObject].self,from:JSONEncoder.form.encode(after.objects))
    XCTAssertEqual(try store.repository.load(after.id).objects,persisted)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();XCTAssertEqual(store.project,after)
  }
  func testInlineReverseImportPreservesCanonicalIDsMetadataAndFinishAssignments() throws {
    let(store,id)=try fixture(legacy:true),view=try projection(store,id),before=try XCTUnwrap(store.project)
    let physical=try XCTUnwrap(before.objects.first{$0.id==id}),legacy=try XCTUnwrap(physical.paperConstruction?.insideArtwork)
    let imported=try SVGImporter.read(svg,name:"Legacy reverse addition"),undo=store.engine.undoStack.count
    _ = try store.commitSVG(imported,data:svg,name:"Legacy reverse addition",targetID:view.sourceID,projection:view)
    let saved=try XCTUnwrap(store.project?.objects.first{$0.id==id}),insideID=try XCTUnwrap(saved.paperConstruction?.insideArtworkSourceID)
    let art=try XCTUnwrap(store.project?.objects.first{$0.id==insideID}?.artwork)
    XCTAssertNil(saved.paperConstruction?.insideArtwork)
    XCTAssertEqual(art.background,legacy.background);XCTAssertEqual(art.backgroundOpacity,legacy.backgroundOpacity)
    XCTAssertEqual(art.bleed,legacy.bleed)
    for element in legacy.elements {XCTAssertEqual(art.elements.first{$0.id==element.id},element)}
    XCTAssertEqual(saved.artwork,physical.artwork)
    XCTAssertEqual(saved.paperConstruction?.finishes,physical.paperConstruction?.finishes)
    XCTAssertEqual(store.engine.undoStack.count,undo+1)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
  func testLockedPhysicalOwnerAndStaleBlankReviewRejectBeforeAssetsOrSourceMutation() throws {
    let(store,id)=try fixture(),view=try projection(store,id),imported=try SVGImporter.read(svg,name:"Rejected reverse")
    let index=try XCTUnwrap(store.engine.project?.objects.firstIndex{$0.id==id})
    store.engine.project!.objects[index].locked=true
    let locked=try XCTUnwrap(store.project),undo=store.engine.undoStack.count
    let folder=store.repository.url(for:locked.id).appendingPathComponent("Assets")
    let files=Set((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? [])
    XCTAssertThrowsError(try store.commitSVG(imported,data:svg,name:"Rejected reverse",targetID:view.sourceID,projection:view))
    XCTAssertEqual(store.project,locked);XCTAssertEqual(store.engine.undoStack.count,undo)
    XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []),files)
    store.engine.project!.objects[index].locked=false
    _ = try store.engine.call("form_paper",arguments:["command":"ensure_inside","object_id":id.uuidString])
    let changed=try XCTUnwrap(store.project),changedUndo=store.engine.undoStack.count
    XCTAssertThrowsError(try store.commitSVG(imported,data:svg,name:"Stale reverse",targetID:view.sourceID,projection:view))
    XCTAssertEqual(store.project,changed);XCTAssertEqual(store.engine.undoStack.count,changedUndo)
    XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []),files)
  }
}
