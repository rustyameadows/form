import AppKit
import Foundation
import FormCore
import XCTest
@testable import FormApp

@MainActor final class ObjectViewExportGuardTests: XCTestCase {
  func testOnlySelectedPendingLinkedOutputIsBlocked() throws {
    let source=ProductObject(name:"Source",recipeID:"test",parameters:[:])
    var pending=ArtworkElement(kind:"image",x:0,y:0,asset:"pending.png")
    pending.objectView = .init(sourceID:source.id,style:"rendered",linked:true)
    pending.objectView?.renderPending=true
    var frozen=pending; frozen.id=UUID(); frozen.objectView?.linked=false
    let other=ArtworkElement(kind:"rectangle",x:0,y:0)
    let page=ProductObject(name:"Page",recipeID:"artboard",parameters:[:],artwork:Artwork(elements:[pending,frozen,other]))
    var project=Project(name:"Pending");project.objects=[source,page]
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:project,object:page))
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[pending.id.uuidString]))
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[frozen.id.uuidString]))
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[other.id.uuidString]))
  }

  private func publicationFixture() throws -> (project:Project,documentID:UUID,masterID:UUID,pageID:UUID,localID:UUID) {
    var project=Project(name:"Pending running furniture"),pages=[UUID]()
    for index in 0..<4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index+1)",parameters:["width":100,"depth":140])
      page.artwork = Artwork(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:45,y:70,width:15,height:20,color:"#21483F")])
      project.objects.append(page);pages.append(page.id)
    }
    let documentID=try PublicationCommands.createPublication(in:&project,name:"Running furniture output",pages:pages)
    var source=try project.makeObject(recipeID:"artboard",name:"Independent rendered source",parameters:["width":20,"depth":20])
    source.artwork = Artwork(elements:[]);project.objects.append(source)
    var pending=ArtworkElement(kind:"image",x:10,y:12,width:30,height:20,asset:"old.png")
    pending.objectView = .init(sourceID:source.id,style:"rendered",linked:true)
    pending.objectView?.renderPending=true
    var master=try project.makeObject(recipeID:"artboard",name:"Live master source",parameters:["width":100,"depth":140])
    master.artwork = Artwork(elements:[pending]);project.objects.append(master)
    var document=project.publications![0];document.masters=[.init(name:"Live master",sourceObjectID:master.id)]
    try PublicationCommands.setPublication(in:&project,document:document)
    return(project,documentID,master.id,pages[0],project.objects[0].artwork!.elements[0].id)
  }

  func testAppliedPendingMasterUsesEffectiveDerivedSelectionWhileFrozenUnappliedAndOtherSubsetsStayAllowed() throws {
    let fixture=try publicationFixture();var project=fixture.project
    let page=try XCTUnwrap(project.objects.first{$0.id==fixture.pageID})
    XCTAssertFalse(page.storedArtworks.flatMap(\.elements).contains{$0.objectView != nil})
    let effective=try XCTUnwrap(project.surfaceArtwork(page)),derived=try XCTUnwrap(effective.elements.first{$0.objectView?.renderPending==true})
    let original=try XCTUnwrap(project.objects.first{$0.id==fixture.masterID}?.artwork?.elements.first)
    XCTAssertNotEqual(derived.id,original.id)
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:project,object:page)) {
      XCTAssertTrue($0.localizedDescription.contains("linked object view is still updating"))
    }
    XCTAssertThrowsError(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[derived.id.uuidString]))
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page,elementIDs:[fixture.localID.uuidString]))
    let masterIndex=try XCTUnwrap(project.objects.firstIndex{$0.id==fixture.masterID})
    project.objects[masterIndex].artwork!.elements[0].objectView?.linked=false
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page))
    project.objects[masterIndex].artwork!.elements[0].objectView?.linked=true
    var document=project.publications![0];document.pages[0].masterIDs=[]
    try PublicationCommands.setPublication(in:&project,document:document)
    XCTAssertNoThrow(try ObjectViewExportGuard.validate(project:project,object:page))
  }

  func testPublicationPagesSpreadsAndBookletRejectPendingMasterPixelsBeforeWritingAndFrozenPixelsExport() throws {
    _=NSApplication.shared
    let fixture=try publicationFixture(),root=FileManager.default.temporaryDirectory.appendingPathComponent("pending-master-output-"+UUID().uuidString)
    let repository=try ProjectRepository(root:root),store=StudioStore(repository:repository,seedLibrary:false)
    defer {store.linkedObjectViews.reset();store.solids.reset();store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    let assets=repository.url(for:fixture.project.id).appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
    let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
    for y in 0..<8 {for x in 0..<8 {bitmap.setColor(.blue,atX:x,y:y)}}
    let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    try png.write(to:assets.appendingPathComponent("old.png"))
    XCTAssertNotNil(NSImage(contentsOf:assets.appendingPathComponent("old.png")),"A valid previous capture must exist; this regression is not a missing-asset failure.")
    store.engine.project=fixture.project
    for layout in ["pages","spreads","booklet"] {
      let path=root.appendingPathComponent("rejected-"+layout+".pdf")
      XCTAssertThrowsError(try store.publicationGraphicsCall("form_export_publication",["publication_id":fixture.documentID.uuidString,"layout":layout,"path":path.path])) {
        XCTAssertTrue($0.localizedDescription.contains("linked object view is still updating"))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
    }
    var frozen=fixture.project
    let masterIndex=try XCTUnwrap(frozen.objects.firstIndex{$0.id==fixture.masterID})
    frozen.objects[masterIndex].artwork!.elements[0].objectView?.linked=false
    store.engine.project=frozen
    for layout in ["pages","spreads","booklet"] {
      let path=root.appendingPathComponent("deliberately-frozen-"+layout+".pdf")
      _=try store.publicationGraphicsCall("form_export_publication",["publication_id":fixture.documentID.uuidString,"layout":layout,"path":path.path])
      let data=try Data(contentsOf:path),provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
      let pdf=try XCTUnwrap(CGPDFDocument(provider))
      XCTAssertEqual(pdf.numberOfPages,layout=="pages" ? 4:layout=="spreads" ? 3:2)
    }
    XCTAssertEqual(store.project,frozen,"Export must not rewrite canonical page/master sources.")
  }
}
