import Foundation
import FormCADModel
import XCTest
@testable import FormCore

final class ConstructionPacketTests:XCTestCase {
  private func rect(_ id:String,_ x:Double,_ y:Double,_ width:Double,_ height:Double,holes:[PlanarCutoutDefinition]?=nil)->PlanarPanelDefinition {
    .init(id:id,name:id,polygon:[.init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y)),.init(CADScalar(x+width),CADScalar(y+height)),.init(CADScalar(x),CADScalar(y+height))],cutouts:holes)
  }
  private func fixture()->(Project,ProductObject) {
    let hole=PlanarCutoutDefinition(id:"actual-hole",polygon:[.init(40,20),.init(50,20),.init(50,30),.init(40,30)])
    let cloth=PaperStock(name:"Backed surface sheet",thicknessMM:0.15,grain:.parallelHeight,profile:.init(texture:.linen,color:"#315D55"),plies:[.init(name:"Backing",color:"#E4DDBB",thicknessMM:0.05),.init(name:"Face",color:"#315D55",thicknessMM:0.1)])
    let production=ConstructionProductionDefinition(materials:[.init(id:"sheet-format",name:"Declared stock sheets",componentIDs:["plate","surface"],widthMM:200,lengthMM:300,marginMM:5,spacingMM:3,grain:.unrestricted)],steps:[
      .init(id:"prepare",title:"Prepare independent parts",componentIDs:["plate"],instructions:"Cut the actual plate and its inner aperture; preserve part identity."),
      .init(id:"attach",title:"Attach the connected surface",componentIDs:["surface"],after:["prepare"],instructions:"Apply the retained surface sheet and turn its flexible edge along the declared guide.")],assumptions:["Declared prototype stock calipers; no machine command or strength verification."],guides:[.init(id:"turn-in",componentID:"surface",role:.turnIn,points:[.init(2,45),.init(68,45)],label:"Retained turn-in")],quantity:2)
    let definition=PlanarConstructionDefinition(name:"Reusable independent part assembly",parameters:[.init("showSurface",1,0...1,unit:"")],size:.init(300,200),stockThickness:2,panels:[rect("plate-panel",0,0,100,60,holes:[hole]),rect("surface-main",130,0,70,40),rect("surface-turn",130,40,70,10)],hinges:[.init(id:"surface-fold",parentPanelID:"surface-main",childPanelID:"surface-turn",start:.init(130,40),end:.init(200,40),angleDegrees:90)],rootPanelID:"plate-panel",components:[
      .init(id:"plate",name:"Independent plate",rootPanelID:"plate-panel",anchor:.init(0,0),position:.init(0,1,0),rotationDegrees:.init(-90,0,0),groupID:"fixed",stock:.init(name:"Board",thicknessMM:2,grain:.parallelHeight,profile:.init(texture:.recycled,color:"#B29C77")),quantity:2,purpose:"support"),
      .init(id:"surface",name:"One connected surface blank",rootPanelID:"surface-main",anchor:.init(130,0),position:.init(0,10,0),rotationDegrees:.init(-90,0,0),groupID:"movable",stock:cloth,purpose:"surface",enabled:"showSurface")],groups:[.init(id:"fixed",name:"Fixed frame"),.init(id:"movable",name:"Movable frame",position:.init(0,"opening/5+explosion/4",0))],production:production)
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:300,height:200,depth:2),stock:.init(thicknessMM:2));paper.authored=definition
    let values=PaperConstructionEngine.parameters(paper),controls=values.keys.sorted().map{Parameter($0,$0,values[$0]!,-1000...10000)}
    let recipe=Recipe("independent-test","Independent test","square","Generic physical parts",controls)
    var owner=ProductObject(name:"Independent physical assembly",recipeID:recipe.id,parameters:values,materialID:"paper-superfine");owner.paperConstruction=paper
    var project=Project(name:"Packet source");project.objects=[owner];project.recipes=[recipe]
    return(project,owner)
  }
  func testConnectedTreesBecomeIndependentMaterialPiecesAndHolesStayReal()throws {
    let (_,owner)=fixture(),paper=try PaperConstruction.definition(for:owner),pieces=try ConstructionPieces.resolve(paper)
    XCTAssertEqual(pieces.count,2)
    let plate=try XCTUnwrap(pieces.first{$0.id=="plate"}),surface=try XCTUnwrap(pieces.first{$0.id=="surface"})
    XCTAssertEqual(plate.cutContours.count,2);XCTAssertEqual(plate.areaMM2,5900,accuracy:1e-6)
    XCTAssertEqual(surface.panelIDs,["surface-main","surface-turn"]);XCTAssertEqual(surface.cutContours.count,1)
    XCTAssertEqual(surface.bounds,.init(x:130,y:0,width:70,height:50));XCTAssertEqual(surface.areaMM2,3500,accuracy:1e-6)
    XCTAssertEqual(surface.cutContours.flatMap{$0}.map(\.x).min(),0)
    XCTAssertEqual(surface.guides.first{$0.id=="surface-fold"}?.role,.fold)
    XCTAssertEqual(surface.guides.first{$0.id=="surface-fold"}?.points,[.init(0,40),.init(70,40)])
    XCTAssertEqual(surface.guides.first{$0.id=="turn-in"}?.role,.turnIn)
    let svg=ConstructionPacketDrawing.pieceSVG(surface)
    XCTAssertTrue(svg.contains("width=\"70.0mm\""));XCTAssertTrue(svg.contains("height=\"50.0mm\""))
    XCTAssertTrue(svg.contains("data-role=\"fold\""));XCTAssertFalse(svg.contains("data-role=\"score\""));XCTAssertFalse(svg.contains("<g id=\"crease\""))
  }
  func testMaterialLayoutPartitionsStockAndCountsActualContoursWithoutMovingSource()throws {
    let (project,owner)=fixture(),before=try JSONEncoder.form.encode(project),model=try ConstructionPacketModel(project:project,object:owner)
    XCTAssertTrue(model.isValid,model.issues.map(\.message).joined(separator:"\n"));XCTAssertEqual(model.layouts.batches.count,2)
    XCTAssertEqual(model.layouts.batches.reduce(0){$0+$1.placements.count},6)
    XCTAssertEqual(model.layouts.batches.reduce(0.0){$0+$1.cutAreaMM2},30600,accuracy:1e-6)
    let calipers=model.layouts.batches.map{$0.stock.resolvedThicknessMM}.sorted();XCTAssertEqual(calipers[0],0.15,accuracy:1e-10);XCTAssertEqual(calipers[1],2,accuracy:1e-10)
    XCTAssertEqual(try JSONEncoder.form.encode(project),before)
    for batch in model.layouts.batches {
      XCTAssertEqual(batch.sheetCount,1)
      for p in batch.placements {XCTAssertGreaterThanOrEqual(p.bounds.x,batch.format.marginMM);XCTAssertLessThanOrEqual(p.bounds.x+p.bounds.width,batch.format.widthMM-batch.format.marginMM+1e-7)}
      let svg=ConstructionPacketDrawing.layoutSVG(batch,sheetIndex:0,pieces:model.pieces)
      XCTAssertTrue(svg.contains("width=\"200.0mm\""));XCTAssertTrue(svg.contains("data-copy=\""))
    }
    var smaller=model.production;smaller.materials[0].widthMM=50;smaller.materials[0].lengthMM=50
    let report=try ConstructionMaterialLayouts.plan(pieces:model.pieces,production:smaller)
    XCTAssertFalse(report.isValid);XCTAssertTrue(report.issues.contains{$0.code=="unplacedCopy"})
  }
  func testPresentationAndCanvasPositionsDoNotInvalidatePacketButStockAndInkDo()throws {
    var(project,owner)=fixture();let original=try ConstructionPacketModel.currentSourceDigest(project:project,object:owner)
    owner.position = .init(200,30,-60);owner.rotation=77;owner.parameters["opening"]=60;owner.parameters["explosion"]=90
    owner.paperConstruction!.openingPercent=60;owner.paperConstruction!.explosionPercent=90
    project.objects[0]=owner;project.camera.distance=200;project.camera.target = .init(20,30,40);project.updatedAt=Date()
    XCTAssertEqual(try ConstructionPacketModel.currentSourceDigest(project:project,object:owner),original)
    owner.paperConstruction!.authored!.components![0].stockThickness=3;project.objects[0]=owner
    XCTAssertNotEqual(try ConstructionPacketModel.currentSourceDigest(project:project,object:owner),original)
    let afterStock=try ConstructionPacketModel.currentSourceDigest(project:project,object:owner)
    owner.artwork=Artwork(background:"#FFFFFF",elements:[.init(kind:"rectangle",x:10,y:12,width:20,height:8,color:"#123456")],bleed:0);owner.artwork?.backgroundOpacity=0;project.objects[0]=owner
    XCTAssertNotEqual(try ConstructionPacketModel.currentSourceDigest(project:project,object:owner),afterStock)
  }
  func testDisabledSavedPatternRestoresAndDoesNotKeepCutQuantitiesOrInstructionsActive()throws {
    var(project,owner)=fixture();let saved=owner.paperConstruction!.authored!.components![1]
    owner.parameters["showSurface"]=0;project.objects[0]=owner
    let off=try ConstructionPacketModel(project:project,object:owner)
    XCTAssertEqual(off.pieces.map(\.id),["plate"]);XCTAssertEqual(off.layouts.batches.count,1);XCTAssertEqual(off.steps.map(\.id),["prepare"])
    XCTAssertEqual(owner.paperConstruction!.authored!.components![1],saved)
    owner.parameters["showSurface"]=1;project.objects[0]=owner
    let restored=try ConstructionPacketModel(project:project,object:owner);XCTAssertEqual(restored.pieces.count,2);XCTAssertEqual(restored.steps.map(\.id),["prepare","attach"])
  }
  func testProductionOrderAndReferenceErrorsAreSpecificAndAtomic()throws {
    let (_,owner)=fixture();let definition=owner.paperConstruction!.authored!
    var invalid=definition;invalid.production!.steps[0].after=["attach"]
    XCTAssertThrowsError(try invalid.net()) {XCTAssertTrue($0.localizedDescription.contains("earlier steps"))}
    invalid=definition;invalid.production!.materials.append(invalid.production!.materials[0]);invalid.production!.materials[1].id="duplicate-assignment"
    XCTAssertThrowsError(try invalid.net()) {XCTAssertTrue($0.localizedDescription.contains("duplicate component"))}
    invalid=definition;invalid.production!.guides[0].componentID="removed-piece"
    XCTAssertThrowsError(try invalid.net())
    XCTAssertEqual(definition,owner.paperConstruction!.authored)
  }
  func testSharedMaterialKernelKeepsHolesAvailableAndDetectsActualOverlapAndSpacing()throws {
    let outer=[Point2(0,0),.init(100,0),.init(100,100),.init(0,100)],hole=[Point2(30,30),.init(70,30),.init(70,70),.init(30,70)]
    let inner=[Point2(40,40),.init(60,40),.init(60,60),.init(40,60)],cross=[Point2(20,20),.init(40,20),.init(40,40),.init(20,40)]
    var comparisons=0
    let free=try MaterialContourGeometry.separation([outer,hole],[inner],required:5,comparisons:&comparisons)
    XCTAssertFalse(free.overlaps);XCTAssertEqual(free.distance,10,accuracy:1e-8)
    XCTAssertTrue(try MaterialContourGeometry.separation([outer,hole],[cross],required:5,comparisons:&comparisons).overlaps)
    XCTAssertThrowsError(try MaterialContourGeometry.separation([outer,hole],[inner],required:5,comparisons:&comparisons,maximumComparisons:0))
  }
  func testSectionsRetainActualStockLayersAndPosesPreserveCutSources()throws {
    let (_,owner)=fixture(),source=try PaperConstruction.definition(for:owner),before=try ConstructionPieces.resolve(source)
    let section=try ConstructionAssemblyDrawings.resolve(source:source,view:.init(id:"section",title:"Actual nominal material section",projection:.side,sectionAxis:.x,sectionOffsetMM:0))
    XCTAssertTrue(section.shapes.contains{$0.pieceID=="plate"});XCTAssertTrue(section.shapes.contains{$0.color=="#315D55"});XCTAssertTrue(section.shapes.contains{$0.color=="#E4DDBB"})
    let closed=try ConstructionAssemblyDrawings.resolve(source:source,view:.init(id:"closed",title:"Closed")),open=try ConstructionAssemblyDrawings.resolve(source:source,view:.init(id:"open",title:"Open",openingPercent:100,explosionPercent:80))
    XCTAssertNotEqual(closed.shapes,open.shapes);XCTAssertEqual(try ConstructionPieces.resolve(source),before)
    let svg=ConstructionAssemblyDrawings.svg(section);XCTAssertTrue(svg.contains("data-not-tool-path=\"true\""))
  }
}
