import XCTest
@testable import FormCore

final class DeskClockDesignTests:XCTestCase {
  func testOutlineHasConstantNormalWallSmoothConvexSymmetryAndRealTaper()throws {
    let p=Project(name:"Clock"),o=try p.makeObject(recipeID:"deskClock"),outer=DeskClockDesign.outline(o),inner=DeskClockDesign.outline(o,inset:3)
    XCTAssertEqual(outer.count,512)
    for i in outer.indices {
      XCTAssertTrue(outer[i].x.isFinite && inner[i].x.isFinite)
      let j=(i+1)%outer.count,k=(i+2)%outer.count,a=outer[i],b=outer[j],c=outer[k]
      XCTAssertGreaterThan((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x),0)
      XCTAssertEqual(hypot(inner[i].x-a.x,inner[i].y-a.y),3,accuracy:0.02)
      XCTAssertLessThan(hypot(b.x-a.x,b.y-a.y),16)
    }
    let upper=outer.filter{$0.y>50}.map{abs($0.x)}.max()!,lower=outer.filter{$0.y < -50}.map{abs($0.x)}.max()!
    XCTAssertLessThan(upper,lower)
  }
  func testLinkedDialPhysicalSurfaceAndSchemaReopenPreserveReferenceSource()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    var p=Project(name:"Reference-led clock"),clock=try p.makeObject(recipeID:"deskClock"),source=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":166])
    source.artwork=Artwork(elements:[.init(kind:"text",x:40,y:10,text:"12",fontSize:36)])
    clock.artworkSourceID=source.id;clock.artworkFit="actual";p.objects=[clock,source]
    let workspace=try p.ensureCanvasWorkspace();p.objects[p.objects.firstIndex{$0.id==workspace.id}!].artwork=Artwork(elements:[.init(kind:"image",x:-290,y:0,width:230,height:230)])
    let art=try XCTUnwrap(p.surfaceArtwork(clock));XCTAssertEqual(art.boundary?.contours.count,2);XCTAssertEqual(clock.artworkSize,.init(180,166));XCTAssertEqual(art.boundary,DeskClockDesign.boundary(clock));XCTAssertNil(source.artwork?.boundary)
    let repo=try ProjectRepository(root:root);try repo.save(p);let q=try repo.load(p.id);XCTAssertEqual(q.schemaVersion,50);XCTAssertEqual(q.objects,p.objects);XCTAssertEqual(q.camera,p.camera)
  }
  func testInvalidClockControlsRejectBeforeSourceMutation()throws {
    XCTAssertThrowsError(try DeskClockDesign.recipe.validate(["hour":1.5]));XCTAssertThrowsError(try DeskClockDesign.recipe.validate(["roundness":10]));XCTAssertThrowsError(try DeskClockDesign.recipe.validate(["wall":Double.nan]))
  }
}
