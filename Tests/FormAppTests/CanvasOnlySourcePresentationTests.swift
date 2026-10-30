import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasOnlySourcePresentationTests:XCTestCase {
  func testInsideSourceStaysEditableOnCanvasWithoutTableNodeOrFindTarget()throws {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("inside-source-native-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    defer{store.artworkSession.canvas?.finishText();store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    var p=Project(name:"Inside source presentation")
    let paper=try p.makeObject(recipeID:"paperEnvelope"),legacy=try p.makeObject(recipeID:"artboard",position:.init(-500,0,0))
    p.objects=[paper,legacy];store.engine.project=p;store.showingHome=false
    let response=try XCTUnwrap(store.engine.call("form_paper",arguments:["command":"ensure_inside","object_id":paper.id.uuidString]) as? [String:Any])
    let sourceID=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["inside_source_id"] as? String)))
    store.select(paper.id)
    let scene=TableSceneController(store:store),view=TableSceneView(frame:.init(x:0,y:0,width:800,height:600))
    view.controller=scene;scene.view=view;store.scene=scene;store.synchronizeScene()
    XCTAssertNotNil(scene.logicalNode(for:paper.id));XCTAssertNotNil(scene.logicalNode(for:legacy.id))
    XCTAssertNil(scene.logicalNode(for:sourceID))
    let before=store.project!,history=store.engine.undoStack.count,camera=scene.camera,selection=store.engine.selection
    store.artworkSession.activate(sourceID);store.artworkSession.reconcile()
    XCTAssertEqual(store.artworkSession.objectID,sourceID)
    XCTAssertTrue(store.artworkSession.activeProjection?.inside == true)
    XCTAssertTrue(store.artworkSession.frames.contains{$0.projection?.sourceID==sourceID})
    XCTAssertFalse(store.findOnTable(sourceID))
    XCTAssertEqual(store.engine.selection,selection);XCTAssertEqual(scene.camera,camera)
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
    let text=ArtworkElement(kind:"text",x:20,y:30,width:60,height:12,text:"Canonical inside text",fontSize:10)
    store.artworkSession.add([text])
    let edited=try XCTUnwrap(store.project!.objects.first{$0.id==sourceID})
    XCTAssertTrue(edited.artwork?.elements.contains{$0.id==text.id && $0.text==text.text} == true)
    XCTAssertEqual(edited.canvasSourceOnly,true);XCTAssertFalse(edited.hasTablePresentation)
    XCTAssertEqual(store.engine.undoStack.count,history+1)
    store.synchronizeScene();XCTAssertNil(scene.logicalNode(for:sourceID))
    XCTAssertEqual(try StudioVisibility().resolved(in:store.project!),[paper.id,legacy.id])
    try store.engine.flush();let reopened=try store.repository.load(p.id)
    XCTAssertEqual(reopened.objects,store.project!.objects);XCTAssertEqual(reopened.physicalObjectCount,2)
  }
}
