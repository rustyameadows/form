import AppKit
import CryptoKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class PaperProductionOutputTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID,URL) {
    _=NSApplication.shared
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:folder.appendingPathComponent("Library")),seedLibrary:false)
    store.engine.project=Project(name:"Paper handoff")
    let parameters:[CADModelParameter]=[.init("width",100,50...150),.init("height",80,40...120),.init("stock",0.6,0.1...2)]
    let points:[CADExpressionPoint2]=[.init(0,0),.init("width",0),.init("width","height"),.init(0,"height")]
    let definition=PlanarConstructionDefinition(name:"Test sheet",parameters:parameters,size:.init("width","height"),stockThickness:"stock",panels:[.init(id:"front",name:"Front",polygon:points)],rootPanelID:"front")
    let result=try store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as! [String:Any]
    let id=UUID(uuidString:result["object_id"] as! String)!
    addTeardownBlock{@MainActor in store.engine.project=nil;try? FileManager.default.removeItem(at:folder)}
    return(store,id,folder)
  }
  func testPacketSeparatesBlindAndFoilFromOrdinaryInkAndRejectsMissingEnabledTargets()throws {
    let(store,id,folder)=try fixture()
    let ink=ArtworkElement(kind:"text",x:8,y:12,width:70,height:10,text:"Registered ink",color:"#123456",fontSize:12)
    let foil=ArtworkElement(kind:"rectangle",x:10,y:40,width:10,height:10,color:"#CC5500")
    let blind=ArtworkElement(kind:"ellipse",x:35,y:40,width:10,height:10,color:"#AA00BB")
    var art=Artwork(background:"#FFFFFF",elements:[ink,foil,blind]);art.backgroundOpacity=0
    _=try store.engine.call("form_set_artwork",arguments:["object_id":id.uuidString,"artwork":try jsonObject(art)])
    let f=PaperFinishAssignment(name:"Foil",kind:.foil,elementIDs:[foil.id],color:"#CCAA55")
    let b=PaperFinishAssignment(name:"Blind",kind:.emboss,elementIDs:[blind.id],heightMM:0.08)
    for finish in [f,b] {_ = try store.engine.call("form_paper",arguments:["command":"set_finish","object_id":id.uuidString,"finish":try jsonObject(finish)])}
    let accepted=store.project!,undos=store.engine.undoStack.count,path=folder.appendingPathComponent("handoff")
    _=try store.paperOutputCall(["command":"export","object_id":id.uuidString,"format":"packet","path":path.path,"bleed_mm":3,"count":1])
    let ordinary=try String(contentsOf:path.appendingPathComponent("outside-artwork.svg"))
    XCTAssertFalse(ordinary.lowercased().contains("#cc5500"));XCTAssertFalse(ordinary.lowercased().contains("#aa00bb"))
    XCTAssertTrue(ordinary.contains("viewBox=\"-3.0 -3.0 106.0 86.0\""))
    for finish in [f,b] {XCTAssertTrue(FileManager.default.fileExists(atPath:path.appendingPathComponent("finish-"+finish.id.uuidString.lowercased()+".svg").path))}
    let record=try JSONSerialization.jsonObject(with:Data(contentsOf:path.appendingPathComponent("production.json"))) as! [String:Any]
    XCTAssertEqual((record["finishing_plates"] as? [[String:Any]])?.count,2)
    XCTAssertEqual(record["bleed_mm"] as? Double,3)
    XCTAssertEqual(store.project!.objects,accepted.objects);XCTAssertEqual(store.engine.undoStack.count,undos)
    _=try store.engine.call("form_edit_artwork",arguments:["object_id":id.uuidString,"command":"delete","element_ids":[foil.id.uuidString]])
    let failed=folder.appendingPathComponent("missing-target")
    XCTAssertThrowsError(try store.paperOutputCall(["command":"export","object_id":id.uuidString,"format":"packet","path":failed.path,"count":1]))
    XCTAssertFalse(FileManager.default.fileExists(atPath:failed.path))
  }
  func testRetainedSupplierSVGIsByteExactAndRegistrationDoesNotChangeItsTechnicalPaths()throws {
    let(store,id,folder)=try fixture()
    let xml="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120mm\" height=\"100mm\" viewBox=\"-10 -10 120 100\"><g id=\"supplier-cut\" fill=\"none\" stroke=\"red\"><path d=\"M0,0 L100,0 L100,80 L0,80 Z\"/></g><g id=\"notes\"><text x=\"0\" y=\"-4\" font-size=\"2\">DO NOT PRINT NOTES</text></g></svg>"
    let file=folder.appendingPathComponent("vendor.svg");try xml.write(to:file,atomically:true,encoding:.utf8)
    var args:[String:Any]=["command":"template_attach","object_id":id.uuidString,"path":file.path,"instructions":"Return separate artwork at actual size; retain original.","technical_mapping":[["elementID":"supplier-cut","kind":"cut"],["elementID":"notes","kind":"instructions"]]]
    XCTAssertThrowsError(try store.paperTemplateCall(args),"Margins require an explicit registration, not a guessed offset")
    args["canonical_to_template"]=try jsonObject(Affine2())
    _=try store.paperTemplateCall(args)
    let object=store.project!.objects.first{$0.id==id}!,ref=try XCTUnwrap(object.paperTemplateReference)
    let assets=store.repository.url(for:store.project!.id).appendingPathComponent("Assets")
    XCTAssertEqual(try Data(contentsOf:assets.appendingPathComponent(ref.originalAsset)),Data(xml.utf8))
    XCTAssertEqual(try PaperTemplateOperations.original(ref,assets:assets),Data(xml.utf8))
    let element=ArtworkElement(kind:"text",x:10,y:10,width:70,height:12,text:"Registered artwork",color:"#223344",fontSize:12)
    var art=Artwork(elements:[element]);art.backgroundOpacity=0
    _=try store.engine.call("form_set_artwork",arguments:["object_id":id.uuidString,"artwork":try jsonObject(art)])
    let output=folder.appendingPathComponent("registered.svg")
    _=try store.paperOutputCall(["command":"export","object_id":id.uuidString,"format":"svg","path":output.path,"handoff":"registered_original","bleed_mm":3])
    let actual=try String(contentsOf:output)
    XCTAssertTrue(actual.contains("<path d=\"M0,0 L100,0 L100,80 L0,80 Z\"/>"))
    XCTAssertTrue(actual.contains("lab-registered-artwork"));XCTAssertTrue(actual.contains("matrix(1.0 0.0 0.0 1.0 0.0 0.0)"))
    _=try store.engine.call("form_construction",arguments:["command":"parameter","object_id":id.uuidString,"values":["width":105]])
    XCTAssertThrowsError(try store.paperOutputCall(["command":"export","object_id":id.uuidString,"format":"svg","path":folder.appendingPathComponent("stale.svg").path,"handoff":"registered_original"]))
  }
  func testSafetyReviewIncludesInteriorCutsWithoutEditingArtwork()throws {
    let(store,id,_)=try fixture()
    var definition=try PaperConstruction.definition(for:store.project!.objects.first{$0.id==id}!)
    var source=definition.authored!
    source.version=3
    source.panels[0].cutouts=[.init(id:"hole",polygon:[.init(40,35),.init(50,35),.init(50,45),.init(40,45)],kind:.window)]
    definition.authored=source
    _=try store.engine.call("form_paper",arguments:["command":"configure","object_id":id.uuidString,"definition":try jsonObject(definition)])
    let text=ArtworkElement(kind:"text",x:39,y:32,width:16,height:7,text:"Review",color:"#000000",fontSize:10)
    var art=Artwork(elements:[text]);art.backgroundOpacity=0
    _=try store.engine.call("form_set_artwork",arguments:["object_id":id.uuidString,"artwork":try jsonObject(art)])
    let p=store.project!,undo=store.engine.undoStack.count
    let review=try PaperProductionReview.inspect(object:p.objects.first{$0.id==id}!,project:p)
    XCTAssertTrue((review["issues"] as! [[String:Any]]).contains{$0["code"] as? String=="typeNearCut"})
    XCTAssertEqual(store.project!.objects,p.objects);XCTAssertEqual(store.engine.undoStack.count,undo)
  }
}
