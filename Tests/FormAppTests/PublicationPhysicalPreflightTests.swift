import AppKit
import XCTest
import FormCore
import FormGraphics
@testable import FormApp

@MainActor final class PublicationPhysicalPreflightTests:XCTestCase {
  func testNativeInspectorPreflightUsesPhysicalInkRouteAndRejectsAChromaticColoredFace()throws {
    _=NSApplication.shared
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("native-physical-preflight-"+UUID().uuidString)
    let store=StudioStore(repository:try .init(root:folder),seedLibrary:false)
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:folder)}
    var project=Project(name:"Shared native and public physical preflight")
    let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
    let profile=try ICCOutputProfile(url:URL(fileURLWithPath:"/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"));try profile.store(in:assets)
    let ink=try SwatchCommands.save(in:&project,name:"Actual K",color:"#000000",printInk:.init(kind:.processCMYK,components:.init(0,0,0,1),profile:profile.reference))
    for index in 1...4 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":100,"depth":140])
      var mark=ArtworkElement(kind:"rectangle",x:12,y:20,width:30,height:40,color:"#000000");mark.fillSwatchID=ink
      var art=Artwork(elements:[mark],bleed:0);art.backgroundOpacity=0;art.outputColorProfile=profile.reference;page.artwork=art;project.objects.append(page)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Declared colored parent",pages:project.objects.map(\.id))
    let entries=project.publications![0].pages,stock=PaperStock(thicknessMM:0.2,profile:.init(color:"#D3BA76"))
    var definition=SheetAssemblyDefinition(publicationID:publication,stock:stock)
    definition.parentSheets=[.init(frontPageIDs:[entries[3].id,entries[0].id],backPageIDs:[entries[1].id,entries[2].id],stock:stock,sizeMM:.init(200,140),printIntent:.blackOnly)]
    let physical=try SheetAssemblyCommands.create(in:&project,definition:definition)
    store.engine.project=project;let before=project,undo=store.engine.undoStack.count
    // The older arranged path is precisely the wrong report for this valid job.
    XCTAssertEqual(PublicationOutput.arrangedPreflight(project,documentID:publication,assets:assets,layout:.booklet)["can_export"] as? Bool,false)
    let native=try store.publicationPreflightReport(publication,layout:.booklet)
    let shared=try XCTUnwrap(try store.publicationGraphicsCall("form_publication",["command":"preflight","publication_id":publication.uuidString,"output_layout":"booklet"]) as? [String:Any])
    XCTAssertEqual(native["can_export"] as? Bool,true);XCTAssertEqual(shared["can_export"] as? Bool,true)
    XCTAssertEqual(native["physical_object_id"] as? String,physical.uuidString)
    XCTAssertEqual(native["substrate_is_printed"] as? Bool,false);XCTAssertEqual(native["parent_sheet_count"] as? Int,1)
    XCTAssertEqual(store.project,before);XCTAssertEqual(store.engine.undoStack.count,undo)
    try store.engine.edit("Chromatic paint on colored stock"){project in project.objects[0].artwork!.elements[0].fillSwatchID=nil;project.objects[0].artwork!.elements[0].color="#EE0033"}
    let changed=try XCTUnwrap(store.project),changedUndo=store.engine.undoStack.count
    let rejected=try store.publicationPreflightReport(publication,layout:.pages)
    XCTAssertEqual(rejected["can_export"] as? Bool,false)
    XCTAssertTrue((rejected["issues"] as? [[String:Any]] ?? []).contains{$0["code"] as? String=="physical_print"})
    XCTAssertEqual(store.project,changed);XCTAssertEqual(store.engine.undoStack.count,changedUndo)
    store.engine.undo();XCTAssertEqual(store.project,before)
  }
}
