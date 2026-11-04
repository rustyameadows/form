import AppKit
import Foundation
import PDFKit
import FormCore
import FormGraphics
import FormCADModel
import XCTest
@testable import FormApp

@MainActor final class ConstructionPacketOutputTests:XCTestCase {
  private func fixture()throws->(StudioStore,UUID,URL,UUID) {
    _=NSApplication.shared
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:root),seedLibrary:false)
    store.engine.project=Project(name:"Generic cutting source")
    let production=ConstructionProductionDefinition(materials:[.init(id:"sheet",name:"Explicit material sheets",componentIDs:["plate","facing"],widthMM:210,lengthMM:297,marginMM:8,spacingMM:4,grain:.unrestricted)],steps:[
      .init(id:"cut",title:"Prepare the separate pieces",componentIDs:["plate","facing"],instructions:"Cut both actual contours. Apply the identified facing to the plate in its registered orientation; retain the specified reverse face.")],assumptions:["Nominal calipers from declared samples; no physical machine operation."],guides:[.init(id:"reference",componentID:"facing",role:.turnIn,points:[.init(2,25),.init(43,25)],label:"Placement reference")],views:[.init(id:"assembly",title:"Independent physical pieces"),.init(id:"section",title:"Nominal ply section",projection:.side,sectionAxis:.x,sectionOffsetMM:0)])
    let definition=PlanarConstructionDefinition(name:"Independent panel pair",size:.init(150,80),stockThickness:2,panels:[
      .init(id:"plate-panel",name:"Support plate",polygon:[.init(0,0),.init(45,0),.init(45,30),.init(0,30)]),
      .init(id:"facing-panel",name:"Facing",polygon:[.init(70,0),.init(115,0),.init(115,30),.init(70,30)])],rootPanelID:"plate-panel",components:[
        .init(id:"plate",name:"Actual plate",rootPanelID:"plate-panel",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),stock:.init(name:"Support board",thicknessMM:2,grain:.parallelHeight,profile:.init(texture:.recycled,color:"#AD9A7D"))),
        .init(id:"facing",name:"Actual facing",rootPanelID:"facing-panel",anchor:.init(70,0),position:.init(0,2.1,0),rotationDegrees:.init(-90,0,0),stock:.init(name:"Pale yellow facing stock",thicknessMM:0.1,grain:.parallelHeight,profile:.init(texture:.cotton,color:"#E5D995")))],production:production)
    let response=try XCTUnwrap(store.engine.call("form_construction",arguments:["command":"create","definition":try jsonObject(definition)]) as? [String:Any])
    let id=try XCTUnwrap((response["object_id"] as? String).flatMap(UUID.init(uuidString:)))
    var project=try XCTUnwrap(store.project)
    var ink=try project.makeObject(recipeID:"artboard",name:"Canonical facing ink",parameters:["width":70,"depth":60])
    let mark=ArtworkElement(kind:"rectangle",x:15,y:19,width:20,height:8,color:"#124567")
    ink.artwork=Artwork(background:"#FFFFFF",elements:[mark],bleed:0);ink.artwork?.backgroundOpacity=0;ink.canvasSourceOnly=true
    project.objects.append(ink)
    let index=try XCTUnwrap(project.objects.firstIndex{$0.id==id})
    project.objects[index].paperConstruction!.authored!.components![1].front = .init(sourceObjectID:ink.id,sourceOriginMM:.init(5,7))
    project.objects[index].paperConstruction!.authored!.components![1].finishes=[.init(name:"Registered foil",kind:.foil,elementIDs:[mark.id],color:"#A78742",metallic:0.9)]
    try project.validateArtworkLinks();store.engine.project=project
    return(store,id,root,ink.id)
  }
  private func release(_ store:StudioStore,_ root:URL) {store.engine.project=nil;try? FileManager.default.removeItem(at:root)}
  func testPacketRetainsActualPiecesMasksScaleSourceAndImmutableRevision()throws {
    let(store,id,root,inkID)=try fixture();defer{release(store,root)}
    let before=try XCTUnwrap(store.project),owner=try XCTUnwrap(before.objects.first{$0.id==id}),destination=store.repository.url(for:before.id).appendingPathComponent("Exports/reviewed-packet")
    XCTAssertThrowsError(try ConstructionPacketOutput.export(store:store,objectID:id,arguments:["command":"export","format":"packet","path":root.appendingPathComponent("authoritative-data").path]))
    let preflight=try XCTUnwrap(store.engine.call("form_paper",arguments:["command":"preflight","object_id":id.uuidString]) as? [String:Any])
    XCTAssertEqual(preflight["piece_count"] as? Int,2)
    let result=try XCTUnwrap(store.engine.call("form_paper",arguments:["command":"export","object_id":id.uuidString,"format":"packet","path":destination.path]) as? [String:Any])
    XCTAssertEqual(store.project,before);XCTAssertEqual(result["piece_count"] as? Int,2)
    let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("Manifest.json"))) as? [String:Any])
    XCTAssertEqual(manifest["source_material_color_is_printed"] as? Bool,false);XCTAssertEqual(manifest["tool_compensation_applied"] as? Bool,false)
    let descriptors=try XCTUnwrap(manifest["files"] as? [[String:Any]])
    for file in descriptors {let path=try XCTUnwrap(file["path"] as? String),data=try Data(contentsOf:destination.appendingPathComponent(path));XCTAssertEqual(ConstructionMaterialLayouts.digest(data),file["sha256"] as? String)}
    let printed=try XCTUnwrap(descriptors.first{($0["path"] as? String)?.contains("front-artwork.svg")==true && ($0["path"] as? String)?.contains("Pieces/facing-")==true}?["path"] as? String)
    let printSVG=try String(contentsOf:destination.appendingPathComponent(printed),encoding:.utf8)
    XCTAssertFalse(printSVG.contains("#E5D995"),"The pale yellow stock must never become printed yellow ink.")
    XCTAssertFalse(printSVG.contains("data-role=\"turnIn\""));XCTAssertFalse(printSVG.contains("crease"))
    let mask=try XCTUnwrap(descriptors.first{($0["path"] as? String)?.contains("/finish-front-")==true}?["path"] as? String)
    let maskSVG=try String(contentsOf:destination.appendingPathComponent(mask),encoding:.utf8);XCTAssertTrue(maskSVG.contains("#000000"))
    let pdf=try XCTUnwrap(PDFDocument(url:destination.appendingPathComponent("Actual-size-pattern-proofs.pdf")));XCTAssertEqual(pdf.pageCount,2)
    let first=try XCTUnwrap(pdf.page(at:0));XCTAssertEqual(first.bounds(for:.mediaBox).width,160*72/25.4,accuracy:0.02)
    XCTAssertTrue((pdf.string ?? "").contains("45.000 × 30.000"))
    let assembly=try XCTUnwrap(PDFDocument(url:destination.appendingPathComponent("Assembly-and-sections.pdf")))
    XCTAssertTrue((assembly.string ?? "").contains("Apply the identified facing"));XCTAssertFalse((assembly.string ?? "").contains("dust flaps"))
    let current=try XCTUnwrap(store.engine.call("form_paper",arguments:["command":"packet_status","object_id":id.uuidString,"path":destination.path]) as? [String:Any])
    XCTAssertEqual(current["source_current"] as? Bool,true);XCTAssertEqual(current["artifact_integrity"] as? Bool,true)
    XCTAssertThrowsError(try ConstructionPacketOutput.export(store:store,objectID:id,arguments:["command":"export","format":"packet","path":destination.path]))
    var changed=before;let inkIndex=try XCTUnwrap(changed.objects.firstIndex{$0.id==inkID});changed.objects[inkIndex].artwork!.elements[0].color="#998877"
    let stale=try ConstructionPacketOutput.status(project:changed,object:owner,arguments:["path":destination.path])
    XCTAssertEqual(stale["stale"] as? Bool,true);XCTAssertEqual(stale["artifact_integrity"] as? Bool,true)
    let copied=try Data(contentsOf:destination.appendingPathComponent(mask));try Data("changed externally".utf8).write(to:destination.appendingPathComponent(mask))
    let damaged=try ConstructionPacketOutput.status(project:before,object:owner,arguments:["path":destination.path]);XCTAssertEqual(damaged["artifact_integrity"] as? Bool,false)
    try copied.write(to:destination.appendingPathComponent(mask))
    XCTAssertEqual(store.project,before)
  }
  func testPieceCropAndSheetRepackingRetainCanonicalInkAndPhysicalPlacement()throws {
    let(store,id,root,inkID)=try fixture();defer{release(store,root)}
    let project=try XCTUnwrap(store.project),owner=try XCTUnwrap(project.objects.first{$0.id==id}),source=try PaperConstruction.definition(for:owner),model=try ConstructionPacketModel(project:project,object:owner),piece=try XCTUnwrap(model.pieces.first{$0.id=="facing"})
    let before=try XCTUnwrap(project.objects.first{$0.id==inkID}?.artwork),cropped=try XCTUnwrap(ConstructionPacketOutput.pieceArtwork(piece,side:.outside,owner:owner,project:project,source:source))
    XCTAssertEqual(cropped.elements[0].x,before.elements[0].x);XCTAssertEqual(cropped.elements[0].width,20);XCTAssertEqual(cropped.elements[0].height,8)
    XCTAssertEqual(cropped.elements[0].affine?.tx,-5);XCTAssertEqual(cropped.elements[0].affine?.ty,-7)
    var format=model.production;format.materials[0].widthMM=297;format.materials[0].lengthMM=210
    _=try ConstructionMaterialLayouts.plan(pieces:model.pieces,production:format)
    XCTAssertEqual(project.objects.first{$0.id==inkID}?.artwork,before)
    let svg=store.repository.url(for:project.id).appendingPathComponent("Exports/logical-parts.svg");_=try ConstructionPacketOutput.export(store:store,objectID:id,arguments:["format":"svg","path":svg.path])
    XCTAssertTrue(try String(contentsOf:svg,encoding:.utf8).contains("logical layout, not stock nesting"))
  }
  func testNarrowMaterialPlacementsKeepEveryIdentityInActualPDFAndSVGBothOrientations()throws {
    let(store,id,root,_)=try fixture();defer{release(store,root)}
    var project=try XCTUnwrap(store.project),owner=try XCTUnwrap(project.objects.first{$0.id==id})
    owner.paperConstruction!.authored!.panels[0].polygon=[.init(0,0),.init(7,0),.init(7,30),.init(0,30)]
    owner.paperConstruction!.authored!.panels[1].polygon=[.init(70,0),.init(115,0),.init(115,7),.init(70,7)]
    owner.paperConstruction!.authored!.production!.guides=[]
    owner.paperConstruction!.authored!.production!.materials[0].allowRotation=false
    owner.paperConstruction!.authored!.production!.quantity=2
    for index in owner.paperConstruction!.authored!.components!.indices {
      owner.paperConstruction!.authored!.components![index].front=nil
      owner.paperConstruction!.authored!.components![index].finishes=nil
    }
    project.objects[try XCTUnwrap(project.objects.firstIndex{$0.id==id})]=owner
    let before=try JSONEncoder.form.encode(project),model=try ConstructionPacketModel(project:project,object:owner)
    XCTAssertTrue(model.isValid,model.issues.map(\.message).joined(separator:"\n"))
    let document=try XCTUnwrap(PDFDocument(data:try ConstructionPacketPDF.materialLayouts(model)))
    let contents=(document.string ?? "").replacingOccurrences(of:"\n",with:" ")
    var rotations=Set<Double>()
    for batch in model.layouts.batches {
      let labeled=ConstructionPacketDrawing.layoutSVG(batch,sheetIndex:0,pieces:model.pieces)
      let unlabeled=ConstructionPacketDrawing.layoutSVG(batch,sheetIndex:0,pieces:model.pieces,labels:false)
      XCTAssertFalse(unlabeled.contains("placement-label"));XCTAssertFalse(unlabeled.contains(" / copy "))
      for placement in batch.placements {
        let identity="\(placement.pieceID) / copy \(placement.copy)"
        XCTAssertTrue(contents.contains(identity),"Actual PDF lost narrow placement identity: "+identity)
        XCTAssertTrue(labeled.contains(identity),"SVG lost narrow placement identity: "+identity)
        let label=ConstructionPacketDrawing.materialLayoutLabel(in:placement.bounds);rotations.insert(label.rotationDegrees)
        let cut=model.pieces.first{$0.id==placement.pieceID}!.cutContours.map{$0.map(placement.transform.apply)}
        for contour in cut {XCTAssertTrue(unlabeled.contains(ConstructionPacketDrawing.path(contour)),"Labels may never change nominal cut geometry.")}
      }
    }
    XCTAssertEqual(rotations,[0,-90],"Horizontal and vertical narrow strips must both remain labeled along their long axes.")
    owner.paperConstruction!.authored!.production!.labels=false
    project.objects[try XCTUnwrap(project.objects.firstIndex{$0.id==id})]=owner
    let silent=try ConstructionPacketModel(project:project,object:owner)
    XCTAssertEqual(silent.layouts.batches,model.layouts.batches,"Toggling labels must preserve every sheet, transform and physical cut quantity.")
    let hidden=try XCTUnwrap(PDFDocument(data:try ConstructionPacketPDF.materialLayouts(silent)))
    XCTAssertFalse((hidden.string ?? "").contains(" / copy "))
    project.objects[try XCTUnwrap(project.objects.firstIndex{$0.id==id})].paperConstruction!.authored!.production!.labels=true
    XCTAssertEqual(try JSONEncoder.form.encode(project),before)
  }
  func testTinyPlacementKeysRetainReadableFullIdentityInSeparatePDFAndSVGWithExactStockPages()throws {
    let(store,id,root,_)=try fixture();defer{release(store,root)}
    var project=try XCTUnwrap(store.project),owner=try XCTUnwrap(project.objects.first{$0.id==id})
    owner.paperConstruction!.authored!.panels[0].polygon=[.init(0,0),.init(16,0),.init(16,4),.init(0,4)]
    owner.paperConstruction!.authored!.panels[1].polygon=[.init(70,0),.init(74,0),.init(74,16),.init(70,16)]
    owner.paperConstruction!.authored!.production!.guides=[]
    owner.paperConstruction!.authored!.production!.materials[0].allowRotation=false
    owner.paperConstruction!.authored!.production!.materials[0].widthMM=250
    owner.paperConstruction!.authored!.production!.materials[0].lengthMM=400
    owner.paperConstruction!.authored!.production!.quantity=2
    for index in owner.paperConstruction!.authored!.components!.indices {
      owner.paperConstruction!.authored!.components![index].front=nil
      owner.paperConstruction!.authored!.components![index].finishes=nil
    }
    let ownerIndex=try XCTUnwrap(project.objects.firstIndex{$0.id==id});project.objects[ownerIndex]=owner;store.engine.project=project
    let model=try ConstructionPacketModel(project:project,object:owner),pages=ConstructionPacketPDF.materialLayoutPageIndex(model)
    XCTAssertTrue(model.isValid,model.issues.map(\.message).joined(separator:"\n"))
    XCTAssertEqual(pages.compactMap{$0["role"] as? String},["actualSizeStock","labelKey","actualSizeStock","labelKey"])
    let destination=store.repository.url(for:project.id).appendingPathComponent("Exports/tiny-placement-keys")
    _=try ConstructionPacketOutput.export(store:store,objectID:id,arguments:["format":"packet","path":destination.path])
    let document=try XCTUnwrap(PDFDocument(url:destination.appendingPathComponent("Material-layout-proofs.pdf")))
    XCTAssertEqual(document.pageCount,pages.count)
    let contents=(document.string ?? "").replacingOccurrences(of:"\n",with:" ")
    XCTAssertTrue(contents.contains("This page is not a cutting sheet."))
    for descriptor in pages {
      let page=try XCTUnwrap(document.page(at:try XCTUnwrap(descriptor["page"] as? Int)-1)),bounds=page.bounds(for:.mediaBox)
      XCTAssertEqual(bounds.width,try XCTUnwrap(descriptor["width_mm"] as? Double)*72/25.4,accuracy:0.02)
      XCTAssertEqual(bounds.height,try XCTUnwrap(descriptor["height_mm"] as? Double)*72/25.4,accuracy:0.02)
    }
    for batch in model.layouts.batches {
      let plan=ConstructionPacketDrawing.materialLayoutAnnotations(batch,sheetIndex:0)
      XCTAssertTrue(plan.placements.allSatisfy{$0.key != nil});XCTAssertEqual(plan.keyPages.count,1)
      let stockSVG=ConstructionPacketDrawing.layoutSVG(batch,sheetIndex:0,pieces:model.pieces)
      let keys=ConstructionPacketDrawing.layoutLabelKeySVGs(batch,sheetIndex:0).joined()
      XCTAssertTrue(stockSVG.contains("width=\"250.0mm\""));XCTAssertTrue(stockSVG.contains("height=\"400.0mm\""))
      for annotation in plan.placements {
        let identity="\(annotation.pieceID) / copy \(annotation.copy)",key=try XCTUnwrap(annotation.key)
        XCTAssertTrue(contents.contains(identity));XCTAssertTrue(keys.contains(identity))
        XCTAssertTrue(stockSVG.contains("data-key=\"\(key)\""));XCTAssertFalse(stockSVG.contains(identity),"Tiny stock placements must show a key instead of an overflowing full label.")
        XCTAssertTrue(keys.contains("data-role=\"label-key-entry\" data-key=\"\(key)\""))
      }
    }
    let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:destination.appendingPathComponent("Manifest.json"))) as? [String:Any])
    let index=try XCTUnwrap(manifest["material_layout_pdf_pages"] as? [[String:Any]])
    XCTAssertEqual(index.compactMap{$0["role"] as? String},pages.compactMap{$0["role"] as? String})
    let files=try XCTUnwrap(manifest["files"] as? [[String:Any]]),companions=files.filter{$0["role"] as? String=="layoutLabelKey"}
    XCTAssertEqual(companions.count,2)
    for file in companions {
      let path=try XCTUnwrap(file["path"] as? String),data=try Data(contentsOf:destination.appendingPathComponent(path))
      XCTAssertEqual(ConstructionMaterialLayouts.digest(data),file["sha256"] as? String)
    }
    owner.paperConstruction!.authored!.production!.labels=false;project.objects[ownerIndex]=owner;store.engine.project=project
    let silent=try ConstructionPacketModel(project:project,object:owner)
    XCTAssertEqual(silent.layouts.batches,model.layouts.batches)
    XCTAssertTrue(ConstructionPacketPDF.materialLayoutPageIndex(silent).allSatisfy{$0["role"] as? String=="actualSizeStock"})
    let silentDestination=store.repository.url(for:project.id).appendingPathComponent("Exports/tiny-without-labels")
    let result=try XCTUnwrap(ConstructionPacketOutput.export(store:store,objectID:id,arguments:["format":"packet","path":silentDestination.path]) as? [String:Any])
    XCTAssertFalse((result["files"] as? [String] ?? []).contains{$0.contains("label-key")})
    let silentPDF=try XCTUnwrap(PDFDocument(url:silentDestination.appendingPathComponent("Material-layout-proofs.pdf")))
    XCTAssertEqual(silentPDF.pageCount,2);XCTAssertFalse((silentPDF.string ?? "").contains(" / copy "))
  }
}
