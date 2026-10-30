import AppKit
import FormCADModel
import FormCore
import FormGeometry
import XCTest
@testable import FormApp

@MainActor final class PaperNativeFitTests:XCTestCase {
  private func fixture(narrowOpening:Bool=false)throws->(store:StudioStore,owner:UUID,target:UUID) {
    _ = NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("native-paper-fit-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    store.engine.project=Project(name:"Actual modeled contents fit")
    addTeardownBlock { @MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:directory) }
    let file=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("examples/paper-packaging/04-two-piece-board-box.json")
    var definition=try JSONDecoder.form.decode(PlanarConstructionDefinition.self,from:Data(contentsOf:file))
    if narrowOpening {definition.interiors![0].opening = .init(axis:.y,width:60,height:46,origin:.init(40,27))}
    let response=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let owner=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["object_id"] as? String)))
    var targetID:UUID?
    try store.engine.edit("Placed actual contents fixture"){project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==owner})
      project.objects[index].position = .init(1200,37,-650);project.objects[index].rotation=67
      var target=try project.makeObject(recipeID:"box",name:"Actual watch-sized product",
        parameters:["width":56,"height":20,"depth":44,"corner":0],position:.init(1200,46,-650))
      target.rotation=67
      targetID=target.id;project.objects.append(target)
    }
    return(store,owner,try XCTUnwrap(targetID))
  }
  private func fit(_ store:StudioStore,_ owner:UUID,_ target:UUID,interior:String="base-interior",clearance:Double=1)throws->PaperContentsFitResult {
    // Let expected adapter errors propagate before entering an XCTest unwrap;
    // XCTUnwrap itself records a failure when its autoclosure throws.
    let value=try PaperNativeFit.preflight(store:store,args:["command":"preflight","object_id":owner.uuidString,
      "contents_object_id":target.uuidString,"interior_id":interior,"clearance_mm":clearance])
    let response=try XCTUnwrap(value as? [String:Any])
    let raw=try XCTUnwrap(response["contents_fit"])
    return try JSONDecoder.form.decode(PaperContentsFitResult.self,from:JSONSerialization.data(withJSONObject:raw))
  }
  func testTranslatedRotatedModeledWatchUsesMillimetersAndMovingOutFailsWithoutMutation()throws {
    let (store,owner,target)=try fixture(),before=store.project!,history=store.engine.undoStack.count,selection=store.engine.selection
    let result=try fit(store,owner,target)
    XCTAssertTrue(result.passed);XCTAssertTrue(result.containmentPassed);XCTAssertEqual(result.openingPassed,true)
    XCTAssertEqual(result.sourceObjectID,owner);XCTAssertEqual(result.contentsObjectID,target)
    XCTAssertEqual(result.minimum.x,42,accuracy:0.002);XCTAssertEqual(result.minimum.y,7.2,accuracy:0.002)
    XCTAssertEqual(result.minimum.z,28,accuracy:0.002)
    XCTAssertEqual(result.maximum.x,98,accuracy:0.002);XCTAssertEqual(result.maximum.y,27.2,accuracy:0.002)
    XCTAssertEqual(result.maximum.z,72,accuracy:0.002)
    XCTAssertFalse(try XCTUnwrap(result.sourceRevision).isEmpty);XCTAssertFalse(try XCTUnwrap(result.contentsRevision).isEmpty)
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
    XCTAssertEqual(store.engine.selection,selection)
    var moved=before;let index=try XCTUnwrap(moved.objects.firstIndex{$0.id==target})
    moved.objects[index].position.x+=500;store.engine.project=moved
    let failed=try fit(store,owner,target)
    XCTAssertFalse(failed.passed);XCTAssertFalse(failed.containmentPassed)
    XCTAssertEqual(failed.sourceRevision,result.sourceRevision);XCTAssertNotEqual(failed.contentsRevision,result.contentsRevision)
    XCTAssertEqual(store.project!.objects,moved.objects);XCTAssertEqual(store.engine.undoStack.count,history)
  }
  func testActualWrongOrientationCanFailOpeningWhileStillFittingCavity()throws {
    let (store,owner,target)=try fixture(narrowOpening:true)
    let good=try fit(store,owner,target);XCTAssertTrue(good.passed)
    var rotated=store.project!
    let index=try XCTUnwrap(rotated.objects.firstIndex{$0.id==target})
    rotated.objects[index].rotation+=90;store.engine.project=rotated
    let before=store.project!,history=store.engine.undoStack.count,failed=try fit(store,owner,target)
    XCTAssertTrue(failed.containmentPassed);XCTAssertEqual(failed.openingPassed,false);XCTAssertFalse(failed.passed)
    XCTAssertThrowsError(try fit(store,owner,target,interior:"missing-interior"))
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
  }
  func testPaperContentsBoundsExcludeHiddenHighlightsAndRejectCanvasOnlyTargets()throws {
    let (store,owner,_)=try fixture()
    let definition=PlanarConstructionDefinition(name:"Actual paper contents",size:.init(20,12),stockThickness:0.2,
      panels:[.init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(20,0),.init(20,12),.init(0,12)])],rootPanelID:"sheet")
    let response=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let target=try XCTUnwrap(UUID(uuidString:try XCTUnwrap(response["object_id"] as? String)))
    try store.engine.edit("Placed real paper contents"){project in
      let index=try XCTUnwrap(project.objects.firstIndex{$0.id==target})
      project.objects[index].position = .init(1200,46,-650);project.objects[index].rotation=67
    }
    let before=store.project!,history=store.engine.undoStack.count,object=try XCTUnwrap(before.objects.first{$0.id==target})
    let assets=store.repository.url(for:before.id).appendingPathComponent("Assets")
    let node=GeometryFactory.object(object,project:before,assets:assets,textureLimit:64)
    func descendants(_ node:MeshNode)->[MeshNode] {[node]+node.childNodes.flatMap(descendants)}
    let highlights=descendants(node).filter{$0.name==PaperGeometry.highlightName}
    XCTAssertFalse(highlights.isEmpty);XCTAssertTrue(highlights.allSatisfy(\.isHidden))
    XCTAssertGreaterThan((node.boundingBox.max.z-node.boundingBox.min.z)*100,0.23,
      "The fixture must expose the raw hidden-highlight overshoot that physical measurement excludes")
    let result=try fit(store,owner,target)
    XCTAssertTrue(result.passed)
    XCTAssertEqual(result.maximum.x-result.minimum.x,20,accuracy:0.002)
    XCTAssertEqual(result.maximum.y-result.minimum.y,12,accuracy:0.002)
    XCTAssertEqual(result.maximum.z-result.minimum.z,0.2,accuracy:0.002)
    XCTAssertEqual(store.project!.objects,before.objects);XCTAssertEqual(store.engine.undoStack.count,history)
    var canvasOnly=before;let index=try XCTUnwrap(canvasOnly.objects.firstIndex{$0.id==target})
    canvasOnly.objects[index].canvasSourceOnly=true;store.engine.project=canvasOnly
    XCTAssertThrowsError(try fit(store,owner,target))
    XCTAssertEqual(store.project!.objects,canvasOnly.objects);XCTAssertEqual(store.engine.undoStack.count,history)
    canvasOnly.objects[index].canvasSourceOnly=nil;store.engine.project=canvasOnly
    XCTAssertTrue(try fit(store,owner,target).passed,"Historical nil presentation retains a physical paper target")
  }
}
