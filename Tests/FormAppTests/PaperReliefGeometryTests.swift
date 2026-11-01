import AppKit
import FormCore
import FormGeometry
import FormGraphics
import XCTest
@testable import FormApp

@MainActor final class PaperReliefGeometryTests: XCTestCase {
  private let panel=PaperPanel(id:"face",name:"Face",role:.body,
    polygon:[.init(0,0),.init(20,0),.init(20,20),.init(0,20)])
  private let size=Point2(20,20)
  private func maps(x:Double=5,color:String="#000000",kind:PaperFinishAssignment.Kind = .emboss,
    amount:Double=0.12)throws->PaperSurfaceRasterizer.Maps {
    let shape=ArtworkElement(kind:"rectangle",x:x,y:5,width:8,height:8,color:color)
    var art=Artwork(elements:[shape]);art.backgroundOpacity=0
    let finish=PaperFinishAssignment(name:"Relief",kind:kind,elementIDs:[shape.id],
      depthMM:kind == .deboss || kind == .letterpress ? amount:0,
      heightMM:kind == .emboss || kind == .screenPrint ? amount:0)
    return try PaperSurfaceRasterizer.make(rect:panel.bounds,netSize:size,
      profile:.init(texture:.smooth,textureDepthMM:0),color:"#FFFFFF",grain:.unknown,
      artwork:art,finishes:[finish],assets:FileManager.default.temporaryDirectory,
      maximumEdge:256,pixelBudget:256*256)
  }
  private func empty()throws->PaperSurfaceRasterizer.Maps {
    try PaperSurfaceRasterizer.make(rect:panel.bounds,netSize:size,
      profile:.init(texture:.smooth,textureDepthMM:0),color:"#FFFFFF",grain:.unknown,
      artwork:nil,finishes:[],assets:FileManager.default.temporaryDirectory,
      maximumEdge:128,pixelBudget:128*128)
  }

  func testFinalReliefDisplacesRegisteredFaceAndRetainsPhysicalSourceEdgesUVAndSlots()throws {
    let base=try PaperGeometry.panelMesh(panel,netSize:size,thicknessMM:0.8)
    let physical=try XCTUnwrap(base.sources(for:.vertex).first).vectors
    let front=try maps(),back=try empty()
    let result=try PaperReliefGeometry.make(base:base,front:front,back:back,panel:panel,thicknessMM:0.8)
    let vertices=try XCTUnwrap(result.sources(for:.vertex).first).vectors
    XCTAssertGreaterThan(vertices.map(\.z).max()!,physical.map(\.z).max()!+0.001,
      "Raised finish intent must move real final-view vertices, not only a normal-map label.")
    XCTAssertEqual(base.sources(for:.vertex).first?.vectors,physical)
    XCTAssertEqual(result.elements.count,base.elements.count)
    XCTAssertEqual(result.elements[1].indices,base.elements[1].indices)
    XCTAssertEqual(result.elements[2].indices,base.elements[2].indices)
    XCTAssertLessThanOrEqual(result.elements[0].indices.count/3,PaperReliefGeometry.maximumTrianglesPerFace)
    XCTAssertEqual(result.sources(for:.texcoord).first?.points.count,vertices.count)
    XCTAssertEqual(result.sources(for:.normal).first?.vectors.count,vertices.count)
    for id in base.elements[2].indices {
      XCTAssertEqual(vertices[Int(id)],physical[Int(id)],"Cut walls and bevels retain exact stock caliper.")
    }
    let coordinates=try XCTUnwrap(result.sources(for:.texcoord).first).points
    for (i,p) in vertices.enumerated() {
      let uv=coordinates[i]
      XCTAssertEqual(uv.x,p.x*100/size.x,accuracy:1e-10)
      XCTAssertEqual(uv.y,-p.y*100/size.y,accuracy:1e-10)
    }
  }

  func testReverseImpressionUsesRegisteredSourceAndCannotInvertOpposingStockFaces()throws {
    let base=try PaperGeometry.panelMesh(panel,netSize:size,thicknessMM:0.2)
    let deep=try maps(kind:.deboss,amount:1)
    let result=try PaperReliefGeometry.make(base:base,front:deep,back:deep,panel:panel,thicknessMM:0.2)
    let vertices=try XCTUnwrap(result.sources(for:.vertex).first).vectors
    let front=result.elements[0].indices.map{vertices[Int($0)].z*100}
    let back=result.elements[1].indices.map{vertices[Int($0)].z*100}
    XCTAssertGreaterThanOrEqual(front.min()!,0.01-1e-6)
    XCTAssertLessThanOrEqual(back.max()!,-0.01+1e-6)
    XCTAssertLessThan(front.min()!,0.09)
    XCTAssertGreaterThan(back.max()!,-0.09)
    XCTAssertEqual(PaperReliefGeometry.sample(deep,at:.init(8,8)),-1,accuracy:1e-6)
    XCTAssertEqual(PaperReliefGeometry.sample(deep,at:.init(-1,8)),0)
  }

  func testMaskEditsChangeReliefWhileInkColorDoesNotAndZeroDepthRetainsBase()throws {
    let base=try PaperGeometry.panelMesh(panel,netSize:size,thicknessMM:0.8),back=try empty()
    let black=try maps(),red=try maps(color:"#FF0000"),moved=try maps(x:10)
    XCTAssertEqual(black.reliefRevision,red.reliefRevision)
    XCTAssertNotEqual(black.reliefRevision,moved.reliefRevision)
    let first=try PaperReliefGeometry.make(base:base,front:black,back:back,panel:panel,thicknessMM:0.8)
    let recolored=try PaperReliefGeometry.make(base:base,front:red,back:back,panel:panel,thicknessMM:0.8)
    XCTAssertEqual(first.name,recolored.name)
    XCTAssertEqual(first.sources(for:.vertex).first?.vectors,recolored.sources(for:.vertex).first?.vectors)
    let zero=try maps(amount:0)
    XCTAssertTrue(try PaperReliefGeometry.make(base:base,front:zero,back:back,panel:panel,thicknessMM:0.8) === base)
    XCTAssertThrowsError(try PaperReliefGeometry.make(base:base,front:black,back:back,panel:panel,
      thicknessMM:0.8,triangleBudget:PaperReliefGeometry.maximumTrianglesPerFace+1))
  }

  func testAsymmetricReverseReliefKeepsNonzeroSourceOffsetAndFrontUntouched()throws {
    let offset=PaperPanel(id:"offset",name:"Offset",role:.body,
      polygon:[.init(30,40),.init(50,40),.init(50,60),.init(30,60)])
    let net=Point2(100,100)
    let mark=ArtworkElement(kind:"rectangle",x:43,y:44,width:4,height:8,color:"#000000")
    let finish=PaperFinishAssignment(name:"Back mark",kind:.deboss,elementIDs:[mark.id],depthMM:0.1)
    func raster(_ art:Artwork?,_ finishes:[PaperFinishAssignment])throws->PaperSurfaceRasterizer.Maps {
      try PaperSurfaceRasterizer.make(rect:offset.bounds,netSize:net,
        profile:.init(texture:.smooth,textureDepthMM:0),color:"#FFFFFF",grain:.unknown,
        artwork:art,finishes:finishes,assets:FileManager.default.temporaryDirectory,
        maximumEdge:256,pixelBudget:256*256)
    }
    let base=try PaperGeometry.panelMesh(offset,netSize:net,thicknessMM:0.8)
    let front=try raster(nil,[]),back=try raster(Artwork(elements:[mark]),[finish])
    let mesh=try PaperReliefGeometry.make(base:base,front:front,back:back,panel:offset,thicknessMM:0.8)
    XCTAssertEqual(mesh.elements[0].indices,base.elements[0].indices)
    let points=try XCTUnwrap(mesh.sources(for:.vertex).first).vectors
    let backPoints=mesh.elements[1].indices.map{points[Int($0)]}
    let marked=backPoints.filter{(43...47).contains($0.x*100) && (44...52).contains(-$0.y*100)}
    let opposite=backPoints.filter{(33...37).contains($0.x*100) && (44...52).contains(-$0.y*100)}
    XCTAssertFalse(marked.isEmpty);XCTAssertFalse(opposite.isEmpty)
    XCTAssertGreaterThan(marked.map(\.z).max() ?? -.infinity,-0.0035)
    XCTAssertTrue(opposite.allSatisfy{abs($0.z+0.004)<1e-10},"The canonical back mark must not mirror onto the other half.")
    let uv=try XCTUnwrap(mesh.sources(for:.texcoord).first).points
    for (p,t) in zip(points,uv) {XCTAssertEqual(t.x,p.x,accuracy:1e-10);XCTAssertEqual(t.y,-p.y,accuracy:1e-10)}
  }

  func testThinPanelCannotExceedItsRasterPixelAllocation()throws {
    let maps=try PaperSurfaceRasterizer.make(rect:.init(x:30,y:40,width:1000,height:0.01),
      netSize:.init(1100,50),profile:.init(texture:.smooth,textureDepthMM:0),color:"#FFFFFF",
      grain:.unknown,artwork:nil,finishes:[],assets:FileManager.default.temporaryDirectory,
      maximumEdge:8192,pixelBudget:64)
    XCTAssertLessThanOrEqual(maps.width*maps.height,64)
    XCTAssertEqual(maps.height,1)
  }

  func testFinalOnlyPlanKeepsPhysicalExportMeshSeparate()throws {
    var project=Project(name:"Finish separation")
    var object=try project.makeObject(recipeID:"paperEnvelope")
    object.parameters["fold"]=0
    var paper=try PaperConstruction.definition(for:object)
    let net=try paper.net()
    let bounds=try XCTUnwrap(net.panels.first{$0.id==net.rootPanelID}).bounds
    let mark=ArtworkElement(kind:"rectangle",x:bounds.x+bounds.width*0.25,
      y:bounds.y+bounds.height*0.25,width:bounds.width*0.4,height:bounds.height*0.4,color:"#000000")
    object.artwork=Artwork(elements:[mark])
    paper.finishes=[.init(name:"Raised source",kind:.emboss,elementIDs:[mark.id],heightMM:0.1)]
    object.paperConstruction=paper;project.objects=[object]
    let ordinary=try PaperGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:256)
    let plan=SourceTextureSamplingPlan(raster:.init(maximumEdge:512,maximumPixels:512*512),isFinalCapture:true)
    let final=try PaperGeometry.make(object,project:project,assets:FileManager.default.temporaryDirectory,limit:256,sampling:plan)
    var ordinaryNames=[String](),finalNames=[String]()
    ordinary.enumerateChildNodes{node,_ in if let name=node.geometry?.name{ordinaryNames.append(name)}}
    final.enumerateChildNodes{node,_ in if let name=node.geometry?.name{finalNames.append(name)}}
    XCTAssertFalse(ordinaryNames.contains{$0.hasPrefix("paper.relief.render:")})
    XCTAssertTrue(finalNames.contains{$0.hasPrefix("paper.relief.render:")})
    XCTAssertEqual(project.objects.first,object)
  }
}
