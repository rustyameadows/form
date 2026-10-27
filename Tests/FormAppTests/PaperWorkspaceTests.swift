import AppKit
import CryptoKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PaperWorkspaceTests:XCTestCase {
  private func fixture()throws->StudioStore {
    _ = NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("lab-paper-test-"+UUID().uuidString)
    let repository=try ProjectRepository(root:root),project=Samples.cyanotype()
    try repository.save(project)
    let store=StudioStore(repository:repository,seedLibrary:false)
    try store.engine.open(project.id);store.showingHome=false
    let paper=try XCTUnwrap(store.project?.objects.first(where:{PaperConstruction.isPaper($0)}))
    store.select(paper.id)
    addTeardownBlock {@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
    return store
  }
  func testPurposeRepresentationAndPanelSelectionDoNotChangeSourceOrUndo()throws {
    let store=try fixture(),object=try XCTUnwrap(store.primary),before=try XCTUnwrap(store.project)
    for environment in [ProjectEnvironment.form,.function,.fabricate] {
      store.showEnvironment(environment)
      for representation in PaperRepresentation.allCases {
        store.showPaper(representation,object:object,split:true)
        store.selectPaperPanel(objectID:object.id,panelID:"back")
        XCTAssertEqual(store.project,before)
        XCTAssertTrue(store.engine.undoStack.isEmpty)
        XCTAssertEqual(store.engine.selection,[object.id])
        XCTAssertEqual(store.environment,environment)
        XCTAssertEqual(store.surfaceLayout,.split)
      }
    }
  }
  func testInsideSourceEditsThroughNativeSessionAndSurvivesReconciliation()throws {
    let store=try fixture(),object=try XCTUnwrap(store.primary),outside=object.artwork
    store.createPaperInside(object)
    let current=try XCTUnwrap(store.primary),source=try XCTUnwrap(current.paperConstruction?.insideArtworkSourceID)
    XCTAssertEqual(store.engine.undoStack.count,1)
    store.artworkSession.reconcile()
    XCTAssertEqual(store.artworkSession.objectID,source)
    var artwork=store.artworkSession.art
    artwork.elements.append(.init(kind:"text",x:20,y:30,width:60,height:12,text:"Made for sunlight",fontSize:11))
    try store.engine.edit("Edit inside source") {try $0.setArtwork(artwork,for:source)}
    XCTAssertEqual(store.project?.paperArtwork(for:current,inside:true)?.elements.last?.text,"Made for sunlight")
    XCTAssertEqual(store.primary?.artwork,outside)
    store.engine.undo()
    XCTAssertFalse(store.project?.paperArtwork(for:current,inside:true)?.elements.contains(where:{$0.text=="Made for sunlight"}) == true)
    store.engine.redo()
    try store.engine.flush();let reopened=try store.repository.load(store.project!.id)
    XCTAssertEqual(reopened.paperArtwork(for:reopened.objects.first{$0.id==current.id}!,inside:true)?.elements.last?.text,"Made for sunlight")
  }
  func testPrintActionUsesPaperPreparationAndRetainsCamera()throws {
    let store=try fixture(),before=store.project!
    store.prepareSelectedPrint()
    XCTAssertEqual(store.environment,.fabricate);XCTAssertEqual(store.paperRepresentation,.sheet)
    XCTAssertEqual(store.surfaceLayout,.split);XCTAssertFalse(store.showingPrint)
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testPhysicalPacketHasExactSheetPagesSeparateOperationsAndVerifiedArtifacts()throws {
    let store=try fixture(),object=store.primary!,before=store.project!
    let output=store.repository.url(for:before.id).appendingPathComponent("Exports/Proofs",isDirectory:true)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let packet=output.appendingPathComponent("prototype.paperjob")
    _ = try store.paperOutputCall(["command":"export","object_id":object.id.uuidString,"format":"packet","path":packet.path,"sheet_width":700,"sheet_height":1000,"count":3])
    let data=try Data(contentsOf:packet.appendingPathComponent("production.json")),record=try JSONSerialization.jsonObject(with:data) as! [String:Any]
    let hashes=try XCTUnwrap(record["artifact_sha256"] as? [String:String])
    for (name,digest) in hashes {XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:packet.appendingPathComponent(name))).map{String(format:"%02x",$0)}.joined(),digest)}
    let pdf=try XCTUnwrap(CGPDFDocument(packet.appendingPathComponent("sheet-proof.pdf") as CFURL))
    let layout=try PaperOutput.layout(store:store,definition:.definition(for:object))
    XCTAssertEqual(pdf.numberOfPages,layout.sheetCount)
    let box=try XCTUnwrap(pdf.page(at:1)).getBoxRect(.mediaBox)
    XCTAssertEqual(box.width,700*72/25.4,accuracy:0.01);XCTAssertEqual(box.height,1000*72/25.4,accuracy:0.01)
    let cuts=try String(contentsOf:packet.appendingPathComponent("cut-crease.svg"),encoding:.utf8)
    XCTAssertTrue(cuts.contains("id=\"cut\""));XCTAssertTrue(cuts.contains("id=\"crease\""));XCTAssertFalse(cuts.contains("<g id=\"artwork\""))
    XCTAssertEqual(store.project,before);XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertThrowsError(try store.paperOutputCall(["command":"export","object_id":object.id.uuidString,"format":"packet","path":packet.path]))
    XCTAssertEqual(try Data(contentsOf:packet.appendingPathComponent("production.json")),data)
  }
  func testInvalidLayoutAndSourceFolderExportsAreRejectedWithoutMutation()throws {
    let store=try fixture(),object=store.primary!,before=store.project!
    let output=store.repository.url(for:before.id).appendingPathComponent("Exports/invalid-paper-output.pdf")
    XCTAssertThrowsError(try store.paperOutputCall(["command":"export","object_id":object.id.uuidString,"format":"pdf","path":output.path,"sheet_width":100,"sheet_height":100]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    let asset=store.repository.url(for:before.id).appendingPathComponent("Assets/invalid.svg")
    XCTAssertThrowsError(try store.paperOutputCall(["command":"export","object_id":object.id.uuidString,"format":"svg","path":asset.path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:asset.path));XCTAssertEqual(store.project,before)
    let nested=store.repository.url(for:before.id).appendingPathComponent("Assets/nested.form/Exports",isDirectory:true)
    try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
    let nestedFile=nested.appendingPathComponent("rejected.svg")
    XCTAssertThrowsError(try store.paperOutputCall(["command":"export","object_id":object.id.uuidString,"format":"svg","path":nestedFile.path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:nestedFile.path))
  }
  func testVisibleArtworkRecoversAfterInvalidPreviewAndUndo()throws {
    let store=try fixture(),object=store.primary!
    let view=PaperConstructionPreviewView(frame:.init(x:0,y:0,width:640,height:720))
    view.store=store;view.object=object;view.representation = .dieline;view.synchronize()
    func pixels()throws->Data {
      let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
      view.cacheDisplay(in:view.bounds,to:rep)
      return try XCTUnwrap(rep.representation(using:.png,properties:[:]))
    }
    let before=try pixels()
    var invalid=object;invalid.parameters["width"] = -1
    view.object=invalid;view.synchronize();XCTAssertNotEqual(try pixels(),before)
    view.object=object;view.synchronize();XCTAssertEqual(try pixels(),before)
  }
}
