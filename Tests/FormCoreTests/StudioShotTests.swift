import XCTest
@testable import FormCore

final class StudioShotTests:XCTestCase {
  func fixture()throws->OperationEngine {
    let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:url)}
    let engine=OperationEngine(repository:try ProjectRepository(root:url));var p=Project(name:"Shots")
    p.objects=[try p.makeObject(recipeID:"box")];p.camera.viewportAspect=1.5;engine.project=p;return engine
  }
  func call(_ e:OperationEngine,_ command:String,_ extra:[String:Any]=[:])throws->Any {try e.call("form_set_view",arguments:["view":"studio","studio_command":command].merging(extra){_,new in new})}
  func testCaptureUpdateRenameDeleteUndoAndPersistentReopenPreserveSource()throws {
    let e=try fixture(),before=e.project!,digest=try before.studioDesignDigest()
    _=try call(e,"capture",["name":"Hero","lighting":"rim-v1"]);let captured=e.project!,shot=captured.studioPresentation!.shots[0]
    XCTAssertEqual(captured.objects,before.objects);XCTAssertEqual(try captured.studioDesignDigest(),digest);XCTAssertEqual(e.undoStack.count,1);XCTAssertEqual(captured.schemaVersion,43)
    for op in ["list","get"] {_=try call(e,op,["shot_id":shot.id.uuidString])};XCTAssertEqual(e.project,captured);XCTAssertEqual(e.undoStack.count,1)
    _=try call(e,"rename",["shot_id":shot.id.uuidString,"name":"Detail"]);XCTAssertEqual(e.project!.studioPresentation!.shots[0].id,shot.id);XCTAssertEqual(e.project!.studioPresentation!.shots[0].revision,2)
    _=try call(e,"update",["shot_id":shot.id.uuidString,"width":2000,"height":3000]);XCTAssertEqual(e.project!.studioPresentation!.shots[0].pixels,.init(width:2000,height:3000));XCTAssertEqual(e.project!.objects,before.objects)
    try e.flush();XCTAssertEqual(try e.repository.load(before.id),try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(e.project!)))
    let edited=e.project!;_=try call(e,"delete",["shot_id":shot.id.uuidString]);XCTAssertNil(e.project!.studioPresentation)
    e.undo();XCTAssertEqual(e.project,edited);e.undo();e.undo();XCTAssertEqual(e.project,captured);e.undo();XCTAssertEqual(e.project,before)
  }
  func testVisibilityIsExactMissingSourceIsReportedAndDeletionRemainsValid()throws {
    let e=try fixture();var p=e.project!;let other=try p.makeObject(recipeID:"box");p.objects.append(other);_=try p.ensureCanvasWorkspace();e.project=p
    let v=StudioVisibility(mode:.objects,objectIDs:[other.id]);XCTAssertEqual(try v.resolved(in:p),[other.id])
    _=try call(e,"capture",["visibility":try jsonObject(v)]);let shot=e.project!.studioPresentation!.shots[0]
    try e.edit("Delete subject"){$0.objects.removeAll{$0.id==other.id}}
    XCTAssertThrowsError(try shot.visibility.resolved(in:e.project!));try e.project!.validateArtworkLinks()
    XCTAssertThrowsError(try StudioVisibility(mode:.objects,objectIDs:[p.canvasWorkspace!.id]).resolved(in:p))
    XCTAssertEqual(try StudioVisibility().resolved(in:p),Set([p.objects[0].id,other.id]))
  }
  func testAtomicArgumentBoundsAndUnknownOperationFailures()throws {
    let e=try fixture(),p=e.project!
    for values:[String:Any] in [["width":true,"height":2000],["width":3000.5,"height":2000],["width":8192,"height":8192],["width":3000],["lighting":"pretend-v1"],["reference_aspect":true],["unexpected":1]] {
      XCTAssertThrowsError(try call(e,"capture",values));XCTAssertEqual(e.project,p);XCTAssertTrue(e.undoStack.isEmpty)
    }
    XCTAssertThrowsError(try call(e,"typo"));XCTAssertEqual(e.project,p)
    var s=StudioShot(name:"Bad",camera:p.camera,referenceAspect:1.5);s.camera.orientation = .init(x:0,y:0,z:0,w:0);XCTAssertThrowsError(try s.validate())
    s.camera=p.camera;s.camera.distance=1000;XCTAssertNoThrow(try s.validate()) // valid whole-project fit can exceed interactive zoom cap
  }
  func testReferenceProjectionContainsSourceExactlyAndDoesNotChangeRawPose()throws {
    let e=try fixture();var c=e.project!.camera;c.projection="orthographic";c.target = .init(12,3,-7);c.distance=35
    var shot=StudioShot(name:"Top",camera:c,referenceAspect:1.5)
    shot.pixels = .init(width:2000,height:3000);XCTAssertEqual(shot.expansion,2.25,accuracy:1e-12)
    XCTAssertEqual(shot.camera,c);shot.pixels = .init(width:3000,height:2000);XCTAssertEqual(shot.expansion,1);XCTAssertEqual(shot.outputFieldOfView,39,accuracy:1e-12)
  }
  func testNoOpEditsAndReadClassificationAreExact()throws {
    let e=try fixture();_=try call(e,"capture");let s=e.project!.studioPresentation!.shots[0],p=e.project!
    _=try call(e,"rename",["shot_id":s.id.uuidString,"name":s.name]);_=try call(e,"update",["shot_id":s.id.uuidString]);XCTAssertEqual(e.project,p);XCTAssertEqual(e.undoStack.count,1)
    XCTAssertTrue(StudioShotCommands.isInspection(["view":"studio","studio_command":"get"]));XCTAssertFalse(StudioShotCommands.isInspection(["view":"studio","studio_command":"capture"]))
    XCTAssertFalse(StudioShotCommands.isInspection(["view":"table","studio_command":"get"]))
  }
}
