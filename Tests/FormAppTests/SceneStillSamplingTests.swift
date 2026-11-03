import AppKit
import CoreGraphics
import Metal
import simd
import XCTest
@testable import LabRendering

@MainActor final class SceneStillSamplingTests:XCTestCase {
  private func frame(_ bytes:[UInt8])throws->SceneCaptureImage {
    let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData)),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
    return .init(image:try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)))
  }
  private func bytes(_ image:CGImage)throws->[UInt8] {
    let space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),context=try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setBlendMode(.copy);context.draw(image,in:.init(x:0,y:0,width:image.width,height:image.height))
    let p=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
    return Array(UnsafeBufferPointer(start:p,count:image.width*image.height*4))
  }
  func testLinearEnergyAndPremultipliedTransparency()async throws {
    for (a,b,expected) in [([0,0,0,255],[255,255,255,255],[188,188,188,255]),([255,0,0,255],[0,0,255,255],[188,0,188,255]),([255,0,0,255],[0,0,0,0],[128,0,0,128])] {
      let accumulator=try SceneStillPixelAccumulator(width:1,height:1)
      try await accumulator.append(frame(a.map{UInt8($0)}));try await accumulator.append(frame(b.map{UInt8($0)}))
      let image=try await accumulator.image().image,result=try bytes(image)
      for channel in 0..<4{XCTAssertLessThanOrEqual(abs(Int(result[channel])-expected[channel]),1)}
      XCTAssertEqual(accumulator.byteCount,16)
    }
  }
  func testExistingPixelLimitsAndExplicitAccumulatorBudgetKeepOutputDimensions()throws {
    XCTAssertEqual(try SceneStillSampling.pixelCount(width:8000,height:4000),32_000_000)
    XCTAssertEqual(try SceneStillSampling.accumulatorBytes(width:8000,height:4000),512_000_000)
    XCTAssertThrowsError(try SceneStillSampling.pixelCount(width:8193,height:1))
    XCTAssertThrowsError(try SceneStillSampling.pixelCount(width:8000,height:4001))
    XCTAssertEqual(SceneStillSampling.offsets.count,16)
    XCTAssertEqual(SceneStillSampling.offsets.map(\.x).reduce(0,+),0,accuracy:1e-6)
    XCTAssertEqual(SceneStillSampling.offsets.map(\.y).reduce(0,+),0,accuracy:1e-6)
    XCTAssertTrue(SceneStillSampling.offsets.allSatisfy{abs($0.x)<0.5 && abs($0.y)<0.5})
  }
  func testNominalReverseDepthProjectionMatchesPublicFramingForBothLenses()throws {
    for projection:SceneCameraProjection in [.perspective(verticalFieldOfViewDegrees:39),.orthographic(verticalSpanMM:100)] {
      let camera=SceneCameraPayload.looking(from:.init(180,120,220),at:.zero,projection:projection)
      let matrix=try SceneStillSampling.projection(camera:camera,width:1000,height:800,offset:.zero),view=simd_inverse(camera.worldFromCameraMM)
      for point:SIMD3<Double> in [.zero,.init(10,20,-10),.init(-20,5,12)] {
        let local=view*SIMD4(point,1),clip=matrix*SIMD4<Float>(Float(local.x/1000),Float(local.y/1000),Float(local.z/1000),1)
        let x=Double(clip.x/clip.w+1)*500,y=Double(1-clip.y/clip.w)*400,expected=try XCTUnwrap(SceneProjection.project(point,camera:camera,viewport:.init(width:1000,height:800)))
        XCTAssertEqual(x,expected.x,accuracy:0.001);XCTAssertEqual(y,expected.y,accuracy:0.001)
        XCTAssertGreaterThan(clip.z/clip.w,0);XCTAssertLessThan(clip.z/clip.w,1)
      }
    }
  }
  func testActualGPUStillPreservesOrthographicAndPerspectiveColorSilhouetteAndTransparentAlpha()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Still sampling requires actual Metal.")}
    let renderer=try RealityKitSceneRenderer(),id=UUID()
    let positions:[SIMD3<Double>]=[.init(-25,-25,-25),.init(25,-25,-25),.init(25,25,-25),.init(-25,25,-25),.init(-25,-25,25),.init(25,-25,25),.init(25,25,25),.init(-25,25,25)]
    let indices:[UInt32]=[0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5]
    let payload=SceneRenderablePayload(componentID:"generic-solid",objectID:id,mesh:.init(id:"generic-cube",revision:"1",positionsMM:positions,parts:[.init(triangleIndices:indices)]),materials:[.init(id:"color",baseColor:.init(0.8,0.2,0.1,1),unlit:true)])
    try renderer.upsert(payload);let builds=renderer.diagnostics.meshBuilds
    for projection:SceneCameraProjection in [.perspective(verticalFieldOfViewDegrees:39),.orthographic(verticalSpanMM:100)] {
      let camera=SceneCameraPayload.looking(from:.init(120,90,180),at:.zero,projection:projection)
      try renderer.setCamera(camera)
      for transparent in [false,true] {
        let raw=try await renderer.capture(width:256,height:256,transparent:transparent),rawBytes=try bytes(raw)
        let final=try await renderer.capture(width:256,height:256,transparent:transparent,sampling:.still),finalBytes=try bytes(final)
        XCTAssertEqual(final.width,256);XCTAssertEqual(final.height,256)
        let difference=zip(rawBytes,finalBytes).reduce(0.0){$0+Double(abs(Int($1.0)-Int($1.1)))}/Double(rawBytes.count)/255
        XCTAssertLessThan(difference,0.01,"Sampling must preserve the same lens, silhouette and source color")
        XCTAssertEqual(renderer.diagnostics.meshBuilds,builds);XCTAssertEqual(renderer.diagnostics.lastCaptureSamples,16)
        XCTAssertEqual(renderer.diagnostics.lastCaptureAccumulatorBytes,256*256*16)
        XCTAssertEqual(renderer.camera.projection,camera.projection)
        for column in 0..<4{XCTAssertEqual(renderer.camera.worldFromCameraMM[column],camera.worldFromCameraMM[column])}
      }
    }
  }
  func testCancelledStillDoesNotPublishAnImageOrBuildGeometry()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Still sampling requires actual Metal.")}
    let renderer=try RealityKitSceneRenderer()
    let task=Task { @MainActor in try await renderer.capture(width:64,height:64,sampling:.still) }
    task.cancel()
    do {_ = try await task.value;XCTFail("A cancelled still must not publish an image")}catch is CancellationError {}
    XCTAssertEqual(renderer.diagnostics.offscreenCaptures,0);XCTAssertEqual(renderer.diagnostics.meshBuilds,0)
  }

}
