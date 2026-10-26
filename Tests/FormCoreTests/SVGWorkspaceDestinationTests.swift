import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class SVGWorkspaceDestinationTests:XCTestCase {
  private func svg()throws->SVGImportResult {
    try SVGImporter.read(Data("""
      <svg xmlns="http://www.w3.org/2000/svg" width="2in" height="72pt" viewBox="0 0 200 100">
        <rect id="physical-mark" x="0" y="0" width="200" height="100" fill="#224B9B"/>
        <g id="caption" transform="translate(10 10)"><text x="5" y="20" font-family="Arial" font-size="12">Orbit 01</text></g>
      </svg>
      """.utf8))
  }
  private func record(_ result:SVGImportResult)->ArtworkImport {
    var value=ArtworkImport(asset:"original.svg",name:"Physical SVG",width:result.width,height:result.height,issues:result.issues.map(\.message))
    value.importedAt=Date(timeIntervalSince1970:1_800_000_000);return value
  }
  private func assertTranslatedWithoutScaling(_ result:SVGImportResult,in art:Artwork,offset:Point2,file:StaticString = #filePath,line:UInt = #line)throws {
    for original in result.artwork.elements {
      let placed=try XCTUnwrap(art.elements.first{$0.id==original.id},file:file,line:line)
      var expected=original
      if original.parentID==nil {expected.affine=Affine2.translation(offset.x,offset.y).followed(by:original.affine ?? .init())}
      XCTAssertEqual(placed,expected,file:file,line:line)
      let sourceBounds=result.artwork.bounds(of:original),placedBounds=art.bounds(of:placed)
      XCTAssertEqual(placedBounds.width,sourceBounds.width,accuracy:1e-9,file:file,line:line)
      XCTAssertEqual(placedBounds.height,sourceBounds.height,accuracy:1e-9,file:file,line:line)
      XCTAssertEqual(placedBounds.x-sourceBounds.x,offset.x,accuracy:1e-9,file:file,line:line)
      XCTAssertEqual(placedBounds.y-sourceBounds.y,offset.y,accuracy:1e-9,file:file,line:line)
    }
  }
  func testExistingWorkspaceUsesCurrentCenteringPathWithExactLooseContentSourceCameraAndOneUndo()throws {
    let result=try svg(),source=record(result),sourceBytes=try JSONEncoder.form.encode(result.artwork)
    XCTAssertEqual(result.width,50.8,accuracy:1e-9);XCTAssertEqual(result.height,25.4,accuracy:1e-9)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let repository=try ProjectRepository(root:root),engine=OperationEngine(repository:repository)
    var project=Project(name:"Existing Canvas SVG destination")
    let workspace=try project.ensureCanvasWorkspace(),loose=ArtworkElement(kind:"text",x:-340,y:2200,width:80,height:25,text:"Existing loose content",fontSize:18)
    project.objects[0].artwork!.elements=[loose]
    project.objects[0].artwork!.imports=[.init(asset:"older.svg",name:"Previous import",width:10,height:20)]
    project.objects[0].artwork!.imports![0].importedAt=Date(timeIntervalSince1970:1_700_000_000)
    project.camera.azimuth = -1.23;project.camera.elevation=0.42;project.camera.distance=17;project.camera.target = .init(3,4,5)
    engine.project=project;let before=project
    var importedID:UUID?
    try engine.edit("Import SVG into Canvas"){p in importedID=try p.importArtwork(result.artwork,source:source,targetID:workspace.id)}
    let after=try XCTUnwrap(engine.project),destination=try XCTUnwrap(after.canvasWorkspace),art=try XCTUnwrap(destination.artwork)
    XCTAssertEqual(importedID,workspace.id);XCTAssertEqual(after.objects.count,before.objects.count);XCTAssertEqual(engine.undoStack.count,1)
    XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(destination.parameters,workspace.parameters);XCTAssertEqual(destination.position,workspace.position)
    XCTAssertEqual(art.elements.first,loose);XCTAssertEqual(art.elements.count,1+result.artwork.elements.count)
    XCTAssertEqual(art.imports,(before.canvasWorkspace!.artwork!.imports ?? [])+[source])
    var stripped=art;stripped.elements=[loose];stripped.imports=before.canvasWorkspace!.artwork!.imports
    XCTAssertEqual(stripped,before.canvasWorkspace!.artwork!)
    XCTAssertNil(art.safeInset);XCTAssertEqual(art.bleed,0)
    try assertTranslatedWithoutScaling(result,in:art,offset:.init((workspace.artworkSize.x-result.width)/2,(workspace.artworkSize.y-result.height)/2))
    XCTAssertEqual(try JSONEncoder.form.encode(result.artwork),sourceBytes)
    engine.undo();XCTAssertEqual(engine.project,before);engine.redo();XCTAssertEqual(engine.project,after)
    try engine.flush();let reopened=try repository.load(after.id)
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.camera,after.camera);XCTAssertEqual(reopened.canvasWorkspace?.artwork?.imports,art.imports)
  }
  func testExistingFiniteDestinationRetainsBleedSafeInsetAndCurrentPhysicalScale()throws {
    let result=try svg();var project=Project(name:"Finite SVG destination")
    var frame=try project.makeObject(recipeID:"artboard",parameters:["width":200,"depth":150])
    var art=Artwork(background:"#D8E6E0",elements:[.init(kind:"ellipse",x:12,y:18,width:9,height:7)],bleed:4.25)
    art.safeInset=7.125;art.unit = .cm;frame.artwork=art;project.objects=[frame]
    let camera=project.camera,source=record(result)
    XCTAssertEqual(try project.importArtwork(result.artwork,source:source,targetID:frame.id),frame.id)
    let imported=try XCTUnwrap(project.objects[0].artwork)
    var stripped=imported;stripped.elements=art.elements;stripped.imports=art.imports
    XCTAssertEqual(stripped,art);XCTAssertEqual(imported.bleed,4.25);XCTAssertEqual(imported.safeInset,7.125);XCTAssertEqual(project.camera,camera)
    try assertTranslatedWithoutScaling(result,in:imported,offset:.init((200-result.width)/2,(150-result.height)/2))
  }
  func testLockedWorkspaceRejectsWithoutChangingSourceHistoryOrCamera()throws {
    let result=try svg(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root))
    var project=Project(name:"Locked SVG destination");let workspace=try project.ensureCanvasWorkspace();project.objects[0].locked=true;engine.project=project
    XCTAssertThrowsError(try engine.edit("Rejected SVG import"){p in _ = try p.importArtwork(result.artwork,source:record(result),targetID:workspace.id)})
    XCTAssertEqual(engine.project,project);XCTAssertTrue(engine.undoStack.isEmpty);XCTAssertTrue(engine.redoStack.isEmpty)
  }
}
