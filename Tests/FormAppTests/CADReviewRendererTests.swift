import AppKit
import LabRendering
import Metal
import simd
import XCTest
@testable import FormApp

@MainActor final class CADReviewRendererTests:XCTestCase {
  private func scene()->[SceneRenderablePayload] {
    let mesh=SceneMeshPayload(id:"review-box",revision:"1",positionsMM:[.init(-50,-30,-20),.init(50,-30,-20),.init(50,30,-20),.init(-50,30,-20),.init(-50,-30,20),.init(50,-30,20),.init(50,30,20),.init(-50,30,20)],parts:[.init(triangleIndices:[0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5])])
    return [.init(componentID:"left",objectID:UUID(),mesh:mesh,materials:[.init(id:"red",baseColor:.init(1,0,0,1),doubleSided:true,unlit:true)],transform:.init(translationMM:.init(-120,0,0))),.init(componentID:"right",objectID:UUID(),mesh:mesh,materials:[.init(id:"blue",baseColor:.init(0,0,1,1),doubleSided:true,unlit:true)],transform:.init(translationMM:.init(140,70,-50)))]
  }
  func testEveryNamedReviewCameraFramesEveryComponentAtPortraitAndLandscapeAspects()throws {
    let scene=scene()
    for view in ["perspective","front","top"] {for (width,height) in [(640,360),(360,640)] {
      let camera=try CADReviewRenderer.camera(scene:scene,view:view,width:width,height:height)
      switch camera.projection {
      case .orthographic:XCTAssertNotEqual(view,"perspective")
      case .perspective:XCTAssertEqual(view,"perspective")
      }
      for payload in scene {for p in payload.mesh.positionsMM {
        let q=payload.transform.matrixMM*SIMD4(p,1),pixel=try XCTUnwrap(SceneProjection.project(.init(q.x,q.y,q.z),camera:camera,viewport:.init(width:width,height:height)))
        XCTAssertGreaterThan(pixel.x,0);XCTAssertLessThan(pixel.x,Double(width))
        XCTAssertGreaterThan(pixel.y,0);XCTAssertLessThan(pixel.y,Double(height))
      }}
    }}
    XCTAssertThrowsError(try CADReviewRenderer.camera(scene:scene,view:"selected",width:640,height:360))
    XCTAssertThrowsError(try CADReviewRenderer.camera(scene:scene,view:"front",width:0,height:360))
    XCTAssertThrowsError(try CADReviewRenderer.camera(scene:scene,view:"front",width:8192,height:8192))
    XCTAssertThrowsError(try CADReviewRenderer.camera(scene:[],view:"front",width:640,height:360))
    XCTAssertThrowsError(try CADReviewRenderer.camera(scene:[scene[0],scene[0]],view:"front",width:640,height:360))
  }
  func testUncommittedReviewProducesExactTransparentGPUImagesWithoutMutatingSource()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Actual CAD review pixels require Metal.")}
    _=NSApplication.shared;let scene=scene(),originalVertices=scene.map(\.mesh.positionsMM),originalTransforms=scene.map(\.transform)
    for view in ["perspective","front","top"] {
      let image=try await CADReviewRenderer.render(scene:scene,view:view,width:360,height:240,transparent:true)
      let cg=try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),bitmap=NSBitmapImageRep(cgImage:cg)
      XCTAssertEqual(cg.width,360);XCTAssertEqual(cg.height,240)
      XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x:0,y:0)).alphaComponent,0.01)
      var red=0,blue=0
      for y in stride(from:0,to:240,by:2){for x in stride(from:0,to:360,by:2){
        let color=try XCTUnwrap(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB))
        if color.alphaComponent>0.9 && color.redComponent>color.blueComponent+0.5 {red+=1}
        if color.alphaComponent>0.9 && color.blueComponent>color.redComponent+0.5 {blue+=1}
      }}
      XCTAssertGreaterThan(red,100,view);XCTAssertGreaterThan(blue,100,view)
    }
    XCTAssertEqual(scene.map(\.mesh.positionsMM),originalVertices)
    XCTAssertEqual(scene.map(\.transform),originalTransforms)
  }
}
