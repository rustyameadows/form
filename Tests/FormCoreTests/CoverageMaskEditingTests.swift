import XCTest
import FormCore
import FormGraphics

final class CoverageMaskEditingTests:XCTestCase {
  @MainActor func testPickingMaskGroupBeyondThirtyTwoLevelsUsesAcceptedHierarchyBudget()throws {
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:100,height:100);mask.hidden=true;mask.contentSize = .init(100,100)
    var elements=[mask],parent=mask.id,first:UUID?
    for _ in 0..<40 {
      var group=ArtworkElement(kind:"group",x:0,y:0,width:100,height:100);group.contentSize = .init(100,100)
      group.parentID=parent;parent=group.id;if first==nil{first=group.id};elements.append(group)
    }
    var leaf=ArtworkElement(kind:"rectangle",x:5,y:5,width:20,height:20);leaf.parentID=parent;leaf.opacity=0;elements.append(leaf)
    var content=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100);content.clipID=mask.id;content.clipMode="alpha";elements.append(content)
    let art=Artwork(elements:elements);try validateArtwork(art)
    XCTAssertEqual(ArtworkHitTesting.hit(at:.init(x:12,y:12),in:art,scope:mask.id,editingMask:mask.id)?.id,first)
    XCTAssertNil(ArtworkHitTesting.hit(at:.init(x:12,y:12),in:art,scope:mask.id))
  }
  func testMaskScopeIsBoundedToVisibleUnlockedDescendantsDespiteHiddenRoot()throws {
    var mask=ArtworkElement(kind:"group",x:0,y:0,width:100,height:100);mask.hidden=true;mask.opacity=0
    var child=ArtworkElement(kind:"rectangle",x:5,y:5,width:20,height:20);child.parentID=mask.id;child.opacity=0
    var hidden=child;hidden.id=UUID();hidden.hidden=true
    var locked=child;locked.id=UUID();locked.locked=true
    var nested=child;nested.id=UUID()
    var clipped=child;clipped.id=UUID();clipped.clipID=nested.id;clipped.clipMode="alpha"
    var content=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100);content.clipID=mask.id;content.clipMode="luminance"
    let art=Artwork(elements:[mask,child,hidden,locked,nested,clipped,content])
    try validateArtwork(art)
    XCTAssertTrue(art.isCoverageMask(mask.id));XCTAssertTrue(art.isCoverageMask(nested.id))
    XCTAssertEqual(art.editableMaskElementIDs(rootID:mask.id),[mask.id,child.id,clipped.id])
  }
  func testCoverageMaskAppearanceChangesAreAllowedAndOutlineOnlyStillRejects()throws {
    var project=Project(name:"Mask appearance");let owner=try project.ensureCanvasWorkspace()
    var mask=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:20);mask.hidden=true
    var content=ArtworkElement(kind:"rectangle",x:0,y:0,width:30,height:30);content.clipID=mask.id;content.clipMode="alpha"
    try project.setArtwork(.init(elements:[mask,content]),for:owner.id)
    try AppearanceCommands.apply(in:&project,objectID:owner.id,ids:[mask.id],values:["opacity":0.3,"effect_stack":["effects":[["kind":"blur","blur":0.2]]]])
    XCTAssertEqual(project.canvasWorkspace?.artwork?.elements[0].opacity,0.3)
    project.objects[0].artwork!.elements[1].clipMode=nil
    let before=project
    XCTAssertThrowsError(try AppearanceCommands.apply(in:&project,objectID:owner.id,ids:[mask.id],values:["opacity":0.6]))
    XCTAssertEqual(project,before)
  }
}
