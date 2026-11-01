import AppKit
import FormCADModel
import FormCore
import FormGraphics
import FormGeometry
import LabRendering
import simd
import XCTest
@testable import FormApp

@MainActor final class StudioSourceSamplingTests: XCTestCase {
  private func camera(span:Double=100,eye:Double=1000)->SceneCameraPayload {
    var transform = matrix_identity_double4x4
    transform.columns.3.z=eye
    if eye<0 {transform.columns.0.x = -1;transform.columns.2.z = -1}
    return .init(worldFromCameraMM:transform,projection:.orthographic(verticalSpanMM:span),nearMM:1,farMM:10000)
  }
  func testDemandUsesActualOutputCameraAndPhysicalAspect() throws {
    let world: [SIMD3<Double>] = [.init(-50,25,0),.init(50,25,0),.init(50,-25,0),.init(-50,-25,0)]
    let viewport=CGSize(width:4096,height:2048)
    let normal=StudioSourceSampling.quadDemand(world:world,width:100,height:50,camera:camera(span:100),viewport:viewport)
    let wide=StudioSourceSampling.quadDemand(world:world,width:100,height:50,camera:camera(span:200),viewport:viewport)
    XCTAssertEqual(normal.edge,2048,accuracy:0.0001)
    XCTAssertEqual(wide.edge,1024,accuracy:0.0001)
    var perspective=camera();perspective.projection = .perspective(verticalFieldOfViewDegrees:39)
    let actual=StudioSourceSampling.quadDemand(world:world,width:100,height:50,camera:perspective,viewport:viewport)
    let expected=100*2048/(2*1000*tan(39*Double.pi/360))
    XCTAssertEqual(actual.edge,expected,accuracy:0.0001)
    perspective.projection = .perspective(verticalFieldOfViewDegrees:70)
    let expanded=StudioSourceSampling.quadDemand(world:world,width:100,height:50,camera:perspective,viewport:viewport)
    XCTAssertLessThan(expanded.edge,actual.edge)
  }
  func testCameraFlipReallocatesCanonicalFrontAndBackWithoutChangingSource() throws {
    let definition=PlanarConstructionDefinition(name:"Sampling sheet",size:.init(96,24),panels:[
      .init(id:"sheet",name:"Sheet",polygon:[.init(0,0),.init(96,0),.init(96,24),.init(0,24)])],rootPanelID:"sheet")
    var object=ProductObject(name:"Sheet",recipeID:"source-authored",parameters:[:])
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:96,height:24,depth:1))
    paper.authored=definition;object.paperConstruction=paper
    var project=Project(name:"Sampling");project.objects=[object]
    let before=project,controller=TableSceneController()
    let owner=MeshNode();owner.name="object:"+object.id.uuidString
    let panel=MeshNode();panel.name=PaperGeometry.panelPrefix+"sheet";owner.addChildNode(panel)
    controller.objectRoot.addChildNode(owner)
    let front=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera(span:24),
      viewport:.init(width:4096,height:1024),objectIDs:[object.id],maximumEdge:8192)
    let reverse=try StudioSourceSampling.plans(controller:controller,project:project,camera:camera(span:24,eye:-1000),
      viewport:.init(width:4096,height:1024),objectIDs:[object.id],maximumEdge:8192)
    let f=try XCTUnwrap(front[object.id]),r=try XCTUnwrap(reverse[object.id])
    let outside=SourceTextureSamplingPlan.paperFace("sheet",inside:false),inside=SourceTextureSamplingPlan.paperFace("sheet",inside:true)
    XCTAssertGreaterThan(try XCTUnwrap(f.surfaces[outside]).maximumPixels,try XCTUnwrap(f.surfaces[inside]).maximumPixels)
    XCTAssertGreaterThan(try XCTUnwrap(r.surfaces[inside]).maximumPixels,try XCTUnwrap(r.surfaces[outside]).maximumPixels)
    XCTAssertTrue(f.isFinalCapture);XCTAssertEqual(project,before)
  }
  func testFullResolutionPaperSourceRetainsFineRulesAndLetteringBeyond2048() throws {
    let assets=FileManager.default.temporaryDirectory
    var elements=[ArtworkElement(kind:"text",x:12,y:2,width:80,height:5,
      text:"Fine editable lettering / 3072 source pixels",color:"#000000",fontSize:3)]
    for i in 0..<128 {
      elements.append(.init(kind:"rectangle",x:Double(i)/16,y:0,width:1.0/32,height:24,color:"#000000"))
    }
    let art=Artwork(background:"#FFFFFF",elements:elements)
    let profile=PaperSurfaceProfile(texture:.smooth,roughness:0.9,textureScaleMM:1,textureDepthMM:0)
    let high=try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:96,height:24),netSize:.init(96,24),
      profile:profile,color:"#FFFFFF",grain:.unknown,artwork:art,finishes:[],assets:assets,
      maximumEdge:3072,pixelBudget:3072*768)
    let low=try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:96,height:24),netSize:.init(96,24),
      profile:profile,color:"#FFFFFF",grain:.unknown,artwork:art,finishes:[],assets:assets,
      maximumEdge:2048,pixelBudget:2048*512)
    XCTAssertEqual(high.width,3072);XCTAssertEqual(high.height,768)
    XCTAssertGreaterThan(high.width,low.width)
    func transitions(_ image:NSImage)throws->Int {
      let original=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
      let context=try XCTUnwrap(CGContext(data:nil,width:3072,height:768,bitsPerComponent:8,bytesPerRow:3072*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.interpolationQuality = .high;context.draw(original,in:.init(x:0,y:0,width:3072,height:768))
      let bytes=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
      var count=0
      for x in 1..<254 {
        let a=Int(bytes[(384*3072+x-1)*4]),b=Int(bytes[(384*3072+x)*4])
        if abs(a-b)>200 {count+=1}
      }
      return count
    }
    XCTAssertGreaterThan(try transitions(high.color),200)
    XCTAssertGreaterThan(try transitions(high.color),try transitions(low.color)+100)
    let repeated=try PaperSurfaceRasterizer.make(rect:.init(x:0,y:0,width:96,height:24),netSize:.init(96,24),
      profile:profile,color:"#FFFFFF",grain:.unknown,artwork:art,finishes:[],assets:assets,
      maximumEdge:3072,pixelBudget:3072*768)
    XCTAssertEqual(repeated.revision,high.revision)
    XCTAssertNotEqual(low.revision,high.revision)
    // The area outside the fine-rule strip contains only the authored small text.
    let letterContext=try XCTUnwrap(CGContext(data:nil,width:3072,height:768,bitsPerComponent:8,bytesPerRow:3072*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    letterContext.draw(try XCTUnwrap(high.color.cgImage(forProposedRect:nil,context:nil,hints:nil)),
      in:.init(x:0,y:0,width:3072,height:768))
    let letterBytes=try XCTUnwrap(letterContext.data).assumingMemoryBound(to:UInt8.self)
    var letterPixels=0
    for y in 0..<768 {for x in 400..<3072 {
      if letterBytes[(y*3072+x)*4]<76 {letterPixels+=1}
    }}
    XCTAssertGreaterThan(letterPixels,200,"Small type must be present in actual high-resolution material pixels.")
    XCTAssertEqual(art.elements[0].text,"Fine editable lettering / 3072 source pixels")
  }
}
