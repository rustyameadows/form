import XCTest
@testable import FormCore

final class ArtworkPageSetupTests:XCTestCase {
  private func fixture()throws->(OperationEngine,URL,UUID) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);let engine=OperationEngine(repository:try ProjectRepository(root:root));var p=Project(name:"Physical page"),o=try p.makeObject(recipeID:"artboard",parameters:["width":200,"depth":150]);o.artwork = .init(background:"#FFFFFF",bleed:3);p.objects=[o];engine.project=p;addTeardownBlock{try? FileManager.default.removeItem(at:root)};return(engine,root,o.id)
  }
  private func setup(_ engine:OperationEngine,_ id:UUID,_ fields:[String:Any])throws {_ = try engine.call("form_edit_artwork",arguments:fields.merging(["object_id":id.uuidString,"command":"page_setup"]){_,v in v})}
  func testLegacyNilEncodingAndGuideOnlyRenderDefinitionAreExact()throws {
    let old=Artwork(background:"#FFFFFF"),data=try JSONEncoder.form.encode(old);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("safeInset"));XCTAssertNil(try JSONDecoder.form.decode(Artwork.self,from:data).safeInset)
    var a=old;a.safeInset=5;XCTAssertNotEqual(a,old);a.bleed=12;XCTAssertEqual(a.renderDefinition,old.renderDefinition)
    var e=ArtworkElement(kind:"rectangle",x:0,y:0,width:10,height:10);e.color="#203A4A";a.elements=[e]
    XCTAssertNil(try a.exporting([e.id]).artwork.safeInset)
  }
  func testFiveThousandPhysicalGeometryCasesKeepNestedBoxesAllMarksAndExactSourceSize()throws {
    var seed:UInt64=49
    func unit()->Double {seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Double(seed>>11)/Double(UInt64.max>>11)}
    func contains(_ a:Rect2,_ b:Rect2)->Bool {b.x>=a.x-1e-8 && b.y>=a.y-1e-8 && b.maxX<=a.maxX+1e-8 && b.maxY<=a.maxY+1e-8}
    for i in 0..<5000 {
      let width=50+4450*unit(),height=50+4450*unit(),bleed=25*unit(),safe=min(width,height)*0.4*unit(),options=ArtworkPageOptions(area:i%3==0 ? .trim:.bleed,cropMarks:i%2==0,markGapMm:25*unit(),markLengthMm:0.1+24.9*unit()),g=try ArtworkPageGeometry(width:width,height:height,bleed:bleed,safeInset:safe,options:options)
      XCTAssertEqual(g.trimMm.width,width);XCTAssertEqual(g.trimMm.height,height);XCTAssertEqual(g.drawingOriginMm,Point2(g.trimMm.x,g.trimMm.y));XCTAssertTrue(contains(g.mediaMm,g.bleedMm));XCTAssertTrue(contains(g.bleedMm,g.trimMm));XCTAssertTrue(contains(g.trimMm,g.safeMm!));XCTAssertEqual(g.marks.count,options.cropMarks ? 8:0)
      for mark in g.marks {let b=mark.strokeBoundsMm;XCTAssertTrue(contains(g.mediaMm,b));XCTAssertTrue(min(b.maxX,g.bleedMm.maxX)-max(b.x,g.bleedMm.x)<=1e-8 || min(b.maxY,g.bleedMm.maxY)-max(b.y,g.bleedMm.y)<=1e-8)}
    }
  }
  func testStrictPageOptionsRejectUnknownBooleanNonfiniteAndOversizeInputs()throws {
    for raw in [[:],["area":"crop"],["area":"trim","crop_marks":1],["area":"bleed","mark_gap_mm":true],["area":"bleed","mark_length_mm":Double.infinity],["area":"bleed","unknown":0]] as [Any] {XCTAssertThrowsError(try ArtworkPageSetup.options(raw))}
    XCTAssertThrowsError(try ArtworkPageGeometry(width:5080,height:150,bleed:3,safeInset:nil,options:.init()))
    XCTAssertThrowsError(try ArtworkPageGeometry(width:200,height:150,bleed:3,safeInset:75,options:.init()))
    XCTAssertThrowsError(try ArtworkPageGeometry(width:.nan,height:150,bleed:3,safeInset:nil,options:.init()))
    let trim=try ArtworkPageGeometry(width:200,height:150,bleed:3,safeInset:0,options:.init(area:.trim));XCTAssertEqual(trim.includedBleedMm,0);XCTAssertEqual(trim.bleedMm,trim.trimMm);XCTAssertNil(trim.safeMm)
  }
  func testPageSetupHasOneUndoAndExplicitNullRestoresNoDeclarationOnReopen()throws {
    let(engine,root,id)=try fixture(),before=engine.project!;try setup(engine,id,["bleed":4.25,"safe_inset":7.125]);XCTAssertEqual(engine.undoStack.count,1)
    let after=engine.project!;XCTAssertEqual(after.objects[0].artwork!.safeInset,7.125);XCTAssertEqual(after.minimumSchemaVersion,49);XCTAssertEqual(after.camera,before.camera)
    try engine.flush();let reopened=try ProjectRepository(root:root).load(after.id);XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.schemaVersion,49)
    engine.undo();XCTAssertEqual(engine.project,before);engine.redo();XCTAssertEqual(engine.project,after)
    try setup(engine,id,["safe_inset":NSNull()]);XCTAssertNil(engine.project!.objects[0].artwork!.safeInset);XCTAssertEqual(engine.project!.objects[0].artwork!.bleed,4.25)
  }
  func testInvalidSetupAndFrameResizeRejectAtomicallyWithoutClampingOrHistory()throws {
    let(engine,_,id)=try fixture()
    for fields in [[:],["bleed":true],["safe_inset":true],["safe_inset":Double.nan],["safe_inset":75],["bleed":26],["bleed":4,"element_ids":[]],["safe_inset":-1],["unknown":2]] as [[String:Any]] {let before=engine.project;XCTAssertThrowsError(try setup(engine,id,fields));XCTAssertEqual(engine.project,before);XCTAssertTrue(engine.undoStack.isEmpty)}
    try setup(engine,id,["safe_inset":20]);let before=engine.project,count=engine.undoStack.count
    XCTAssertThrowsError(try engine.call("form_update_object",arguments:["object_id":id.uuidString,"parameters":["depth":30.0]]));XCTAssertEqual(engine.project,before);XCTAssertEqual(engine.undoStack.count,count)
  }
  func testCanonicalOwnershipWorkspaceBoundaryAndLockedGuards()throws {
    let(engine,_,id)=try fixture(),before=engine.project!
    for mutate in [{(p:inout Project) in p.objects[0].locked=true},{p in p.objects[0].canvasWorkspace=true},{p in p.objects[0].artwork!.boundary = .init(width:200,height:150,contours:[])}] {var p=before;mutate(&p);engine.project=p;XCTAssertThrowsError(try setup(engine,id,["safe_inset":3]));XCTAssertEqual(engine.project,p)}
    engine.project=before;var p=before,o=try p.makeObject(recipeID:"box",parameters:["width":100,"depth":80,"height":20]);p.objects[0].artwork!.safeInset=5
    // Add first, then link through the canonical graph below.
    o.artworkSourceID=id;o.artwork=nil;p.objects.append(o)
    XCTAssertThrowsError(try ArtworkPageSetup.source(p,objectID:o.id));XCTAssertNil(p.surfaceArtwork(o)?.safeInset);XCTAssertEqual(p.objects[0].artwork!.safeInset,5)
  }
  func testOnlyExactPageFieldsQualifyForMetadataHistoryRefresh()throws {
    let(engine,_,_)=try fixture(),a=engine.project!;var b=a;b.objects[0].artwork!.safeInset=5;b.objects[0].artwork!.bleed=4;b.schemaVersion=49
    XCTAssertTrue(ArtworkPageSetup.containsOnlyPageSetupChanges(a,b));XCTAssertFalse(ArtworkPageSetup.containsOnlyPageSetupChanges(a,a))
    b.objects[0].artwork!.background="#EE5533";XCTAssertFalse(ArtworkPageSetup.containsOnlyPageSetupChanges(a,b))
    b=a;b.objects[0].parameters["width"]=250;b.objects[0].artwork!.safeInset=5;XCTAssertFalse(ArtworkPageSetup.containsOnlyPageSetupChanges(a,b))
  }
  func testAggregateSourceBudgetsRejectBeforeRenderingOrAssetReads()throws {
    let e=ArtworkElement(kind:"text",x:0,y:0,width:200,height:150,text:String(repeating:"a",count:1_000_001))
    XCTAssertThrowsError(try ArtworkPageSetup.sourceWorkload(Artwork(elements:[e])))
    var image=ArtworkElement(kind:"image",x:0,y:0,width:1,height:1);let images=(0..<129).map{i->ArtworkElement in var copy=image;copy.id=UUID();copy.asset="not-read-\(i).png";return copy}
    XCTAssertThrowsError(try ArtworkPageSetup.sourceWorkload(Artwork(elements:images)))
    image.kind="text";image.text="Actual source";XCTAssertEqual(try ArtworkPageSetup.sourceWorkload(Artwork(elements:[image]))["source_utf16"],13)
  }

}
