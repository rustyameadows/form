import XCTest
@testable import FormCore

final class CanvasWorkspaceTests: XCTestCase {
  private func fixture() throws -> (Project,UUID,UUID,UUID) {
    var project = Project(name:"Canvas transfer")
    let workspace = try project.ensureCanvasWorkspace()
    var frame = try project.makeObject(recipeID:"artboard",name:"Physical frame")
    var e = ArtworkElement(kind:"rectangle",x:12,y:18,width:40,height:20,color:"#AA5533")
    e.transformOrigin = .init(0.25,0.75)
    var artwork = Artwork(background:"#FFFFFF",elements:[e]); artwork.canvasPosition = .init(300,140)
    frame.artwork = artwork; project.objects.append(frame)
    return(project,workspace.id,frame.id,e.id)
  }
  private func artwork(_ p:Project,_ id:UUID) -> Artwork { p.editableArtwork(p.objects.first { $0.id == id }!)! }
  private func assertPoint(_ a:Point2,_ b:Point2,file:StaticString = #filePath,line:UInt = #line) {
    XCTAssertEqual(a.x,b.x,accuracy:1e-8,file:file,line:line)
    XCTAssertEqual(a.y,b.y,accuracy:1e-8,file:file,line:line)
  }
  func testOneWorkspaceIsIdempotentNonphysicalAndUsesSchemaNineteen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    var p = Project(name:"Empty Canvas"); let workspace = try p.ensureCanvasWorkspace(),original = p
    XCTAssertEqual(try p.ensureCanvasWorkspace(),workspace); XCTAssertEqual(p,original)
    XCTAssertEqual(p.minimumSchemaVersion,19); XCTAssertFalse(workspace.supportsArtworkFace)
    XCTAssertNil(p.surfaceArtwork(workspace)); XCTAssertEqual(workspace.artwork?.canvasPosition,Point2())
    let repo = try ProjectRepository(root:root); try repo.save(p)
    let loaded = try repo.load(p.id); XCTAssertEqual(loaded.schemaVersion,19)
    XCTAssertEqual(loaded.objects,p.objects)
    var legacy = workspace; legacy.canvasWorkspace = nil
    let decoded = try JSONDecoder.form.decode(ProductObject.self,from:JSONEncoder.form.encode(legacy))
    XCTAssertFalse(decoded.isCanvasWorkspace)
  }
  func testWorkspaceCannotBecomeAPhysicalSourceComponentOrSecondWorkspace() throws {
    var (p,workspaceID,frameID,_) = try fixture(); let original = p
    XCTAssertThrowsError(try p.linkArtwork(frameID,sourceID:workspaceID)); XCTAssertEqual(p,original)
    var duplicate = p.canvasWorkspace!; duplicate.id = UUID(); duplicate.designID = UUID(); p.objects.append(duplicate)
    XCTAssertThrowsError(try p.validateArtworkLinks())
    p = original; let index = p.objects.firstIndex { $0.id == workspaceID }!
    p.objects[index].componentDefinition = true
    XCTAssertThrowsError(try p.validateArtworkLinks())
    p = original; p.objects[index].artwork?.canvasPosition = .init(1,0)
    XCTAssertThrowsError(try p.validateArtworkLinks())
    p = original; p.objects.firstIndex { $0.id == frameID }.map { p.objects[$0].artworkSourceID = workspaceID; p.objects[$0].artwork = nil }
    XCTAssertThrowsError(try p.validateArtworkLinks())
  }
  func testFrameToWorkspaceAndBackPreservesGlobalPlacementAndOrigin() throws {
    var (p,workspaceID,frameID,id) = try fixture()
    let source = artwork(p,frameID),e = source.elements[0],world = source.worldTransform(e).apply(.init(9,7))
    let origin = ArtworkTransforms.worldOrigin(e,in:source)
    XCTAssertEqual(try p.transferArtwork(from:frameID,to:workspaceID,ids:[id]),[id])
    XCTAssertTrue(artwork(p,frameID).elements.isEmpty)
    let loose = artwork(p,workspaceID),moved = loose.elements.first { $0.id == id }!
    assertPoint(loose.worldTransform(moved).apply(.init(9,7)),.init(world.x+300,world.y+140))
    assertPoint(ArtworkTransforms.worldOrigin(moved,in:loose),.init(origin.x+300,origin.y+140))
    try p.transferArtwork(from:workspaceID,to:frameID,ids:[id])
    let returned = artwork(p,frameID),back = returned.elements[0]
    assertPoint(returned.worldTransform(back).apply(.init(9,7)),world)
    XCTAssertEqual(back.transformOrigin,e.transformOrigin)
    XCTAssertTrue(artwork(p,workspaceID).elements.isEmpty)
  }
  func testNestedGroupsAndDescendantsKeepTheirExactWorldTransforms() throws {
    var (p,workspaceID,frameID,_) = try fixture()
    var parent = ArtworkElement(kind:"group",x:8,y:11,width:100,height:80)
    parent.contentSize = .init(50,40); parent.rotation = 31
    parent.affine = .init(a:1,b:0.1,c:0.2,d:1,tx:6,ty:9)
    var child = ArtworkElement(kind:"rectangle",x:4,y:7,width:20,height:10); child.parentID = parent.id; child.flipX = true
    let i = p.objects.firstIndex { $0.id == frameID }!
    p.objects[i].artwork!.elements = [parent,child]
    let before = artwork(p,frameID).worldTransform(child).apply(.init(6,3))
    try p.transferArtwork(from:frameID,to:workspaceID,ids:[parent.id,child.id],offset:.init(-70,45))
    let destination = artwork(p,workspaceID),transferred = destination.elements.first { $0.id == child.id }!
    XCTAssertEqual(transferred,child)
    assertPoint(destination.worldTransform(transferred).apply(.init(6,3)),.init(before.x-70,before.y+45))
    XCTAssertTrue(artwork(p,frameID).elements.isEmpty)
  }
  func testTransformedChildCanLeaveANeutralGroupButInheritedAppearanceRequiresTheGroup() throws {
    var (p,workspaceID,frameID,_) = try fixture()
    var parent = ArtworkElement(kind:"group",x:30,y:20,width:100,height:80)
    parent.contentSize = .init(50,40); parent.rotation = 27
    var child = ArtworkElement(kind:"ellipse",x:5,y:8,width:20,height:10); child.parentID = parent.id
    let i = p.objects.firstIndex { $0.id == frameID }!
    p.objects[i].artwork!.elements = [parent,child]
    let before = artwork(p,frameID).worldTransform(child).apply(.init(5,4))
    var rejected = p; rejected.objects[i].artwork!.elements[0].opacity = 0.5; let baseline = rejected
    XCTAssertThrowsError(try rejected.transferArtwork(from:frameID,to:workspaceID,ids:[child.id]))
    XCTAssertEqual(rejected,baseline)
    try p.transferArtwork(from:frameID,to:workspaceID,ids:[child.id],offset:.init())
    let destination = artwork(p,workspaceID),moved = destination.elements[0]
    XCTAssertNil(moved.parentID)
    assertPoint(destination.worldTransform(moved).apply(.init(5,4)),before)
  }
  func testSharedExternalClippingMaskIsCopiedWithoutChangingRemainingConsumers() throws {
    var (p,workspaceID,frameID,_) = try fixture()
    let mask = ArtworkElement(kind:"ellipse",x:5,y:5,width:40,height:40)
    var a = ArtworkElement(kind:"rectangle",x:0,y:0,width:60,height:60); a.clipID = mask.id
    var b = a; b.id = UUID(); b.x = 10
    let i = p.objects.firstIndex { $0.id == frameID }!
    p.objects[i].artwork!.elements = [mask,a,b]
    try p.transferArtwork(from:frameID,to:workspaceID,ids:[a.id],offset:.init(15,-8))
    let source = artwork(p,frameID),destination = artwork(p,workspaceID)
    XCTAssertEqual(source.elements.first { $0.id == b.id },b)
    XCTAssertEqual(source.elements.first { $0.id == mask.id },mask)
    let moved = destination.elements.first { $0.id == a.id }!,copy = destination.elements.first { $0.id == moved.clipID }!
    XCTAssertNotEqual(copy.id,mask.id)
    assertPoint(destination.worldTransform(copy).apply(.init()),.init(20,-3))
    try validateArtwork(source); try validateArtwork(destination)
    // Moving the mask itself leaves an equivalent mask for its source consumers.
    try p.transferArtwork(from:frameID,to:workspaceID,ids:[mask.id],offset:.init())
    let remaining = artwork(p,frameID),consumer = remaining.elements.first { $0.id == b.id }!
    XCTAssertNotEqual(consumer.clipID,mask.id)
    XCTAssertNotNil(remaining.elements.first { $0.id == consumer.clipID })
    try validateArtwork(remaining)
  }
  func testIdentityCollisionsRemapMovedLayersAndKeepExistingDestinationArtwork() throws {
    var (p,workspaceID,frameID,id) = try fixture()
    let i = p.objects.firstIndex { $0.id == workspaceID }!
    var existing = artwork(p,frameID).elements[0]; existing.x = 900
    p.objects[i].artwork!.elements = [existing]
    let selected = try p.transferArtwork(from:frameID,to:workspaceID,ids:[id],offset:.init())
    XCTAssertEqual(selected.count,1); XCTAssertFalse(selected.contains(id))
    let destination = artwork(p,workspaceID)
    XCTAssertEqual(destination.elements.first { $0.id == id },existing)
    XCTAssertNotNil(destination.elements.first { selected.contains($0.id) })
    XCTAssertEqual(Set(destination.elements.map(\.id)).count,2)
  }
  func testPaletteTextStyleAssetsAndComponentsStayProjectLinkedAcrossTransfer() throws {
    var (p,workspaceID,frameID,_) = try fixture()
    let swatch = ArtworkSwatch(name:"Ink",color:"#123456"),style = ArtworkTextStyle(name:"Body",fontSize:18)
    p.swatches = [swatch]; p.textStyles = [style]
    var text = ArtworkElement(kind:"text",x:1,y:2,width:80,height:20,text:"Shared source",color:swatch.color,fontSize:18)
    text.fillSwatchID = swatch.id; text.typography = style.typography; text.textStyle = .init(styleID:style.id)
    let image = ArtworkElement(kind:"image",x:1,y:25,width:50,height:30,asset:"original.png")
    var component = try p.makeObject(recipeID:"artboard"); component.componentDefinition = true
    component.artwork = Artwork(elements:[ArtworkElement(kind:"ellipse",x:0,y:0,width:20,height:20)])
    p.objects.append(component)
    var instance = ArtworkElement(kind:"group",x:3,y:60,width:40,height:40)
    instance.contentSize = component.artworkSize; instance.component = .init(sourceObjectID:component.id)
    let i = p.objects.firstIndex { $0.id == frameID }!; p.objects[i].artwork!.elements = [text,image,instance]
    try p.validateArtworkLinks()
    try p.transferArtwork(from:frameID,to:workspaceID,ids:[text.id,image.id,instance.id])
    let result = artwork(p,workspaceID)
    XCTAssertEqual(result.elements.first { $0.id == text.id }?.textStyle,text.textStyle)
    XCTAssertEqual(result.elements.first { $0.id == text.id }?.fillSwatchID,swatch.id)
    XCTAssertEqual(result.elements.first { $0.id == image.id }?.asset,image.asset)
    XCTAssertEqual(result.elements.first { $0.id == instance.id }?.component,instance.component)
    XCTAssertEqual(p.swatches,[swatch]); XCTAssertEqual(p.textStyles,[style])
    try p.validateArtworkLinks()
  }
  func testMCPWorkspaceCreationTransferUndoBatchRollbackAndReopen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let repo = try ProjectRepository(root:root),engine = OperationEngine(repository:try ProjectRepository(root:root))
    var (p,workspaceID,frameID,id) = try fixture(); p.schemaVersion = p.minimumSchemaVersion
    try repo.save(p); try engine.open(p.id)
    let baseline = engine.project!
    engine.selection = [frameID]
    _ = try engine.call("form_add_object",arguments:["recipe_id":"artboard","canvas_workspace":true])
    XCTAssertEqual(engine.project,baseline); XCTAssertTrue(engine.undoStack.isEmpty)
    XCTAssertEqual(engine.selection,[frameID])
    let args:[String:Any] = ["command":"transfer","object_id":frameID.uuidString,
      "target_object_id":workspaceID.uuidString,"element_ids":[id.uuidString],"offset_x":20,"offset_y":-10]
    let result = try engine.call("form_edit_artwork",arguments:args) as! [String:Any]
    XCTAssertEqual(result["target_object_id"] as? String,workspaceID.uuidString)
    XCTAssertEqual(engine.undoStack.count,1)
    let transferred = engine.project!
    try engine.flush(); XCTAssertEqual(try repo.load(p.id).objects,transferred.objects)
    engine.undo(); XCTAssertEqual(engine.project,baseline)
    engine.redo(); XCTAssertEqual(engine.project,transferred)
    var back = args; back["object_id"] = workspaceID.uuidString; back["target_object_id"] = frameID.uuidString
    var bad = back; bad["offset_x"] = true
    XCTAssertThrowsError(try engine.call("form_batch",arguments:["operations":[
      ["name":"form_edit_artwork","arguments":back],["name":"form_edit_artwork","arguments":bad]]]))
    XCTAssertEqual(engine.project,transferred)
    XCTAssertGreaterThanOrEqual(MCP.tools.count,50)
    XCTAssertTrue(Set(["form_add_object","form_edit_artwork","form_set_view"]).isSubset(of:MCP.toolNames))
  }
  func testMCPCreatingTheInternalWorkspacePreservesThePhysicalSelectionAndUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine = OperationEngine(repository:try ProjectRepository(root:root))
    var p = Project(name:"Physical selection"),box = try p.makeObject(recipeID:"box")
    box.name = "Selected product"; p.objects = [box]
    engine.project = p; engine.selection = [box.id]
    let result = try engine.call("form_add_object",arguments:["recipe_id":"artboard","canvas_workspace":true]) as! [String:Any]
    XCTAssertEqual(result["canvasWorkspace"] as? Bool,true)
    XCTAssertEqual(engine.selection,[box.id])
    XCTAssertEqual(engine.project!.objects.first { $0.id == box.id },box)
    XCTAssertNotNil(engine.project!.canvasWorkspace)
    XCTAssertEqual(engine.undoStack.count,1)
    engine.undo(); XCTAssertEqual(engine.project,p)
  }
  func testLockedOrInvalidTransfersAreAtomicAndNativeDragCanShareOneUndo() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    var (p,workspaceID,frameID,id) = try fixture()
    let i = p.objects.firstIndex { $0.id == frameID }!
    p.objects[i].locked = true; let locked = p
    XCTAssertThrowsError(try p.transferArtwork(from:frameID,to:workspaceID,ids:[id]))
    XCTAssertEqual(p,locked); p.objects[i].locked = false
    let engine = OperationEngine(repository:try ProjectRepository(root:root)); engine.project = p
    let baseline = p,key = "artwork-\(frameID)"
    engine.beginInteraction(key)
    try engine.edit("Dragged artwork",coalescing:key) { project in
      project.objects[i].artwork!.elements[0].x += 15
    }
    _ = try engine.call("form_edit_artwork",arguments:["command":"transfer","object_id":frameID.uuidString,
      "target_object_id":workspaceID.uuidString,"element_ids":[id.uuidString]],source:"Studio")
    engine.endInteraction(); XCTAssertEqual(engine.undoStack.count,1)
    engine.undo(); XCTAssertEqual(engine.project,baseline)
  }
}
