import XCTest
@testable import FormCore

final class GarmentBlockTests: XCTestCase {
  private func fixture() throws -> (OperationEngine, UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var project=Project(name:"Original declared block");let owner=try project.ensureCanvasWorkspace();engine.project=project
    return (engine,owner.id)
  }
  @discardableResult private func call(_ engine:OperationEngine,_ owner:UUID,_ operation:String,_ extra:[String:Any]=[:])throws->Any {
    var args:[String:Any]=["object_id":owner.uuidString,"command":"garment_block","operation":operation]
    args.merge(extra){_,new in new};return try engine.call("form_edit_artwork",arguments:args)
  }
  private func create(_ engine:OperationEngine,_ owner:UUID)throws->GarmentBlock {
    _=try call(engine,owner,"create")
    return engine.project!.garmentBlocks![0]
  }
  func testOriginalThreeSizeDraftHasActualRawSideSeamsExplicitFoldPositionsAndDeclaredElasticGuides() throws {
    let (engine,owner)=try fixture(),before=engine.project!
    let block=try create(engine,owner),project=engine.project!,art=project.canvasWorkspace!.artwork!
    XCTAssertEqual(project.minimumSchemaVersion,41);XCTAssertEqual(block.bindings.count,9);XCTAssertEqual(block.seams.count,6)
    XCTAssertTrue(try GarmentBlockSources.conflicts(block,in:project).isEmpty)
    for row in block.sizes {
      let size=try block.resolved(row),refs=block.bindings.filter{$0.sizeID==row.id}
      XCTAssertEqual(refs.count,3)
      let front=art.elements.first{$0.id==refs.first{$0.role == .front}!.elementID}!
      let g=try SewingPatterns.geometry(front,in:art),guides=try SewingConstructionGuides.resolve(g)
      XCTAssertEqual(g.edgeLengths[1],size.rawHeight,accuracy:1e-8)
      XCTAssertEqual(g.bounds.width,size.panelWidth+20,accuracy:1e-8)
      XCTAssertEqual(g.bounds.height,size.rawHeight,accuracy:1e-8)
      XCTAssertEqual(guides[2].guide.offset-guides[1].guide.offset,size.bodyLength,accuracy:1e-8)
      let elastic=art.elements.first{$0.id==refs.first{$0.role == .elastic}!.elementID}!
      XCTAssertEqual(elastic.width,size.elasticCutLength);XCTAssertEqual(elastic.height,25)
    }
    let base=try block.resolved(block.sizes.first{$0.id==block.baseSizeID}!)
    XCTAssertEqual(base.panelWidth,550);XCTAssertEqual(base.rawHeight,718);XCTAssertEqual(base.elasticCutLength,765)
    let checks=try SewingPatterns.diagnostics(art)
    XCTAssertEqual(checks.count,6);XCTAssertTrue(checks.allSatisfy(\.matches))
    XCTAssertEqual(engine.undoStack.count,1);engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testUpdatePreservesSourceEdgeGuideSeamIDsStyleAndChosenTransformOriginWithOneUndo() throws {
    let (engine,owner)=try fixture();var block=try create(engine,owner)
    let ref=block.bindings.first{$0.sizeID == block.baseSizeID && $0.role == .front}!
    var project=engine.project!,art=project.canvasWorkspace!.artwork!
    let index=art.elements.firstIndex{$0.id==ref.elementID}!
    art.elements[index].color="#FF5522";art.elements[index].stroke?.color="#FF5522"
    art.elements[index].rotation=23;art.elements[index].flipX=true;art.elements[index].transformOrigin = .init(0,0)
    try project.setArtwork(art,for:owner);engine.project=project
    let before=project,old=art.elements[index],origin=ArtworkTransforms.worldOrigin(old,in:art),history=engine.undoStack.count
    block.body.hip+=40;block.style.bodyLength+=20
    _=try call(engine,owner,"update",["block_id":block.id.uuidString,"block":try GarmentBlockCommands.definition(block)])
    let after=engine.project!,next=after.canvasWorkspace!.artwork!.elements.first{$0.id==ref.elementID}!
    XCTAssertEqual(next.id,old.id);XCTAssertEqual(next.path!.contours[0].nodes.map(\.id),old.path!.contours[0].nodes.map(\.id))
    XCTAssertEqual(next.sewingPiece!.constructionGuides!.map(\.id),old.sewingPiece!.constructionGuides!.map(\.id))
    XCTAssertEqual(after.garmentBlocks![0].seams.map(\.seamID),before.garmentBlocks![0].seams.map(\.seamID))
    XCTAssertEqual(next.color,old.color);XCTAssertEqual(next.stroke,old.stroke)
    let newOrigin=ArtworkTransforms.worldOrigin(next,in:after.canvasWorkspace!.artwork!)
    XCTAssertEqual(origin.x,newOrigin.x,accuracy:1e-8);XCTAssertEqual(origin.y,newOrigin.y,accuracy:1e-8)
    XCTAssertEqual(engine.undoStack.count,history+1);engine.undo();XCTAssertEqual(engine.project,before)
  }
  func testChartOnlyConfigurationAndReadOperationsDoNotTouchGeometrySelectionOrHistory() throws {
    let (engine,owner)=try fixture();var block=try create(engine,owner)
    let before=engine.project!,objects=before.objects,cache=try before.canvasWorkspace!.artwork!.renderCacheData()
    block.grade.hip=50;let count=engine.undoStack.count
    _=try call(engine,owner,"configure",["block_id":block.id.uuidString,"block":try GarmentBlockCommands.definition(block)])
    XCTAssertEqual(engine.project!.objects,objects);XCTAssertEqual(try engine.project!.canvasWorkspace!.artwork!.renderCacheData(),cache)
    engine.selection=[owner];let saved=engine.project!,history=engine.undoStack.count
    for op in ["list","get","report"] {
      _=try call(engine,owner,op,["block_id":block.id.uuidString])
      XCTAssertEqual(engine.project,saved);XCTAssertEqual(engine.selection,[owner]);XCTAssertEqual(engine.undoStack.count,history)
    }
    XCTAssertEqual(history,count+1)
    try engine.flush();let reopened=try engine.repository.load(saved.id);XCTAssertEqual(reopened.garmentBlocks,saved.garmentBlocks)
  }
  func testManualEditBlocksWholeUpdateAndExplicitRevisionOrDetachNeverOverwritesIt() throws {
    let (engine,owner)=try fixture();let block=try create(engine,owner),ref=block.bindings[0]
    var project=engine.project!,art=project.canvasWorkspace!.artwork!
    let index=art.elements.firstIndex{$0.id==ref.elementID}!
    art.elements[index].sewingPiece!.notes="Keep this original construction note."
    try project.setArtwork(art,for:owner);engine.project=project
    let before=project,count=engine.undoStack.count
    XCTAssertThrowsError(try call(engine,owner,"update",["block_id":block.id.uuidString]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,count)
    _=try call(engine,owner,"create_revision",["block_id":block.id.uuidString])
    XCTAssertEqual(engine.project!.garmentBlocks!.count,2)
    XCTAssertEqual(engine.project!.canvasWorkspace!.artwork!.elements.first{$0.id==ref.elementID},art.elements[index])
    let second=engine.project!.garmentBlocks![1]
    XCTAssertTrue(Set(second.bindings.map(\.elementID)).isDisjoint(with:Set(block.bindings.map(\.elementID))))
    let source=engine.project!.objects
    _=try call(engine,owner,"detach",["block_id":block.id.uuidString]);XCTAssertEqual(engine.project!.objects,source)
  }
  func testMissingSourceIsAConflictAndSizeRemovalDetachesWhilePreservingAllRemainingArtwork() throws {
    let (engine,owner)=try fixture();let block=try create(engine,owner),row=block.sizes[0]
    let ref=block.bindings.first{$0.sizeID==row.id}!
    _=try engine.call("form_edit_artwork",arguments:["object_id":owner.uuidString,"command":"delete","element_ids":[ref.elementID.uuidString]])
    let missing=engine.project!,count=engine.undoStack.count
    XCTAssertTrue(try GarmentBlockSources.conflicts(block,in:missing).contains{$0.contains("missing")})
    XCTAssertThrowsError(try call(engine,owner,"update",["block_id":block.id.uuidString]))
    XCTAssertEqual(engine.project,missing);XCTAssertEqual(engine.undoStack.count,count)
    _=try call(engine,owner,"detach_size",["block_id":block.id.uuidString,"size_id":row.id.uuidString])
    XCTAssertEqual(engine.project!.objects,missing.objects)
    XCTAssertFalse(engine.project!.garmentBlocks![0].sizes.contains{$0.id==row.id})
    engine.undo();XCTAssertEqual(engine.project,missing)
  }
  func testCompleteRigidSizeTransferRemapsSourceAndSeamsWhilePartialOrNonrigidTransferRollsBack() throws {
    let (engine,owner)=try fixture();let block=try create(engine,owner),size=block.sizes[0]
    var project=engine.project!,target=try project.makeObject(recipeID:"artboard",name:"Independent destination",parameters:["width":1400,"depth":1200])
    target.artwork = .init(background:"#FFFFFF",bleed:0);project.objects.append(target);engine.project=project
    let refs=block.bindings.filter{$0.sizeID==size.id},before=project,count=engine.undoStack.count
    let partial=refs.filter{$0.role != .elastic}.map{$0.elementID.uuidString}
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["object_id":owner.uuidString,"command":"transfer","target_object_id":target.id.uuidString,"element_ids":partial]))
    XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,count)
    let moved=refs.map{$0.elementID.uuidString}
    _=try engine.call("form_edit_artwork",arguments:["object_id":owner.uuidString,"command":"transfer","target_object_id":target.id.uuidString,"element_ids":moved])
    let after=engine.project!,updated=after.garmentBlocks![0]
    XCTAssertTrue(updated.bindings.filter{$0.sizeID==size.id}.allSatisfy{$0.objectID==target.id})
    XCTAssertTrue(updated.seams.filter{$0.sizeID==size.id}.allSatisfy{$0.objectID==target.id})
    XCTAssertTrue(try GarmentBlockSources.conflicts(updated,in:after).isEmpty)
    XCTAssertEqual(engine.undoStack.count,count+1);engine.undo();XCTAssertEqual(engine.project,before)
    project=before;var art=project.canvasWorkspace!.artwork!
    let index=art.elements.firstIndex{$0.id==refs[0].elementID}!
    art.elements[index].affine = .scale(1.1,1.1);try project.setArtwork(art,for:owner);engine.project=project
    XCTAssertThrowsError(try engine.call("form_edit_artwork",arguments:["object_id":owner.uuidString,"command":"transfer","target_object_id":target.id.uuidString,"element_ids":moved]))
    XCTAssertEqual(engine.project,project)
  }
  func testOrdinaryArtworkDuplicationIsIndependentAndNeverCreatesManagedBindings() throws {
    let (engine,owner)=try fixture();let block=try create(engine,owner),row=block.sizes[0]
    let refs=block.bindings.filter{$0.sizeID==row.id},before=engine.project!
    let result=try engine.call("form_edit_artwork",arguments:["object_id":owner.uuidString,"command":"duplicate","element_ids":refs.map{$0.elementID.uuidString}]) as! [String:Any]
    let copies=Set((result["selected_elements"] as! [String]).compactMap(UUID.init(uuidString:)))
    XCTAssertFalse(copies.isEmpty)
    XCTAssertEqual(engine.project!.garmentBlocks,before.garmentBlocks)
    XCTAssertTrue(copies.isDisjoint(with:Set(block.bindings.map(\.elementID))))
    XCTAssertTrue(try GarmentBlockSources.conflicts(block,in:engine.project!).isEmpty)
    let oldGuides=Set(before.canvasWorkspace!.artwork!.elements.flatMap{($0.sewingPiece?.constructionGuides ?? []).map(\.id)})
    let newGuides=Set(engine.project!.canvasWorkspace!.artwork!.elements.filter{copies.contains($0.id)}.flatMap{($0.sewingPiece?.constructionGuides ?? []).map(\.id)})
    XCTAssertTrue(oldGuides.isDisjoint(with:newGuides))
  }
  func testCompleteTransferHandlesRealElementNodeAndGuideIdentityCollisionsWithoutLosingBindings() throws {
    let (engine,owner)=try fixture();let block=try create(engine,owner),row=block.sizes[0]
    let refs=block.bindings.filter{$0.sizeID==row.id},front=refs.first{$0.role == .front}!
    var project=engine.project!,target=try project.makeObject(recipeID:"artboard",name:"Collision destination",parameters:["width":1800,"depth":1400])
    var existing=project.canvasWorkspace!.artwork!.elements.first{$0.id==front.elementID}!
    existing.parentID=nil;existing.affine=nil;existing.x=1200
    target.artwork = .init(background:"#FFFFFF",elements:[existing],bleed:0)
    project.objects.append(target);engine.project=project
    _=try engine.call("form_edit_artwork",arguments:["object_id":owner.uuidString,"command":"transfer","target_object_id":target.id.uuidString,"element_ids":refs.map{$0.elementID.uuidString}])
    let moved=engine.project!,updated=moved.garmentBlocks![0],next=updated.bindings.first{$0.sizeID==row.id && $0.role == .front}!
    XCTAssertNotEqual(next.elementID,front.elementID)
    let piece=moved.objects.first{$0.id==target.id}!.artwork!.elements.first{$0.id==next.elementID}!
    XCTAssertTrue(Set(piece.path!.contours[0].nodes.map(\.id)).isDisjoint(with:Set(existing.path!.contours[0].nodes.map(\.id))))
    XCTAssertTrue(try GarmentBlockSources.conflicts(updated,in:moved).isEmpty)
    XCTAssertTrue(try SewingPatterns.diagnostics(moved.objects.first{$0.id==target.id}!.artwork!).allSatisfy(\.matches))
  }
  func testFiniteBoundsOverridesAndOneManagedBindingPerSourceAreEnforcedAtomically() throws {
    let (engine,owner)=try fixture();var block=try create(engine,owner),before=engine.project!
    block.sizes[0].overrides = .init();block.sizes[0].overrides!.hip=1100
    let resolved=try block.resolved(block.sizes[0]);XCTAssertEqual(resolved.hip,1100);XCTAssertEqual(resolved.waist,720)
    for value in [Double.nan,.infinity,-10000,10000] {
      block.grade.hip=value
      XCTAssertThrowsError(try block.validate())
      XCTAssertEqual(engine.project,before)
    }
    XCTAssertThrowsError(try call(engine,owner,"update",["operation":true,"block_id":before.garmentBlocks![0].id.uuidString]))
    XCTAssertThrowsError(try call(engine,owner,"update",["block_id":before.garmentBlocks![0].id.uuidString,"block":["grade":["hip":10000]]]))
    XCTAssertEqual(engine.project,before)
    var definition=try GarmentBlockCommands.definition(before.garmentBlocks![0])
    var sizes=definition["sizes"] as! [[String:Any]];sizes[0]["overrides"]=["hips":1100];definition["sizes"]=sizes
    XCTAssertThrowsError(try call(engine,owner,"configure",["block_id":before.garmentBlocks![0].id.uuidString,"block":definition]))
    XCTAssertEqual(engine.project,before)
    var duplicate=before.garmentBlocks![0];duplicate.id=UUID();before.garmentBlocks!.append(duplicate)
    XCTAssertThrowsError(try before.validateArtworkLinks())
  }
}
