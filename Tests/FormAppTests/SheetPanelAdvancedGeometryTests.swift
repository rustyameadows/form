import AppKit
import FormCore
import FormGeometry
import FormGraphics
import FormCADModel
import XCTest
import simd
@testable import FormApp

@MainActor final class SheetPanelAdvancedGeometryTests:XCTestCase {
  private let assets=FileManager.default.temporaryDirectory
  func testWrappedPanelHasRealCorePocketFloorInsertAndMiteredPrintedTurnIns()throws {
    let stock=PaperStock(thicknessMM:2,profile:.init(texture:.recycled,color:"#A58C63"))
    let wrapper=PaperStock(thicknessMM:0.12,profile:.init(texture:.linen,color:"#31554F"))
    let photo=SheetPanelInsert(stock:.init(thicknessMM:0.2),face:.init(sourceObjectID:UUID()))
    let raw=SheetPanelFeatures(wrap:.init(stock:wrapper,turnInMM:10,cornerRadiusMM:1.5),
      recesses:[.init(id:"seat",origin:.init(20,25),size:.init(35,45),depthMM:0.8,cornerRadiusMM:1,insert:photo)])
    let effective=try raw.resolved(size:.init(100,140),stock:stock,variables:[:],face:{source,_ in source.map{.init(sourceObjectID:$0.sourceObjectID)}})
    let face=ResolvedSheetAssemblyFace(sourceObjectID:UUID())
    let plane=ResolvedSheetAssemblyPlane(id:"panel",name:"Wrapped panel",size:.init(100,140),positionMM:.init(),rotationDegrees:.init(),
      stock:effective.0,front:face,back:nil,finishes:[],features:effective.1)
    let layers=try SheetPanelLayerGeometry.layers(plane)
    let rim=try XCTUnwrap(layers.first{$0.id=="face"}),floor=try XCTUnwrap(layers.first{$0.id=="core:1"}),insert=try XCTUnwrap(layers.first{$0.id=="insert:seat"})
    XCTAssertEqual(rim.cutouts.count,1);XCTAssertTrue(floor.cutouts.isEmpty)
    XCTAssertEqual(rim.position.z-rim.stock.resolvedThicknessMM/2,floor.position.z+floor.stock.resolvedThicknessMM/2,accuracy:1e-10)
    XCTAssertEqual(insert.position.z-insert.stock.resolvedThicknessMM/2,0.2,accuracy:1e-10)
    XCTAssertEqual(1-(insert.position.z+insert.stock.resolvedThicknessMM/2),0.6,accuracy:1e-10,"The image sits in a physical recess below the board rim.")
    let turns=layers.filter{$0.id.hasPrefix("wrap:turn-in:")},sides=layers.filter{$0.id.hasPrefix("wrap:edge:")}
    XCTAssertGreaterThan(turns.count,4);XCTAssertEqual(turns.count,sides.count)
    for layer in turns {XCTAssertTrue(layer.reverseArtwork);XCTAssertNotNil(layer.frontMapping);XCTAssertGreaterThanOrEqual(layer.polygon.count,3)}
    for layer in layers {
      let panel=PaperPanel(id:layer.id,name:layer.id,role:.body,polygon:layer.polygon,cutouts:layer.cutouts)
      XCTAssertNoThrow(try PaperGeometry.panelMesh(panel,netSize:layer.size,thicknessMM:layer.stock.resolvedThicknessMM))
    }
    let rectangular=try SheetPanelFeatures(wrap:.init(stock:wrapper,turnInMM:10)).resolved(size:.init(100,140),stock:stock,variables:[:],face:{_,_ in nil})
    var flat=plane;flat.features=rectangular.1
    let rectLayers=try SheetPanelLayerGeometry.layers(flat),top=try XCTUnwrap(rectLayers.first{$0.id=="wrap:edge:0"}),turn=try XCTUnwrap(rectLayers.first{$0.id=="wrap:turn-in:0"})
    let a=try XCTUnwrap(top.frontMapping).apply(.init(30,-1))
    XCTAssertEqual(a.x,30,accuracy:1e-10);XCTAssertEqual(a.y,1,accuracy:1e-10)
    let b=try XCTUnwrap(turn.frontMapping).apply(.init(30,-7))
    XCTAssertEqual(b.x,30,accuracy:1e-10);XCTAssertEqual(b.y,5,accuracy:1e-10,"Turn-in pixels continue beyond the cap and side, then fold onto the back.")
  }
  func testRecessSlicesActualBondedStrataWithoutDuplicatingOrRecoloringPlies()throws {
    let back=PaperPly(name:"Back blue",color:"#2456A8",thicknessMM:0.4),front=PaperPly(name:"Front cream",color:"#E9DAB8",thicknessMM:0.6)
    let stock=PaperStock(thicknessMM:1,plies:[back,front])
    let feature=try SheetPanelFeatures(recesses:[.init(id:"pocket",origin:.init(15,20),size:.init(40,50),depthMM:0.7)])
      .resolved(size:.init(100,140),stock:stock,variables:[:],face:{_,_ in nil})
    let plane=ResolvedSheetAssemblyPlane(id:"panel",name:"Bonded panel",size:.init(100,140),positionMM:.init(),rotationDegrees:.init(),stock:stock,front:nil,back:nil,finishes:[],features:feature.1)
    let layers=try SheetPanelLayerGeometry.layers(plane)
    XCTAssertEqual(layers.count,3)
    for (actual,expected) in zip(layers.map{$0.stock.resolvedThicknessMM},[0.6,0.1,0.3]) {XCTAssertEqual(actual,expected,accuracy:1e-8)}
    XCTAssertEqual(layers.map{$0.stock.profile?.color},[front.color,back.color,back.color])
    XCTAssertTrue(layers.allSatisfy{$0.stock.plies==nil})
    XCTAssertEqual(layers.filter{$0.cutouts.isEmpty}.count,1)
    for layer in layers {XCTAssertNoThrow(try layer.stock.validate())}
  }
  func testPhysicalHingeAllEdgesConservesNeutralArcCaliperAndUnitNormals()throws {
    let size=Point2(100,140),panel=PaperPanel(id:"face",name:"Flexible sheet",role:.body,polygon:SheetPanelLayerGeometry.rectangle(size))
    let base=try PaperGeometry.panelMesh(panel,netSize:size,thicknessMM:0.3),original=base.sources(for:.vertex).first!.vectors
    for edge in ["left","right","head","tail"] {
      let mesh=try SheetPanelFlexGeometry.make(base,size:size,edge:edge,widthMM:10,angleDegrees:150,final:false,tailRiseMM:2)
      XCTAssertLessThan(mesh.sources(for:.vertex).first!.vectors.count,500_000)
      for n in mesh.sources(for:.normal).first!.vectors {XCTAssertEqual(simd_length(n.simd),1,accuracy:1e-9)}
      let uv=mesh.sources(for:.texcoord).first!.points
      XCTAssertTrue(uv.allSatisfy{$0.x >= -1e-9 && $0.x<=1+1e-9 && $0.y >= -1e-9 && $0.y<=1+1e-9})
    }
    XCTAssertEqual(base.sources(for:.vertex).first!.vectors,original)
    let at=SheetPanelFlexGeometry.sample(10,widthMM:10,angleDegrees:180)
    XCTAssertEqual(at.distanceMM,0,accuracy:1e-10);XCTAssertEqual(at.heightMM,20/Double.pi,accuracy:1e-10)
    XCTAssertThrowsError(try SheetPanelFlexGeometry.make(base,size:size,edge:"left",widthMM:0.1,angleDegrees:180,final:false))
  }
  func testClosedEdgeRegistrationSurvivesPageBendAndSharesOnlyThreeSourceSurfaces()throws {
    let size=Point2(100,140),panel=PaperPanel(id:"face",name:"Printed edge",role:.body,polygon:SheetPanelLayerGeometry.rectangle(size))
    let base=try PaperGeometry.panelMesh(panel,netSize:size,thicknessMM:0.2),material=MeshMaterial()
    for edge in ["head","tail","foreEdge"] {
      let registered=try XCTUnwrap(SheetEdgeArtworkGeometry.register(base,size:size,thickness:0.2,depthOffset:0.4,totalDepth:1,edge:edge,material:material))
      let uv=registered.sources(for:.texcoord).first!.points
      XCTAssertTrue(uv.allSatisfy{$0.y>=0.4-1e-8 && $0.y<=0.6+1e-8})
      let bent=try SheetAssemblyGeometry.bent(registered,widthMM:100,riseMM:8,normalOffsetMM:0,segments:32)
      XCTAssertTrue(bent.sources(for:.texcoord).first!.points.allSatisfy{$0.y>=0.4-1e-8 && $0.y<=0.6+1e-8})
    }
  }
  func testOrdinaryPlanarPanelAndSheetEnclosureUseSameLayerRenderingPrimitive()throws {
    var project=Project(name:"Reusable layered panel")
    var object=try project.makeObject(recipeID:"artboard",parameters:["width":140,"depth":180])
    let face=ArtworkElement(kind:"rectangle",x:20,y:20,width:25,height:30,color:"#246787")
    object.artwork=Artwork(elements:[face]);object.artwork!.backgroundOpacity=0
    let stock=PaperStock(thicknessMM:2,profile:.init(texture:.recycled,color:"#A58C63"))
    let feature=SheetPanelFeatures(wrap:.init(stock:.init(thicknessMM:0.1,profile:.init(texture:.linen,color:"#EEE8DA")),turnInMM:10))
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:140,height:180,depth:2),stock:stock)
    paper.authored = .init(name:"Authored layered panel",size:.init(140,180),stockThickness:2,
      panels:[.init(id:"panel",name:"Panel",polygon:[.init(20,20),.init(120,20),.init(120,160),.init(20,160)],features:feature)],rootPanelID:"panel")
    object.paperConstruction=paper;project.objects.append(object)
    let before=project,root=try PaperGeometry.make(object,project:project,assets:assets,limit:256)
    let physical=try XCTUnwrap(root.childNode(withName:PaperGeometry.panelPrefix+"panel",recursively:true))
    XCTAssertNotNil(physical.childNode(withName:"paper.layer:wrap:face",recursively:true))
    XCTAssertNotNil(physical.childNode(withName:"paper.layer:wrap:turn-in:0",recursively:true))
    XCTAssertEqual(project,before)
  }
  func testGatheredSewnConstructionUsesPaperFoldsAndNonmetallicFiber()throws {
    var project=Project(name:"Physical gathered assembly"),ids=[UUID]()
    for index in 0..<8 {var page=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":100,"depth":140]);page.artwork=Artwork(elements:[]);project.objects.append(page);ids.append(page.id)}
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical run",pages:ids),pages=project.publications![0].pages
    var parents=[SheetAssemblyParentSheet]()
    for start in [0,4] {parents.append(.init(frontPageIDs:[pages[start+3].id,pages[start].id],backPageIDs:[pages[start+1].id,pages[start+2].id],stock:.init(thicknessMM:0.2),sizeMM:.init(200,140)))}
    let definition=SheetAssemblyDefinition(publicationID:publication,openingDegrees:130,activeSpread:2,
      binding:.init(style:.sewn,positionsMM:[30,110],flexWidthMM:10,adhesiveMM:0.15,sewingSwellMM:0.1),parentSheets:parents,
      signatures:parents.map{.init(parentSheetIDs:[$0.id])})
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition),object=project.objects.first{$0.id==id}!,resolved=try project.resolvedSheetAssembly(object)
    let root=try XCTUnwrap(SheetBindingGeometry.make(resolved))
    XCTAssertEqual(root.childNodes.filter{$0.name?.hasPrefix("sheet.signature.fold:")==true}.count,2)
    let stitches=root.childNodes.filter{$0.name?.hasPrefix("sheet.binding.thread:")==true}
    XCTAssertEqual(stitches.count,4)
    for stitch in stitches {XCTAssertEqual(stitch.geometry?.materials[0].name,"Binding / sewn fiber");XCTAssertNil(stitch.geometry?.materials[0].metalness.contents)}
    let rendered=try SheetAssemblyGeometry.make(object,project:project,assets:assets,limit:256)
    let leaf=try XCTUnwrap(rendered.childNode(withName:SheetAssemblyGeometry.leafName(resolved.leaves[0].id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
    XCTAssertTrue(leaf.geometry?.name?.hasPrefix("sheet.panel-flex:")==true)
  }
  func testCanonicalEdgeAndInsetMissingAssetsRejectAndExternalInsetEditsInvalidateGeometry()throws {
    var project=Project(name:"Strict derived artwork sources")
    var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140]);page.artwork=Artwork(elements:[]);project.objects.append(page)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical page",pages:[page.id])
    var edge=try project.makeObject(recipeID:"artboard",parameters:["width":140,"depth":1])
    edge.artwork=Artwork(elements:[.init(kind:"image",x:0,y:0,width:100,height:0.1,asset:"missing-edge-source.png")]);project.objects.append(edge)
    var image=try project.makeObject(recipeID:"artboard",parameters:["width":30,"depth":40])
    image.artwork=Artwork(elements:[.init(kind:"image",x:0,y:0,width:30,height:40,asset:"missing-inset-source.png")]);project.objects.append(image)
    let stock=PaperStock(thicknessMM:2)
    let feature=SheetPanelFeatures(recesses:[.init(id:"seat",origin:.init(10,10),size:.init(30,40),depthMM:0.8,
      insert:.init(stock:.init(thicknessMM:0.2),face:.init(sourceObjectID:image.id)))])
    let enclosure=SheetAssemblyPlane(id:"panel",name:"Inset panel",size:.init(100,140),stock:stock,features:feature)
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.2),
      enclosure:[enclosure],edgeArtwork:.init(foreEdge:.init(sourceObjectID:edge.id))))
    var book=project.objects.first{$0.id==id}!
    // Check edge in isolation, then the inset: neither is a page/cover-cap source.
    book.sheetAssembly!.enclosure=nil
    XCTAssertThrowsError(try SheetAssemblyRenderValidation.sources(book,project:project,assets:assets)) {XCTAssertTrue($0.localizedDescription.contains("missing-edge-source.png"))}
    book.sheetAssembly!.edgeArtwork=nil;book.sheetAssembly!.enclosure=[enclosure]
    XCTAssertThrowsError(try SheetAssemblyRenderValidation.sources(book,project:project,assets:assets)) {XCTAssertTrue($0.localizedDescription.contains("missing-inset-source.png"))}
    var panel=page;panel.id=UUID();panel.name="Ordinary inset panel"
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:100,height:140,depth:2),stock:stock)
    paper.authored = .init(name:"Physical panel",size:.init(100,140),stockThickness:2,panels:[.init(id:"panel",name:"Panel",
      polygon:[.init(0,0),.init(100,0),.init(100,140),.init(0,140)],features:feature)],rootPanelID:"panel")
    panel.paperConstruction=paper;project.objects.append(panel)
    XCTAssertThrowsError(try SheetAssemblyRenderValidation.sources(panel,project:project,assets:assets)) {XCTAssertTrue($0.localizedDescription.contains("missing-inset-source.png"))}
    let revision=PaperGeometry.sourceRevision(panel,project:project)
    project.objects[project.objects.firstIndex{$0.id==image.id}!].artwork = Artwork(elements:[.init(kind:"rectangle",x:0,y:0,width:30,height:40,color:"#246787")])
    XCTAssertNotEqual(PaperGeometry.sourceRevision(panel,project:project),revision,"Changing only a canonical inset source must invalidate derived material geometry.")
  }

  func testFullyOpenBondedAndSewnSpreadsRemainAboveNeighboringBlankLeafFaces()throws {
    for style:SheetBindingStyle in [.adhesive,.sewn] {
      var project=Project(name:"Open spread ordering"),ids=[UUID]()
      for index in 0..<8 {
        var page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
        page.artwork=Artwork(background:index==3 ? "#0066CC":"#FFFFFF",elements:[])
        project.objects.append(page);ids.append(page.id)
      }
      let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical run",pages:ids)
      let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.2),
        openingDegrees:180,activeSpread:2,binding:.init(style:style,positionsMM:[30,110],flexWidthMM:10)))
      let object=project.objects.first{$0.id==id}!,resolved=try project.resolvedSheetAssembly(object)
      let root=try SheetAssemblyGeometry.make(object,project:project,assets:assets,limit:256)
      func freeTailHeight(_ index:Int)throws->Double {
        let node=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(resolved.leaves[index].id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
        let mesh=try XCTUnwrap(node.geometry),p=mesh.sources(for:.vertex).first!.vectors,uv=mesh.sources(for:.texcoord).first!.points
        return try XCTUnwrap(p.indices.filter{uv[$0].x>0.8}.map{node.convertPosition(p[$0],to:nil).y*100}.max())
      }
      XCTAssertTrue(resolved.leaves[1].backVisible);XCTAssertFalse(resolved.leaves[0].backVisible)
      XCTAssertTrue(resolved.leaves[2].frontVisible);XCTAssertFalse(resolved.leaves[3].frontVisible)
      XCTAssertGreaterThan(try freeTailHeight(1),try freeTailHeight(0)+0.15,"The active left spread must sit above earlier opaque blank geometry, for \(style).")
      XCTAssertGreaterThan(try freeTailHeight(2),try freeTailHeight(3)+0.15,"The active right spread must sit above later opaque blank geometry, for \(style).")
    }
  }

  func testActualParentFoldHeightAndRigidTurnFollowResolvedLeavesWithoutChangingCaliper()throws {
    var project=Project(name:"Posed parent binding"),ids=[UUID]()
    for index in 0..<8 {
      var page=try project.makeObject(recipeID:"artboard",name:"Page \(index)",parameters:["width":100,"depth":140])
      page.artwork=Artwork(elements:[]);project.objects.append(page);ids.append(page.id)
    }
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical parent run",pages:ids),pages=project.publications![0].pages
    let parents=[0,4].map {start in SheetAssemblyParentSheet(frontPageIDs:[pages[start+3].id,pages[start].id],
      backPageIDs:[pages[start+1].id,pages[start+2].id],stock:.init(thicknessMM:0.2),sizeMM:.init(200,140))}
    let definition=SheetAssemblyDefinition(publicationID:publication,
      binding:.init(style:.sewn,positionsMM:[30,110],flexWidthMM:10,adhesiveMM:0.15),parentSheets:parents,
      signatures:parents.map{.init(parentSheetIDs:[$0.id])},
      auxiliaryLeaves:[.init(name:"Larger unnumbered guard",placement:.back,size:.init(100,148),stock:.init(thicknessMM:0.2))])
    let id=try SheetAssemblyCommands.create(in:&project,definition:definition)
    var object=try XCTUnwrap(project.objects.first{$0.id==id})
    for opening in [0.0,95,180] {
      object.sheetAssembly!.openingDegrees=opening;object.sheetAssembly!.activeSpread=2
      let resolved=try project.resolvedSheetAssembly(object),root=try SheetAssemblyGeometry.make(object,project:project,assets:assets,limit:128)
      let pair=resolved.leaves.filter{$0.parentSheetID==parents[0].id}
      let node=try XCTUnwrap(root.childNode(withName:"sheet.signature.fold:"+parents[0].id.uuidString,recursively:true))
      let vertices=try XCTUnwrap(node.geometry?.sources(for:.vertex).first?.vectors)
      XCTAssertEqual((vertices.map(\.z).max()!-vertices.map(\.z).min()!)*100,140,accuracy:1e-8,"Actual folded stock must not grow to the larger guard's height.")
      let caps=Array(vertices.suffix(8)),first=Array(caps.prefix(4)),last=Array(caps.suffix(4))
      func center(_ values:[MeshVector3])->SIMD3<Double> {values.reduce(SIMD3<Double>.zero){$0+$1.simd}/Double(values.count)}
      for (leaf,cap) in zip(pair,[first,last]) {
        let wrapper=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(leaf.id),recursively:true))
        let expected=wrapper.convertPosition(.init(0,-leaf.size.y/200,0),to:root).simd
        XCTAssertEqual(simd_distance(center(cap),expected)*100,0,accuracy:1e-7,"Both neutral fold endpoints follow the actual posed leaf roots at \(opening) degrees.")
        XCTAssertEqual(simd_distance(cap[0].simd,cap[1].simd)*100,0.2,accuracy:1e-8,"Rigid posing preserves the physical parent caliper.")
      }
      let adhesive=try XCTUnwrap(root.childNode(withName:"sheet.binding.adhesive",recursively:true)?.geometry)
      let glue=try XCTUnwrap(adhesive.sources(for:.vertex).first?.vectors)
      XCTAssertEqual((glue.map(\.z).max()!-glue.map(\.z).min()!)*100,140,accuracy:1e-8,"Adhesive follows the text block's real head/tail extent.")
      let thread=try XCTUnwrap(root.childNode(withName:"sheet.binding.thread:0:0",recursively:true)?.geometry)
      XCTAssertTrue(thread.sources(for:.vertex).first!.vectors.allSatisfy{abs($0.z*100)<70},"Sewn stations stay inside the actual folded parent.")
    }
  }

}
