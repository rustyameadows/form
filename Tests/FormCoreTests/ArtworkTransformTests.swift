import XCTest
@testable import FormCore

final class ArtworkTransformTests: XCTestCase {
  private func shape() -> ArtworkElement {
    .init(kind:"rectangle",x:12,y:18,width:40,height:20,color:"#AA5533")
  }
  private func assertPoint(_ actual:Point2,_ expected:Point2,
    file:StaticString = #filePath,line:UInt = #line) {
    XCTAssertEqual(actual.x,expected.x,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(actual.y,expected.y,accuracy:1e-8,file:file,line:line)
  }
  func testChangingAndResettingOriginNeverChangesAppearanceOrBounds() throws {
    let e = shape(); var art = Artwork(elements:[e]); let original = art
    for point in [Point2(0,0),.init(1,1),.init(-0.5,1.5)] {
      try ArtworkCommands.apply("origin",to:&art,ids:[e.id],arguments:["origin":["x":point.x,"y":point.y]])
      XCTAssertEqual(art.elements[0].localTransform,e.localTransform)
      XCTAssertEqual(art.bounds(of:art.elements[0]),original.bounds(of:e))
      XCTAssertEqual(art.renderDefinition,original.renderDefinition)
      XCTAssertEqual(art.elements[0].transformOrigin,point)
    }
    try ArtworkCommands.apply("origin",to:&art,ids:[e.id],arguments:["origin":NSNull()])
    XCTAssertEqual(art,original)
  }
  func testEveryReferencePointStaysFixedDuringRotationAndPositiveScaling() throws {
    for x in [0.0,0.5,1] { for y in [0.0,0.5,1] {
      var e = shape(); e.transformOrigin = .init(x,y)
      var art = Artwork(elements:[e]); let pivot = ArtworkTransforms.worldOrigin(e,in:art)
      let corner = art.worldTransform(e).apply(.init())
      try ArtworkCommands.apply("transform",to:&art,ids:[e.id],arguments:["rotation":90,"scale_x":2,"scale_y":3])
      let changed = art.elements[0]
      assertPoint(ArtworkTransforms.worldOrigin(changed,in:art),pivot)
      let dx = (corner.x-pivot.x)*2,dy = (corner.y-pivot.y)*3
      assertPoint(art.worldTransform(changed).apply(.init()),.init(pivot.x-dy,pivot.y+dx))
      XCTAssertEqual(changed.width,e.width); XCTAssertEqual(changed.height,e.height)
    } }
  }
  func testNestedAffineGroupAndFlippedOriginsUseArtworkCoordinates() throws {
    var group = ArtworkElement(kind:"group",x:25,y:12,width:120,height:60)
    group.contentSize = .init(60,30); group.rotation = 33
    group.affine = .init(a:1,b:0.2,c:0.3,d:1,tx:8,ty:-5)
    var e = shape(); e.parentID = group.id; e.rotation = -21; e.flipX = true
    e.transformOrigin = .init(-0.25,1.5)
    var art = Artwork(elements:[group,e]); let original = art
    let pivot = ArtworkTransforms.worldOrigin(e,in:art)
    let before = art.worldTransform(e).apply(.init(7,11))
    try ArtworkCommands.apply("transform",to:&art,ids:[e.id],arguments:["rotation":90,"translate_x":4,"translate_y":-9])
    assertPoint(ArtworkTransforms.worldOrigin(art.elements[1],in:art),.init(pivot.x+4,pivot.y-9))
    assertPoint(art.worldTransform(art.elements[1]).apply(.init(7,11)),
      .init(pivot.x-(before.y-pivot.y)+4,pivot.y+(before.x-pivot.x)-9))
    XCTAssertEqual(art.elements[0],original.elements[0])
    XCTAssertEqual(art.elements[1].parentID,group.id)
    XCTAssertEqual(art.elements[1].transformOrigin,e.transformOrigin)
  }
  func testGroupOriginUsesItsOriginalContentCoordinatesAndRootsTransformOnlyOnce() throws {
    var group = ArtworkElement(kind:"group",x:20,y:10,width:120,height:60)
    group.contentSize = .init(60,30); group.transformOrigin = .init(1,1)
    var child = shape(); child.parentID = group.id
    var art = Artwork(elements:[group,child])
    assertPoint(ArtworkTransforms.worldOrigin(group,in:art),.init(140,70))
    let before = art.worldTransform(child).apply(.init())
    try ArtworkCommands.apply("transform",to:&art,ids:[group.id,child.id],arguments:["rotation":90])
    XCTAssertEqual(art.elements[1],child)
    assertPoint(art.worldTransform(child).apply(.init()),.init(140-(before.y-70),70+(before.x-140)))
  }
  func testMultipleRootsTransformAroundTheirCombinedCenter() throws {
    var left = shape(); left.transformOrigin = .init(0,0)
    var right = shape(); right.id = UUID(); right.x = 92; right.transformOrigin = .init(1,1)
    var art = Artwork(elements:[left,right])
    let pivot = ArtworkTransforms.selectionOrigin(in:art,ids:[left.id,right.id])!
    assertPoint(pivot,.init(72,28))
    try ArtworkCommands.apply("transform",to:&art,ids:[left.id,right.id],arguments:["rotation":180])
    assertPoint(art.bounds(of:art.elements[0]).center,.init(112,28))
    assertPoint(art.bounds(of:art.elements[1]).center,.init(32,28))
  }
  func testMalformedValuesAndLockedAncestorsRejectWithoutMutation() throws {
    let e = shape(); var art = Artwork(elements:[e]); let before = art
    for arguments:[String:Any] in [[:],["origin":["x":true,"y":0]],
      ["origin":["x":0]],["origin":["x":11,"y":0]],["origin":["x":"0.5","y":1]]] {
      XCTAssertThrowsError(try ArtworkCommands.apply("origin",to:&art,ids:[e.id],arguments:arguments))
      XCTAssertEqual(art,before)
    }
    for arguments:[String:Any] in [[:],["rotation":true],["scale_x":0],["scale_y":-1],["rotation":Double.infinity]] {
      XCTAssertThrowsError(try ArtworkCommands.apply("transform",to:&art,ids:[e.id],arguments:arguments))
      XCTAssertEqual(art,before)
    }
    var group = ArtworkElement(kind:"group",x:0,y:0,width:100,height:100); group.locked = true
    var child = e; child.parentID = group.id; art.elements = [group,child]; let locked = art
    XCTAssertThrowsError(try ArtworkCommands.apply("origin",to:&art,ids:[child.id],arguments:["origin":NSNull()]))
    XCTAssertThrowsError(try ArtworkCommands.apply("transform",to:&art,ids:[child.id],arguments:["rotation":90]))
    XCTAssertEqual(art,locked)
  }
  func testMCPOriginTransformBatchUndoPersistenceAndSourceOnlyUpdates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repo = try ProjectRepository(root:root),engine = OperationEngine(repository:try ProjectRepository(root:root))
    var p = Project(name:"Origin study"),frame = try p.makeObject(recipeID:"artboard")
    let e = shape(); frame.artwork = Artwork(elements:[e]); var user = try p.makeObject(recipeID:"box")
    user.artworkSourceID = frame.id; user.artwork = nil; p.objects = [frame,user]
    try repo.save(p); try engine.open(p.id); let baseline = engine.project!
    func command(_ name:String,_ values:[String:Any]) -> [String:Any] {
      var args = values; args["object_id"] = user.id.uuidString; args["element_ids"] = [e.id.uuidString]; args["command"] = name
      return ["name":"form_edit_artwork","arguments":args]
    }
    _ = try engine.call("form_batch",arguments:["operations":[
      command("origin",["origin":["x":0,"y":1]]),command("transform",["rotation":90])]])
    let changed = engine.project!; XCTAssertEqual(changed.schemaVersion,18)
    XCTAssertEqual(changed.objects[1],baseline.objects[1]); XCTAssertEqual(engine.undoStack.count,1)
    try engine.flush(); let reopened = try repo.load(p.id)
    XCTAssertEqual(reopened.objects,changed.objects)
    XCTAssertEqual(reopened.objects[0].artwork!.elements[0].transformOrigin,.init(0,1))
    engine.undo(); XCTAssertEqual(engine.project,baseline)
    engine.redo(); XCTAssertEqual(engine.project,changed)
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":[
      command("origin",["origin":NSNull()]),command("transform",["scale_x":0])]]))
    XCTAssertEqual(engine.project,changed)
    let history = changed.history
    _ = try engine.call("form_edit_artwork",arguments:command("transform",["rotation":0])["arguments"] as! [String:Any])
    XCTAssertEqual(engine.project!.history,history)
    engine.project!.objects[0].locked = true
    let locked = engine.project
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:command("origin",["origin":NSNull()])["arguments"] as! [String:Any]))
    XCTAssertEqual(engine.project,locked)
  }
  func testLegacyDecodeHasNoOriginAndDuplicateRetainsTheConfiguredReference() throws {
    let e = shape(); let decoded = try JSONDecoder.form.decode(ArtworkElement.self,from:JSONEncoder.form.encode(e))
    XCTAssertNil(decoded.transformOrigin)
    var chosen = e; chosen.transformOrigin = .init(0.25,0.75)
    var art = Artwork(elements:[chosen]); try ArtworkCommands.apply("duplicate",to:&art,ids:[e.id])
    XCTAssertEqual(art.elements[1].transformOrigin,chosen.transformOrigin)
    XCTAssertNotEqual(art.elements[1].id,e.id)
  }
}
