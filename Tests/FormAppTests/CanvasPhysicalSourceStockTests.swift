import AppKit
import FormCADModel
import FormCore
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class CanvasPhysicalSourceStockTests:XCTestCase {
  private func sheet(_ project:inout Project,name:String="Canonical atlas",width:Double=200,height:Double=250)throws->UUID {
    var object=try project.makeObject(recipeID:"artboard",name:name,parameters:["width":width,"depth":height])
    var artwork=Artwork(background:"#FFFFFF",elements:[],bleed:0);artwork.backgroundOpacity=0
    object.artwork=artwork;project.objects.append(object);return object.id
  }
  private func base()->(Project,UUID) {
    var project=Project(name:"Nonprinting physical source preview")
    let page=try! sheet(&project,name:"Logical page",width:100,height:140)
    let publication=try! PublicationCommands.createPublication(in:&project,name:"Physical source",pages:[page])
    return(project,publication)
  }
  private func color(_ hex:String,opacity:Double=1,thickness:Double=0.2)->PaperStock {
    .init(thicknessMM:thickness,profile:.init(texture:.smooth,color:hex,textureDepthMM:0,opacity:opacity))
  }
  func testWrapAuxiliaryAndInsetSourcesUseActualMaterialRegionsWithoutChangingPrintedSource()throws {
    var (project,publication)=base()
    let atlas=try sheet(&project),reverse=try sheet(&project,name:"Reverse source"),auxiliary=try sheet(&project,name:"Unnumbered source"),insert=try sheet(&project,name:"Image insert",width:40,height:50)
    let board=PaperStock(thicknessMM:1.5,plies:[.init(name:"Forest reverse",color:"#173E32",thicknessMM:0.7,profile:.init(opacity:0.4)),
      .init(name:"Cream front",color:"#F1E5C8",thicknessMM:0.8)])
    let plane=SheetAssemblyPlane(id:"board",name:"Wrapped generic board",size:.init(80,100),stock:board,
      front:.init(sourceObjectID:atlas,sourceOriginMM:.init(20,20)),back:.init(sourceObjectID:reverse,sourceOriginMM:.init(3,4)),
      features:.init(wrap:.init(stock:color("#D1B98A",opacity:0.6,thickness:0.15),turnInMM:10),
        recesses:[.init(id:"image-seat",origin:.init(10,20),size:.init(20,30),depthMM:0.5,
          insert:.init(stock:color("#D7E0FF"),face:.init(sourceObjectID:insert,sourceOriginMM:.init(5,6))))]))
    _ = try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:[plane],
      auxiliaryLeaves:[.init(name:"Separate endpaper",stock:color("#E5D7A2"),front:.init(sourceObjectID:auxiliary))]))
    let baseline=project,cache=CanvasPhysicalSourceStockCache()
    let front=try XCTUnwrap(cache.regions(for:atlas,in:project).first)
    XCTAssertEqual(front.rect,CGRect(x:8.5,y:8.5,width:103,height:123));XCTAssertEqual(front.color,"#D1B98A");XCTAssertEqual(front.opacity,0.6)
    let back=try XCTUnwrap(cache.regions(for:reverse,in:project).first)
    XCTAssertEqual(back.rect,CGRect(x:3,y:4,width:80,height:100));XCTAssertEqual(back.color,"#173E32");XCTAssertEqual(back.opacity,0.4)
    XCTAssertEqual(cache.regions(for:auxiliary,in:project).first?.color,"#E5D7A2")
    let inset=try XCTUnwrap(cache.regions(for:insert,in:project).first)
    XCTAssertEqual(inset.rect,CGRect(x:5,y:6,width:20,height:30));XCTAssertEqual(inset.color,"#D7E0FF")
    XCTAssertEqual(project,baseline);XCTAssertEqual(cache.builds,1)
    XCTAssertTrue(project.objects.filter{[atlas,reverse,auxiliary,insert].contains($0.id)}.allSatisfy{$0.artwork?.backgroundOpacity==0})
  }
  func testConflictingOverlapIsNeutralAndAgreeingTranslucentUsesPaintOnlyOnce()throws {
    var (project,publication)=base();let source=try sheet(&project)
    let red=color("#CC4422",opacity:0.5),blue=color("#2244CC",opacity:0.5)
    let planes:[SheetAssemblyPlane]=[
      .init(id:"red",name:"Red use",size:.init(80,60),stock:red,front:.init(sourceObjectID:source)),
      .init(id:"same-red",name:"Agreeing translucent use",size:.init(80,60),stock:red,front:.init(sourceObjectID:source)),
      .init(id:"blue",name:"Conflicting use",size:.init(80,60),stock:blue,front:.init(sourceObjectID:source,sourceOriginMM:.init(40,20)))]
    _ = try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:planes))
    let regions=CanvasPhysicalSourceStockCache().regions(for:source,in:project)
    XCTAssertEqual(regions.filter{$0.rect.contains(CGPoint(x:10,y:10))}.count,1)
    XCTAssertEqual(regions.first{$0.rect.contains(CGPoint(x:10,y:10))}?.opacity,0.5)
    XCTAssertFalse(regions.contains{$0.rect.contains(CGPoint(x:60,y:40))},"Ambiguous material must not be chosen by consumer order.")
    XCTAssertEqual(regions.first{$0.rect.contains(CGPoint(x:100,y:70))}?.color,"#2244CC")
    XCTAssertEqual(regions.reduce(0){$0+$1.rect.width*$1.rect.height},6400,accuracy:1e-8)
    let context=try XCTUnwrap(CGContext(data:nil,width:200,height:200,bitsPerComponent:8,bytesPerRow:800,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:200,height:200))
    CanvasPhysicalSourceStockCache.draw(regions,in:context)
    let bytes=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
    XCTAssertEqual(bytes[(40*200+60)*4],255);XCTAssertEqual(bytes[(40*200+60)*4+2],255,"Conflicting overlap remains the neutral Canvas backing.")
  }
  func testOrdinaryLinkedPaperUsesRegisteredFullNetCoordinatesAndStockChangesInvalidateOnlyStructuralCache()throws {
    var project=Project(name:"Registered ordinary material")
    let source=try sheet(&project,width:300,height:250)
    let inside=try sheet(&project,name:"Reverse material source",width:300,height:250)
    let definition=PlanarConstructionDefinition(name:"Ordinary layered shell",size:.init(160,180),stockThickness:1.5,
      panels:[.init(id:"part",name:"Wrapped part",polygon:[.init(20,30),.init(100,30),.init(100,130),.init(20,130)],
        features:.init(wrap:.init(stock:color("#224466",thickness:0.12),turnInMM:8)))],rootPanelID:"part")
    project.recipes.append(.init("linkedStockSource","Generic shell","square","Project source",[.init("fold","Fold",100,0...100),.init("opening","Opening",0,0...100)]))
    var object=try project.makeObject(recipeID:"linkedStockSource")
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:80,height:100,depth:1.5),stock:color("#D1C5AB",thickness:1.5))
    paper.authored=definition;paper.insideArtworkSourceID=inside
    object.paperConstruction=paper;object.artworkSourceID=source;object.artworkFit="actual";project.objects.append(object)
    let cache=CanvasPhysicalSourceStockCache(),baseline=project
    let region=try XCTUnwrap(cache.regions(for:source,in:project).first)
    XCTAssertEqual(region.rect,CGRect(x:10.5,y:20.5,width:99,height:119),"Paper links retain full-net placement; a larger artboard is not arbitrarily centered or fitted.")
    XCTAssertEqual(region.color,"#224466")
    XCTAssertEqual(cache.regions(for:inside,in:project).first?.color,"#D1C5AB")
    project.camera.azimuth=0.8
    project.objects[project.objects.firstIndex{$0.id==source}!].artwork!.elements=[.init(kind:"text",x:25,y:35,width:40,height:20,text:"Edited ink only",fontSize:12)]
    _ = cache.regions(for:source,in:project);XCTAssertEqual(cache.builds,1,"Camera and ink edits do not rebuild physical source geometry.")
    project.objects[project.objects.firstIndex{$0.id==object.id}!].color="#995533"
    XCTAssertEqual(cache.regions(for:source,in:project).first?.color,"#995533");XCTAssertEqual(cache.builds,2)
    XCTAssertEqual(cache.regions(for:source,in:baseline).first?.color,"#224466");XCTAssertEqual(cache.builds,3,"Undo/reopen structural values cannot reuse another stock's preview.")
    XCTAssertEqual(baseline.objects.first{$0.id==source}?.artwork?.backgroundOpacity,0)
  }
  func testTinyMillimeterRegionsAndOverviewCacheMaterialIdentityAreRetained()throws {
    var (project,publication)=base();let source=try sheet(&project,width:0.01,height:0.01)
    _ = try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,
      enclosure:[.init(id:"small",name:"Small physical face",size:.init(0.01,0.01),stock:color("#E8D888"),front:.init(sourceObjectID:source))]))
    let regions=CanvasPhysicalSourceStockCache().regions(for:source,in:project)
    XCTAssertEqual(regions.first?.rect.size,CGSize(width:0.01,height:0.01))
    let a=CanvasOverviewRasterCache.Presentation(size:.init(width:20,height:20),sourceStockRegions:regions)
    var b=a;b.sourceStockRegions[0].color="#123456"
    XCTAssertNotEqual(a,b,"Material-only changes must invalidate distant Canvas pixels too.")
  }
  func testDocumentGenerationAndOptionalStoreRespectExistingPhysicalFaceAndSpreadBackdrops()throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("source-stock-"+UUID().uuidString)
    let store=StudioStore(repository:try ProjectRepository(root:directory),seedLibrary:false)
    defer{store.engine.project=nil;try? FileManager.default.removeItem(at:directory)}
    var (project,publication)=base();let source=try sheet(&project)
    let assemblyID=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,
      enclosure:[.init(id:"source-use",name:"Physical source use",size:.init(80,60),stock:color("#527862",opacity:0.5),front:.init(sourceObjectID:source))]))
    store.engine.project=project
    let object=try XCTUnwrap(project.objects.first{$0.id==source})
    var frame=CanvasFrame(object:object,surfaceObject:object,rect:.init(x:100,y:50,width:200,height:250),artwork:try XCTUnwrap(object.artwork))
    let cache=CanvasPhysicalSourceStockCache()
    XCTAssertTrue(cache.regions(for:frame,store:nil).isEmpty)
    XCTAssertEqual(cache.regions(for:frame,store:store).first?.color,"#527862")
    XCTAssertEqual(cache.regions(for:frame,store:store).first?.opacity,0.5);XCTAssertEqual(cache.builds,1)
    let index=try XCTUnwrap(project.objects.firstIndex{$0.id==assemblyID})
    project.objects[index].sheetAssembly!.enclosure![0].stock.profile!.color="#9C784F"
    store.engine.project=project
    XCTAssertEqual(cache.regions(for:frame,store:store).first?.color,"#9C784F");XCTAssertEqual(cache.builds,2)
    frame.publicationSpread = .init(publicationID:publication,spreadID:UUID(),frameOrder:[source],pageRects:[frame.rect])
    XCTAssertTrue(cache.regions(for:frame,store:store).isEmpty,"Reader-spread backdrops already paint their stock once.")
    frame.publicationSpread=nil
    frame.object.paperConstruction = .init(kind:.authored,dimensions:.init(width:80,height:60,depth:0.2))
    XCTAssertTrue(cache.regions(for:frame,store:store).isEmpty,"Direct physical paper faces already paint their stock once.")
    cache.clear();XCTAssertEqual(cache.count,0)
  }
}
