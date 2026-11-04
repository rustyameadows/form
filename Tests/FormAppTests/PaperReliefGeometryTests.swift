import AppKit
import FormCore
import FormGeometry
import FormGraphics
import simd
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
    XCTAssertFalse(marked.isEmpty)
    XCTAssertGreaterThan(marked.map(\.z).max() ?? -.infinity,-0.0035)
    let backSurface=PaperReliefTessellator.Result(vertices:points.map {
      .init(point:.init($0.x*100,-$0.y*100),uv:.zero,baseZ:0,height:$0.z)
    },indices:mesh.elements[1].indices,heightToleranceMM:0)
    XCTAssertEqual(try XCTUnwrap(interpolatedHeight(backSurface,.init(35,48))),-0.004,accuracy:1e-10,
      "The canonical back mark must not mirror onto the other half, which may remain one large triangle.")
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

  /// Deliberately place a curved mark away from the original cap's vertices and
  /// centroids. Height probes alone would miss it without the field hierarchy.
  private func adaptiveField(edge:Int=1024,amount:Double=0.12,radius:Double=6.3,
    center:SIMD2<Double> = .init(39,26)) -> PaperReliefTessellator.Field {
    let width=edge,height=edge*3/4,size=SIMD2<Double>(60,45)
    var values=[Float]();values.reserveCapacity(width*height)
    for y in 0..<height {for x in 0..<width {
      let point=SIMD2((Double(x)+0.5)/Double(width)*size.x,(Double(y)+0.5)/Double(height)*size.y)
      let distance=simd_length(point-center)
      values.append(Float(amount*max(0,min(1,(radius-distance)/0.12+0.5))))
    }}
    return .init(width:width,height:height,origin:.zero,size:size,values:values)
  }
  private func fieldSample(_ field:PaperReliefTessellator.Field,_ point:SIMD2<Double>)->Double {
    let q=(point-field.origin)/field.size*SIMD2(Double(field.width),Double(field.height))-SIMD2(repeating:0.5)
    let x=max(0,min(Double(field.width-1),q.x)),y=max(0,min(Double(field.height-1),q.y))
    let x0=Int(floor(x)),y0=Int(floor(y)),x1=min(x0+1,field.width-1),y1=min(y0+1,field.height-1)
    let u=x-Double(x0),v=y-Double(y0)
    return Double(field.values[y0*field.width+x0])*(1-u)*(1-v)
      + Double(field.values[y0*field.width+x1])*u*(1-v)
      + Double(field.values[y1*field.width+x0])*(1-u)*v
      + Double(field.values[y1*field.width+x1])*u*v
  }
  private func adaptive(_ field:PaperReliefTessellator.Field,budget:Int=48_000)throws->PaperReliefTessellator.Result {
    let points:[SIMD2<Double>]=[.zero,.init(field.size.x,0),field.size,.init(0,field.size.y)]
    let vertices=points.map{PaperReliefTessellator.Vertex(point:$0,uv:$0/field.size,baseZ:0,height:fieldSample(field,$0))}
    return try PaperReliefTessellator.make(vertices:vertices,indices:[0,1,2,0,2,3],field:field,
      triangleBudget:budget,sample:{self.fieldSample(field,$0)})
  }
  private func interpolatedHeight(_ mesh:PaperReliefTessellator.Result,_ point:SIMD2<Double>)->Double? {
    for i in stride(from:0,to:mesh.indices.count,by:3) {
      let a=mesh.vertices[Int(mesh.indices[i])],b=mesh.vertices[Int(mesh.indices[i+1])],c=mesh.vertices[Int(mesh.indices[i+2])]
      let u=b.point-a.point,v=c.point-a.point,p=point-a.point,det=u.x*v.y-u.y*v.x
      let x=(p.x*v.y-p.y*v.x)/det,y=(u.x*p.y-u.y*p.x)/det
      if x >= -1e-9,y >= -1e-9,x+y<=1+1e-9 {return a.height*(1-x-y)+b.height*x+c.height*y}
    }
    return nil
  }

  func testAdaptiveCurvedReliefKeepsSubpixelHeightErrorWithoutUniformSheetSubdivision()throws {
    let field=adaptiveField(),mesh=try adaptive(field)
    var maximumError=0.0,oldUniformError=0.0
    for step in 0..<180 {
      let angle=Double(step)*2*Double.pi/180
      for offset in [-0.06,0.0,0.06] {
        let point=SIMD2<Double>(39,26)+SIMD2(cos(angle),sin(angle))*(6.3+offset)
        let expected=fieldSample(field,point),actual=try XCTUnwrap(interpolatedHeight(mesh,point))
        maximumError=max(maximumError,abs(actual-expected))
        // Independent reconstruction of the former 109-division cap makes the
        // regression about boundary fidelity, not a preferred triangle count.
        let scaled=point/field.size*109,cell=SIMD2(floor(scaled.x),floor(scaled.y)),f=scaled-cell
        let a=fieldSample(field,cell/109*field.size)
        let b=fieldSample(field,(cell+SIMD2(1,0))/109*field.size)
        let c=fieldSample(field,(cell+SIMD2(1,1))/109*field.size)
        let d=fieldSample(field,(cell+SIMD2(0,1))/109*field.size)
        let old=f.x>=f.y ? a+(b-a)*f.x+(c-b)*f.y:a+(c-d)*f.x+(d-a)*f.y
        oldUniformError=max(oldUniformError,abs(old-expected))
      }
    }
    XCTAssertLessThan(maximumError,mesh.heightToleranceMM*2)
    XCTAssertLessThan(maximumError,oldUniformError/5)
    XCTAssertLessThan(mesh.indices.count/3,24_000,"Refine the changing field, not the entire sheet.")
    XCTAssertEqual(try XCTUnwrap(interpolatedHeight(mesh,.init(39,26))),0.12,accuracy:1e-6)
    print("Adaptive relief: \(mesh.indices.count/3) triangles, max boundary height error \(maximumError) mm, old uniform error \(oldUniformError) mm.")
  }

  func testAdaptiveSharedEdgesAreConformingAndUVsRemainRegistered()throws {
    let field=adaptiveField(edge:512),mesh=try adaptive(field)
    var edges=[String:(count:Int,a:Int,b:Int)]()
    for i in stride(from:0,to:mesh.indices.count,by:3) {for j in 0..<3 {
      let a=Int(mesh.indices[i+j]),b=Int(mesh.indices[i+(j+1)%3]),key="\(min(a,b)):\(max(a,b))"
      edges[key]=((edges[key]?.count ?? 0)+1,a,b)
    }}
    for i in stride(from:0,to:mesh.indices.count,by:3) {
      let a=mesh.vertices[Int(mesh.indices[i])].point,b=mesh.vertices[Int(mesh.indices[i+1])].point,c=mesh.vertices[Int(mesh.indices[i+2])].point
      let u=b-a,v=c-a,area=abs(u.x*v.y-u.y*v.x)
      let longest=max(simd_length_squared(u),max(simd_length_squared(v),simd_length_squared(c-b)))
      XCTAssertGreaterThan(area/longest,0.01,"Conformity must not introduce a chain of near-collinear sliver triangles.")
    }
    for edge in edges.values {
      XCTAssertTrue(edge.count==1 || edge.count==2)
      if edge.count==1 {
        let a=mesh.vertices[edge.a].point,b=mesh.vertices[edge.b].point
        XCTAssertTrue((a.x==0 && b.x==0) || (a.y==0 && b.y==0)
          || (a.x==field.size.x && b.x==field.size.x) || (a.y==field.size.y && b.y==field.size.y),
          "An interior edge must have both incident triangles, including across different refinement levels.")
      }
    }
    for vertex in mesh.vertices {
      XCTAssertEqual(vertex.uv.x,vertex.point.x/field.size.x,accuracy:1e-12)
      XCTAssertEqual(vertex.uv.y,vertex.point.y/field.size.y,accuracy:1e-12)
    }
  }

  func testTinyOffGridReliefIsFoundAndLowReliefIsNotDiscarded()throws {
    let center=SIMD2<Double>(31,11)
    for amount in [0.12,0.001] {
      let field=adaptiveField(amount:amount,radius:0.3,center:center),mesh=try adaptive(field)
      XCTAssertEqual(try XCTUnwrap(interpolatedHeight(mesh,center)),amount,accuracy:amount*0.05)
      XCTAssertLessThan(mesh.indices.count/3,2_000)
    }
  }

  func testAdaptiveBudgetFailureIsExplicitInsteadOfReturningCoarseRelief()throws {
    let field=adaptiveField(edge:512)
    XCTAssertThrowsError(try adaptive(field,budget:32)) {error in
      XCTAssertTrue(error.localizedDescription.contains("32-triangle render budget"))
      XCTAssertTrue(error.localizedDescription.contains("height tolerance"))
    }
  }

  func testHighResolutionTextFoilAndCurvedReliefFitTheBoundedFinalFaceAllocation()throws {
    let size=Point2(84,56),panel=PaperPanel(id:"surface",name:"Surface",role:.body,
      polygon:[.init(0,0),.init(84,0),.init(84,56),.init(0,56)])
    let type=ArtworkElement(kind:"text",x:8,y:8,width:65,height:16,text:"TYPE",fontSize:9)
    let bar=ArtworkElement(kind:"rectangle",x:8,y:30,width:20,height:2.5,color:"#BC8E40")
    let curve=ArtworkElement(kind:"ellipse",x:54,y:27,width:14,height:14,color:"#000000")
    let finishes:[PaperFinishAssignment]=[
      .init(name:"Impression",kind:.letterpress,elementIDs:[type.id],depthMM:0.12),
      .init(name:"Deposited finish",kind:.foil,elementIDs:[bar.id],heightMM:0.02),
      .init(name:"Raised contour",kind:.emboss,elementIDs:[curve.id],heightMM:0.12)]
    func raster(_ art:Artwork?,_ finishes:[PaperFinishAssignment],edge:Int)throws->PaperSurfaceRasterizer.Maps {
      try PaperSurfaceRasterizer.make(rect:panel.bounds,netSize:size,
        profile:.init(texture:.smooth,textureDepthMM:0),color:"#FFFFFF",grain:.unknown,
        artwork:art,finishes:finishes,assets:FileManager.default.temporaryDirectory,
        maximumEdge:edge,pixelBudget:3_595_117)
    }
    var art=Artwork(elements:[type,bar,curve]);art.backgroundOpacity=0
    let front=try raster(art,finishes,edge:2048),back=try raster(nil,[],edge:16)
    let base=try PaperGeometry.panelMesh(panel,netSize:size,thicknessMM:0.8)
    let mesh=try PaperReliefGeometry.make(base:base,front:front,back:back,panel:panel,thicknessMM:0.8)
    let points=try XCTUnwrap(mesh.sources(for:.vertex).first).vectors
    let surface=PaperReliefTessellator.Result(vertices:points.map {
      .init(point:.init($0.x*100,-$0.y*100),uv:.zero,baseZ:0,height:($0.z-0.004)*100)
    },indices:mesh.elements[0].indices,heightToleranceMM:0)
    var maximum=0.0
    for i in 0..<72 {
      let angle=Double(i)*2*Double.pi/72,point=SIMD2<Double>(61,34)+SIMD2(cos(angle),sin(angle))*7
      let expected=PaperReliefGeometry.sample(front,at:.init(point.x,point.y))
      maximum=max(maximum,abs(try XCTUnwrap(interpolatedHeight(surface,point))-expected))
    }
    XCTAssertLessThan(maximum,0.02)
    XCTAssertLessThanOrEqual(mesh.elements[0].indices.count/3,PaperReliefGeometry.maximumTrianglesPerFace)
    print("Combined final paper finishes: \(mesh.elements[0].indices.count/3) triangles, max curved boundary error \(maximum) mm.")
  }

  func testCancelledReliefPreparationStopsWithinItsRefinementLoop()async throws {
    let field=adaptiveField()
    let task=Task {try self.adaptive(field)}
    task.cancel()
    do {_ = try await task.value;XCTFail("Cancelled capture preparation must not complete its relief mesh.")}
    catch {XCTAssertTrue(error is CancellationError)}
  }
}
