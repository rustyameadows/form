import AppKit
import FormCADModel
import FormCore
import XCTest
@testable import FormApp

@MainActor final class PaperWrappingControlsTests:XCTestCase {
  func testOrdinaryWrappedPanelsShareMaterialEditingPreserveSourceAndRejectStaleTargetsAtomically()throws {
    _=NSApplication.shared
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    store.engine.project=Project(name:"Independent wrapped planes")
    let wrap=SheetPanelWrap(stock:.init(name:"Bonded wrapping sheet",thicknessMM:0.12,profile:.init(texture:.cotton,color:"#D8C7A4"),plies:[
      .init(name:"Backing",color:"#C4B08E",thicknessMM:0.06),
      .init(name:"Face",color:"#D8C7A4",thicknessMM:0.06,profile:.init(texture:.linen,color:"#D8C7A4",roughness:0.9))]),turnInMM:5)
    let definition=PlanarConstructionDefinition(name:"Two connected wrapped panels",parameters:[.init("core",1.2,0.5...3)],size:.init(200,140),stockThickness:"core",panels:[
      .init(id:"left",name:"Left plane",polygon:[.init(0,0),.init(100,0),.init(100,140),.init(0,140)],features:.init(wrap:wrap)),
      .init(id:"right",name:"Right plane",polygon:[.init(100,0),.init(200,0),.init(200,140),.init(100,140)],features:.init(wrap:wrap))
    ],hinges:[.init(id:"joint",parentPanelID:"left",childPanelID:"right",start:.init(100,0),end:.init(100,140),angleDegrees:90)],rootPanelID:"left")
    let response=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let id=try XCTUnwrap((response["object_id"] as? String).flatMap(UUID.init(uuidString:)))
    var source=try XCTUnwrap(store.project),index=try XCTUnwrap(source.objects.firstIndex{$0.id==id})
    // The source includes the real 1.2 mm core sidewall plus 5 mm turn-in.
    // A printed wrapped panel with zero source bleed is correctly rejected.
    source.objects[index].artwork = .init(background:"#FFFFFF",elements:[.init(kind:"text",x:12,y:15,width:70,height:16,text:"Unchanged printed ink",color:"#173A52")],bleed:8)
    source.objects[index].artwork?.backgroundOpacity=0
    source.objects[index].paperConstruction!.annotations=[.init(text:"Retain source note",panelID:"right")]
    source.objects[index].paperConstruction!.stock.profile = .init(texture:.laid,color:"#F0E9D8",roughness:0.84)
    try source.validateArtworkLinks()
    store.engine.project=source
    let before=try XCTUnwrap(store.project),history=store.engine.undoStack.count
    var edited=wrap;edited.stock.name="Reviewed linen wrap"
    SheetStockControlEditing.setSurface(in:&edited.stock){$0.roughness=0.31}
    SheetParentStockEditing.setColor("#F3E6A4",plyID:edited.stock.plies![1].id,in:&edited.stock)
    XCTAssertTrue(PaperPanelWrappingEditing.replace(session:store.artworkSession,projectID:before.id,objectID:id,panelID:"left",wrap:edited),store.error ?? "No wrapping diagnostic")
    let after=try XCTUnwrap(store.project),changed=try XCTUnwrap(after.objects.first{$0.id==id})
    var expected=try XCTUnwrap(before.objects.first{$0.id==id}?.paperConstruction?.authored)
    expected.panels[0].features!.wrap=edited
    XCTAssertEqual(changed.paperConstruction?.authored,expected)
    XCTAssertEqual(changed.paperConstruction?.stock,before.objects[index].paperConstruction?.stock)
    XCTAssertEqual(changed.paperConstruction?.annotations,before.objects[index].paperConstruction?.annotations)
    XCTAssertEqual(changed.artwork,before.objects[index].artwork)
    XCTAssertFalse(try XCTUnwrap(changed.paperConstruction).artworkReviewRequired)
    XCTAssertEqual(after.camera,before.camera);XCTAssertEqual(after.objects.filter{$0.id != id},before.objects.filter{$0.id != id})
    let net=try PaperConstruction.definition(for:changed).net(),physical=try XCTUnwrap(net.panels.first{$0.id=="left"}?.features?.wrap)
    XCTAssertEqual(physical.stock.profile?.roughness,0.31)
    XCTAssertEqual(physical.stock.plies!.last?.profile?.roughness,0.31)
    XCTAssertEqual(physical.stock.plies!.last?.profile?.color,"#F3E6A4")
    XCTAssertEqual(net.panels.first{$0.id=="right"}?.features?.wrap?.stock,wrap.stock)
    XCTAssertEqual(store.engine.undoStack.count,history+1)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(after))
    XCTAssertEqual(reopened.objects,after.objects);XCTAssertEqual(reopened.camera,after.camera)
    for target in [(UUID(),id,"left"),(before.id,UUID(),"left"),(before.id,id,"removed")] {
      XCTAssertFalse(PaperPanelWrappingEditing.replace(session:store.artworkSession,projectID:target.0,objectID:target.1,panelID:target.2,wrap:wrap))
      XCTAssertEqual(store.project,after);XCTAssertEqual(store.engine.undoStack.count,history+1)
    }
    var invalid=edited;invalid.stock.profile!.roughness=2
    XCTAssertFalse(PaperPanelWrappingEditing.replace(session:store.artworkSession,projectID:before.id,objectID:id,panelID:"left",wrap:invalid))
    XCTAssertEqual(store.project,after);XCTAssertEqual(store.engine.undoStack.count,history+1)
    store.engine.undo();XCTAssertEqual(store.project,before)
    store.engine.redo();XCTAssertEqual(store.project,after)
  }
}
