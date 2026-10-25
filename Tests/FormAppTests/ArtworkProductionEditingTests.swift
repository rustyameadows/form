import AppKit
import PDFKit
import XCTest
@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class ArtworkProductionEditingTests:XCTestCase {
  private func fixture() throws -> (StudioStore,URL,UUID,UUID,UUID,UUID) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ProjectRepository(root:root)
    var p = Project(name:"Manufacturing-aware artwork")
    var source = try p.makeObject(recipeID:"artboard",name:"Production master",parameters:["width":200,"depth":120])
    let print = ArtworkElement(kind:"rectangle",x:10,y:10,width:40,height:30,color:"#B83328")
    var cut = ArtworkElement(kind:"rectangle",x:10,y:10,width:40,height:30,color:"#285B8A"); cut.productionRole = "cut"
    var guide = ArtworkElement(kind:"line",x:80,y:10,width:60,height:0.1); guide.productionRole = "guide"
    guide.stroke = .init(color:"#5E8D81",width:0.3)
    source.artwork = Artwork(background:"#F6F1E7",elements:[print,cut,guide],bleed:0)
    var product = try p.makeObject(recipeID:"box",name:"Linked product",parameters:["width":200,"depth":120,"height":10])
    product.artwork = nil; product.artworkSourceID = source.id; product.artworkFit = "actual"
    p.objects = [source,product]; p.schemaVersion = p.minimumSchemaVersion
    try repository.save(p)
    let store = StudioStore(repository:repository,seedLibrary:false)
    try store.engine.open(p.id)
    store.showingHome = false; store.mode = .artwork
    store.artworkSession.objectID = source.id
    return (store,root,source.id,product.id,print.id,cut.id)
  }
  private func clean(_ store:StudioStore,_ root:URL) {
    store.engine.project = nil
    try? FileManager.default.removeItem(at:root)
  }
  func testNativeAndMCPRoleAssignmentsShareUndoAndAtomicRollback() throws {
    let (store,root,source,product,print,cut) = try fixture(); defer {clean(store,root)}
    let before = store.project!
    store.artworkSession.choose([print])
    store.artworkSession.execute("production",["role":"engrave"])
    XCTAssertNil(store.error)
    let assigned = store.project!
    XCTAssertEqual(assigned.editableArtwork(assigned.objects.first {$0.id == source}!)?.elements.first {$0.id == print}?.productionRole,"engrave")
    XCTAssertEqual(assigned.objects.first {$0.id == product},before.objects.first {$0.id == product})
    store.engine.undo(); XCTAssertEqual(store.project,before)
    store.engine.redo(); XCTAssertEqual(store.project,assigned)
    let bad:[String:Any] = ["operations":[
      ["name":"form_edit_artwork","arguments":["object_id":product.uuidString,"command":"production","element_ids":[cut.uuidString],"role":"print"]],
      ["name":"form_edit_artwork","arguments":["object_id":product.uuidString,"command":"production","element_ids":[print.uuidString],"role":"unknown"]],
    ]]
    XCTAssertThrowsError(try store.engine.call("form_batch",arguments:bad))
    XCTAssertEqual(store.project,assigned)
    _ = try store.engine.call("form_edit_artwork",arguments:["object_id":product.uuidString,"command":"production","element_ids":[cut.uuidString],"role":"print"])
    XCTAssertEqual(store.project!.schemaVersion,22)
    XCTAssertEqual(store.project!.objects.first {$0.id == product},before.objects.first {$0.id == product})
    store.engine.undo(); XCTAssertEqual(store.project,assigned)
  }
  func testExportsSeparatePhysicalRolesAndLeaveTheSourceAndHistoryExact() throws {
    let (store,root,source,_,_,_) = try fixture(); defer {clean(store,root)}
    let before = store.project!,object = before.objects.first {$0.id == source}!
    let svg = root.appendingPathComponent("production.svg"),pdf = root.appendingPathComponent("production.pdf")
    let roles = ["print","cut","score","stitch","engrave"]
    let a = try store.exportArtwork(object:object,arguments:["format":"svg","path":svg.path,"roles":roles]) as! [String:Any]
    let b = try store.exportArtwork(object:object,arguments:["format":"pdf","path":pdf.path,"roles":roles]) as! [String:Any]
    XCTAssertEqual(a["roles"] as? [String],["print","cut"])
    XCTAssertEqual(b["roles"] as? [String],["print","cut"])
    let text = try String(contentsOf:svg,encoding:.utf8)
    XCTAssertTrue(text.contains("data-form-role=\"print\"")); XCTAssertTrue(text.contains("data-form-role=\"cut\""))
    XCTAssertFalse(text.contains("data-form-role=\"guide\""))
    let document = try XCTUnwrap(PDFDocument(url:pdf))
    XCTAssertEqual(document.pageCount,2)
    XCTAssertEqual(document.page(at:0)!.bounds(for:.mediaBox).width,200*72/25.4,accuracy:0.001)
    XCTAssertEqual(document.page(at:1)!.bounds(for:.mediaBox).height,120*72/25.4,accuracy:0.001)
    XCTAssertEqual(store.project,before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    let guide = root.appendingPathComponent("guide-reference.svg")
    _ = try store.exportArtwork(object:object,arguments:["format":"svg","path":guide.path,"roles":["guide"]])
    XCTAssertTrue(try String(contentsOf:guide,encoding:.utf8).contains("data-form-role=\"guide\""))
    XCTAssertEqual(store.project,before)
  }
  func testLockedCanonicalSourceRejectsRoleChangesThroughALinkedProduct() throws {
    let (store,root,source,product,print,_) = try fixture(); defer {clean(store,root)}
    let index = store.project!.objects.firstIndex {$0.id == source}!
    store.engine.project!.objects[index].locked = true
    let before = store.project!
    XCTAssertThrowsError(try store.engine.call("form_edit_artwork",arguments:["object_id":product.uuidString,"command":"production","element_ids":[print.uuidString],"role":"cut"]))
    XCTAssertEqual(store.project,before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
  }
  func testInvalidTechnicalOutputNeverReplacesAnExistingFile() throws {
    let (store,root,source,_,_,cut) = try fixture(); defer {clean(store,root)}
    let i = store.project!.objects.firstIndex {$0.id == source}!
    let e = store.project!.objects[i].artwork!.elements.firstIndex {$0.id == cut}!
    store.engine.project!.objects[i].artwork!.elements[e].kind = "image"
    let before = store.project!,object = before.objects[i]
    let path = root.appendingPathComponent("keep-existing.svg")
    let sentinel = Data("Existing approved output".utf8); try sentinel.write(to:path)
    XCTAssertThrowsError(try store.exportArtwork(object:object,arguments:["format":"svg","path":path.path,"roles":["cut"]]))
    XCTAssertEqual(try Data(contentsOf:path),sentinel)
    XCTAssertEqual(store.project,before)
    XCTAssertThrowsError(try store.exportArtwork(object:object,arguments:["format":"svg","path":path.path,"roles":["laser-power"]]))
    XCTAssertEqual(try Data(contentsOf:path),sentinel)
  }
  func testNativeOverlayVisibilityChangesPickingWithoutChangingSavedRoleOrHistory() throws {
    let (store,root,_,_,print,cut) = try fixture(); defer {clean(store,root)}
    let session = store.artworkSession
    let window = NSWindow(contentRect:.init(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame:window.contentView!.bounds)
    let canvas = VectorCanvasView(frame:scroll.bounds)
    canvas.session = session; session.canvas = canvas; scroll.documentView = canvas
    window.contentView = scroll; window.makeFirstResponder(canvas)
    defer {canvas.finishText(); window.contentView = nil; window.close()}
    canvas.synchronize(); canvas.fit(all:true)
    let before = store.project!
    func click() {
      session.choose([])
      let frame = session.frames.first {$0.id == session.objectID}!
      let location = canvas.convert(canvas.documentPoint(.init(x:frame.rect.minX+25,y:frame.rect.minY+25)),to:nil)
      for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
        let event = NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:0,
          windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0:1)!
        if type == .leftMouseDown {canvas.mouseDown(with:event)} else {canvas.mouseUp(with:event)}
      }
    }
    click(); XCTAssertEqual(session.selection,[cut])
    session.setProductionOverlay(.cut,visible:false)
    XCTAssertTrue(session.selection.isEmpty)
    click(); XCTAssertEqual(session.selection,[print])
    session.setProductionOverlay(.cut,visible:true)
    click(); XCTAssertEqual(session.selection,[cut])
    XCTAssertEqual(store.project,before)
    XCTAssertTrue(store.engine.undoStack.isEmpty)
    XCTAssertFalse(window.isVisible)
  }
}
