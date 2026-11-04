import AppKit
import FormCore
import FormCADModel
import FormGeometry
import FormGraphics
import XCTest
import simd
@testable import FormApp

@MainActor final class SheetPanelNeutralCurveGeometryTests:XCTestCase {
  private let controls:[Point2]=[.init(0,0),.init(-1,0),.init(-1,30),.init(10,30)]
  func testCurvedSignMeshRetainsPhysicalUVsCaliperNormalsAndSharedCoreBoundsOnAllEdges()throws {
    let profile=try SheetPanelNeutralCurveProfile(points:controls,widthMM:80,fitLength:true,maximumNormalOffsetMM:0.2)
    for edge:SheetPanelEdge in [.left,.right,.head,.tail] {
      let horizontal=edge == .left || edge == .right,size=horizontal ? Point2(80,40):Point2(40,80)
      let polygon=SheetPanelLayerGeometry.rectangle(size),base=try PaperGeometry.panelMesh(.init(id:"sign",name:"Sign",role:.body,polygon:polygon),netSize:size,thicknessMM:0.4)
      let before=base.sources(for:.vertex).first!.vectors
      let mesh=try SheetPanelFlexGeometry.make(base,size:size,edge:edge.rawValue,widthMM:80,angleDegrees:0,final:true,curve:profile)
      let flex=try SheetPanelFeatures(flex:.init(edge:edge,widthMM:80,curve:.init(points:controls.map{.init(CADScalar($0.x),CADScalar($0.y))},fitLength:true)))
        .resolved(size:size,stock:.init(thicknessMM:0.4),variables:[:],face:{_,_ in nil}).1.flex!
      let positions=mesh.sources(for:.vertex).first!.vectors,normals=mesh.sources(for:.normal).first!.vectors,uv=mesh.sources(for:.texcoord).first!.points
      XCTAssertEqual(base.sources(for:.vertex).first!.vectors,before)
      XCTAssertLessThan(positions.count,500_000)
      for normal in normals {XCTAssertEqual(simd_length(normal.simd),1,accuracy:1e-9)}
      for side in 0..<2 {
        for index in Set(mesh.elements[side].indices).map(Int.init) {
          XCTAssertTrue((0...1).contains(uv[index].x));XCTAssertTrue((0...1).contains(uv[index].y))
          let source=Vector3(uv[index].x*size.x,-uv[index].y*size.y,side==0 ? 0.2:-0.2),expected=flex.deform(source,size:size)
          XCTAssertEqual(positions[index].x*100,expected.x,accuracy:1e-7)
          XCTAssertEqual(positions[index].y*100,expected.y,accuracy:1e-7)
          XCTAssertEqual(positions[index].z*100,expected.z,accuracy:1e-7)
        }
      }
      let bounds=flex.boundarySamples(size:size,halfCaliperMM:0.2),lo=SIMD3(bounds.map(\.x).min()!,bounds.map(\.y).min()!,bounds.map(\.z).min()!),hi=SIMD3(bounds.map(\.x).max()!,bounds.map(\.y).max()!,bounds.map(\.z).max()!)
      for p in positions {for axis in 0..<3 {XCTAssertGreaterThanOrEqual(p.simd[axis]*100,lo[axis]-1e-7);XCTAssertLessThanOrEqual(p.simd[axis]*100,hi[axis]+1e-7)}}
      for i in 0...100 {
        let d=80*Double(i)/100,source=horizontal ? Vector3(d,-20,0):Vector3(20,-d,0)
        var front=source,back=source;front.z=0.2;back.z = -0.2
        let a=flex.deform(front,size:size),b=flex.deform(back,size:size)
        XCTAssertEqual(simd_length(SIMD3(a.x-b.x,a.y-b.y,a.z-b.z)),0.4,accuracy:1e-9)
      }
    }
  }
  func testFullWidthCircularFlexHasNoZeroTailDegeneracyAndOrdinaryPaperUsesSharedCurve()throws {
    let size=Point2(80,40),base=try PaperGeometry.panelMesh(.init(id:"sign",name:"Sign",role:.body,polygon:SheetPanelLayerGeometry.rectangle(size)),netSize:size,thicknessMM:0.4)
    let bent=try SheetPanelFlexGeometry.make(base,size:size,edge:"left",widthMM:80,angleDegrees:90,final:false)
    XCTAssertFalse(bent.elements[0].indices.isEmpty)
    XCTAssertTrue(bent.sources(for:.vertex).first!.vectors.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
    XCTAssertThrowsError(try SheetPanelFlexGeometry.make(base,size:size,edge:"left",widthMM:80,angleDegrees:90,final:false,tailRiseMM:1))
    var project=Project(name:"Unrelated curved sign"),object=try project.makeObject(recipeID:"artboard",parameters:["width":80,"depth":40])
    object.artwork=Artwork(elements:[.init(kind:"rectangle",x:5,y:5,width:20,height:15,color:"#246787")])
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:80,height:40,depth:0.4),stock:.init(thicknessMM:0.4))
    paper.authored = .init(name:"Curved structural sign",size:.init(80,40),stockThickness:0.4,panels:[.init(id:"panel",name:"Sign",
      polygon:[.init(0,0),.init(80,0),.init(80,40),.init(0,40)],features:.init(flex:.init(widthMM:80,
      curve:.init(points:controls.map{.init(CADScalar($0.x),CADScalar($0.y))},fitLength:true))))],rootPanelID:"panel")
    object.paperConstruction=paper;project.objects.append(object);let before=project
    let root=try PaperGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:256)
    let layer=try XCTUnwrap(root.childNode(withName:"paper.layer:face",recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
    XCTAssertTrue(layer.geometry?.name?.hasPrefix("sheet.panel-flex:")==true);XCTAssertEqual(project,before)
  }
  func testRigidAttachedLiningIsCenteredOnItsParentWithRealWrapClearance()throws {
    var project=Project(name:"Centered bonded lining"),page=try project.makeObject(recipeID:"artboard",parameters:["width":100,"depth":140])
    page.artwork=Artwork(elements:[]);project.objects.append(page)
    let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical run",pages:[page.id])
    let board=SheetAssemblyPlane(id:"panel",name:"Wrapped panel",size:.init(100,140),stock:.init(thicknessMM:2),features:.init(wrap:.init(stock:.init(thicknessMM:0.1),turnInMM:8)))
    let lining=SheetAssemblyAuxiliaryLeaf(name:"Bonded lining",size:.init(96,136),stock:.init(thicknessMM:0.2),attachment:.init(planeID:"panel",widthMM:0))
    let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,enclosure:[board],auxiliaryLeaves:[lining])),object=project.objects.first{$0.id==id}!
    let root=try SheetAssemblyGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:256)
    let node=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(lining.id),recursively:true))
    XCTAssertEqual(node.parent?.name,SheetAssemblyGeometry.planeName("panel"))
    XCTAssertEqual(node.position.x*100,2,accuracy:1e-10);XCTAssertEqual(node.position.y*100,-2,accuracy:1e-10)
    XCTAssertEqual(node.position.z*100,-1.2,accuracy:1e-10)
    let original=try XCTUnwrap(node.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true)?.geometry)
    var opened=object;opened.sheetAssembly!.openingDegrees=180;opened.sheetAssembly!.activeSpread=1;opened.sheetAssembly!.bendMM=3
    let posed=try SheetAssemblyGeometry.make(opened,project:project,assets:FileManager.default.temporaryDirectory,limit:256)
    let openedLining=try XCTUnwrap(posed.childNode(withName:SheetAssemblyGeometry.leafName(lining.id),recursively:true))
    let physical=try XCTUnwrap(openedLining.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true)?.geometry)
    XCTAssertEqual(physical.sources(for:.vertex).first!.vectors,original.sources(for:.vertex).first!.vectors,
      "A lining bonded to a rigid panel must not inherit the free pages' viewing bend.")
    XCTAssertEqual(openedLining.position,node.position);XCTAssertEqual(openedLining.parent?.name,node.parent?.name)
  }
  func testNarrowLeafBindingUsesTheSameEffectiveHingeAsItsMeasuredDependency()throws {
    for style:SheetBindingStyle in [.adhesive,.sewn] {
      var project=Project(name:"Narrow folded material"),ids=[UUID]()
      for _ in 0..<4 {var page=try project.makeObject(recipeID:"artboard",parameters:["width":20,"depth":60]);page.artwork=Artwork(elements:[]);project.objects.append(page);ids.append(page.id)}
      let publication=try PublicationCommands.createPublication(in:&project,name:"Canonical source",pages:ids)
      let id=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publication,stock:.init(thicknessMM:0.2),openingDegrees:180,activeSpread:1,
        binding:.init(style:style,positionsMM:[15,45],flexWidthMM:25)))
      let object=project.objects.first{$0.id==id}!,resolved=try project.resolvedSheetAssembly(object)
      XCTAssertEqual(resolved.bindingFlexWidth,9,accuracy:1e-10)
      XCTAssertEqual(try project.sheetAssemblyMeasurements(object).bindingFlexWidth,9,accuracy:1e-10)
      let root=try SheetAssemblyGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:256)
      let leaf=try XCTUnwrap(root.childNode(withName:SheetAssemblyGeometry.leafName(resolved.leaves[0].id),recursively:true)?.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true))
      let mesh=try XCTUnwrap(leaf.geometry),uv=mesh.sources(for:.texcoord).first!.points,p=mesh.sources(for:.vertex).first!.vectors
      let index=try XCTUnwrap(mesh.elements[0].indices.map(Int.init).first{uv[$0].x>0.9})
      XCTAssertEqual(p[index].x*100,9-uv[index].x*20,accuracy:1e-7,"A 9 mm neutral hinge leaves an 11 mm reversed tail.")
      XCTAssertEqual(p[index].z*100,18/Double.pi-0.1,accuracy:1e-7,"The free tail must sit at the actual 9 mm hinge's diameter, not the requested 25 mm width.")
    }
    XCTAssertEqual(try SheetBindingDefinition(style:.sideStaple,flexWidthMM:20).effectiveFlexWidthMM(minimumLeafWidthMM:40),20)
    XCTAssertEqual(try SheetBindingDefinition(style:.none,flexWidthMM:20).effectiveFlexWidthMM(minimumLeafWidthMM:40),0)
  }

}
