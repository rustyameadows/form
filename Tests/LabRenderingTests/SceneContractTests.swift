import AppKit
import Foundation
import Metal
import simd
import XCTest
import LabRendering

final class SceneContractTests:XCTestCase {
  private func mesh()->SceneMeshPayload {
    .init(id:"triangle",revision:"1",positionsMM:[.init(-50,-50,0),.init(50,-50,0),.init(0,50,0)],normals:Array(repeating:.init(0,0,1),count:3),uvs:[.init(0,1),.init(1,1),.init(0.5,0)],parts:[.init(triangleIndices:[0,1,2],semanticID:"front")])
  }
  func testRejectsMalformedBuffersIndicesAndPhysicalCoordinates()throws {
    var bad=mesh();bad.parts[0].triangleIndices=[0,1,3];XCTAssertThrowsError(try bad.validate(materialCount:1))
    bad=mesh();bad.parts[0].materialIndex=1;XCTAssertThrowsError(try bad.validate(materialCount:1))
    bad=mesh();bad.positionsMM[0].x = .nan;XCTAssertThrowsError(try bad.validate(materialCount:1))
    bad=mesh();bad.normals[1] = .zero;XCTAssertThrowsError(try bad.validate(materialCount:1))
    bad=mesh();bad.uvs.removeLast();XCTAssertThrowsError(try bad.validate(materialCount:1))
    XCTAssertNoThrow(try mesh().validate(materialCount:1))
  }
  func testPerspectiveAndOrthographicProjectionRoundTripPhysicalPoints()throws {
    for projection:SceneCameraProjection in [.perspective(verticalFieldOfViewDegrees:39),.orthographic(verticalSpanMM:180)] {
      let camera=SceneCameraPayload.looking(from:.init(0,0,300),at:.zero,projection:projection)
      try camera.validate();let viewport=CGSize(width:1000,height:700)
      for source in [SIMD3<Double>(0,0,0),.init(31,17,0),.init(-22,-35,0)] {
        let point=try XCTUnwrap(SceneProjection.project(source,camera:camera,viewport:viewport))
        let ray=try XCTUnwrap(SceneProjection.ray(camera:camera,atTopLeft:point,viewport:viewport))
        let restored=try XCTUnwrap(SceneProjection.intersect(ray,planePointMM:.zero,normal:.init(0,0,1)))
        XCTAssertEqual(restored.x,source.x,accuracy:1e-10);XCTAssertEqual(restored.y,source.y,accuracy:1e-10);XCTAssertEqual(restored.z,0,accuracy:1e-10)
      }
    }
  }
  func testOrthographicSpanDoesNotChangeWithCameraDistance()throws {
    let a=SceneCameraPayload.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:200)),b=SceneCameraPayload.looking(from:.init(0,0,900),at:.zero,projection:.orthographic(verticalSpanMM:200)),size=CGSize(width:600,height:400)
    XCTAssertEqual(SceneProjection.project(.init(40,20,0),camera:a,viewport:size),SceneProjection.project(.init(40,20,0),camera:b,viewport:size))
  }
  func testSemanticPickingUsesActualTrianglesAndPhysicalTransforms()throws {
    let id=UUID(),payload=SceneRenderablePayload(componentID:"part",objectID:id,mesh:mesh(),materials:[.init(id:"material")],transform:.init(translationMM:.init(20,10,40),scale:.init(2,1,1)))
    let ray=SceneRay(originMM:.init(20,10,300),direction:.init(0,0,-1)),hit=try XCTUnwrap(SceneProjection.pick(ray:ray,in:payload))
    XCTAssertEqual(hit.objectID,id);XCTAssertEqual(hit.componentID,"part");XCTAssertEqual(hit.partID,"front");XCTAssertEqual(hit.distanceMM,260,accuracy:1e-10)
    XCTAssertNil(SceneProjection.pick(ray:.init(originMM:.init(100,55,300),direction:.init(0,0,-1)),in:payload)) // inside bounds, outside triangle
    var hidden=payload;hidden.visible=false;XCTAssertNil(SceneProjection.pick(ray:ray,in:hidden))
  }
  func testSingularTransformsAndNonRigidCameraMatricesAreNotSilentlyAccepted()throws {
    XCTAssertThrowsError(try SceneTransformPayload(scale:.init(1,0,1)).validate())
    XCTAssertThrowsError(try SceneTransformPayload(rotationXYZW:.zero).validate())
    var c=SceneCameraPayload();c.worldFromCameraMM.columns.0.x=2;XCTAssertThrowsError(try c.validate())
    XCTAssertThrowsError(try SceneCameraPayload(projection:.orthographic(verticalSpanMM:0)).validate())
  }
  @MainActor func testRealityKitExactPixelCaptureAndTransparentBackground()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required for actual RealityKit rendering.")}
    _=NSApplication.shared
    let r=try RealityKitSceneRenderer(),id=UUID()
    try r.upsert(.init(componentID:"triangle",objectID:id,mesh:mesh(),materials:[.init(id:"red",baseColor:.init(1,0,0,1),unlit:true)]))
    try r.setCamera(.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:180)))
    let image=try await r.capture(width:320,height:240,transparent:true)
    XCTAssertEqual(image.width,320);XCTAssertEqual(image.height,240)
    let rep=NSBitmapImageRep(cgImage:image),corner=try XCTUnwrap(rep.colorAt(x:0,y:0)),center=try XCTUnwrap(rep.colorAt(x:160,y:120))
    XCTAssertLessThan(corner.alphaComponent,0.01);XCTAssertGreaterThan(center.alphaComponent,0.99)
    XCTAssertGreaterThan(center.redComponent,0.95);XCTAssertLessThan(center.greenComponent,0.05)
    // Pixel and neutral projection must agree; RealityKit scale is a half-span.
    let nearTop=try XCTUnwrap(rep.colorAt(x:160,y:65))
    XCTAssertGreaterThan(nearTop.alphaComponent,0.95)
    XCTAssertEqual(r.pick(atTopLeft:.init(x:160,y:120),viewport:.init(width:320,height:240))?.objectID,id)
  }
  @MainActor func testTransformAndMaterialUpdatesReuseMeshAndFailedUpdateRetainsVisibleSource()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required for actual RealityKit rendering.")}
    _=NSApplication.shared
    let r=try RealityKitSceneRenderer(),id=UUID(),source=SceneRenderablePayload(componentID:"triangle",objectID:id,mesh:mesh(),materials:[.init(id:"red",baseColor:.init(1,0,0,1),unlit:true)])
    try r.upsert(source);let builds=r.diagnostics.meshBuilds
    try r.setTransform(.init(translationMM:.init(5,0,0)),componentID:"triangle")
    try r.setMaterials([.init(id:"blue",baseColor:.init(0,0,1,1),unlit:true)],componentID:"triangle")
    XCTAssertEqual(r.diagnostics.meshBuilds,builds)
    var invalid=source;invalid.mesh.revision="2";invalid.mesh.positionsMM=invalid.mesh.positionsMM.map{$0+SIMD3(1000,0,0)}
    var pixels=[UInt8](repeating:255,count:16)
    let image=try XCTUnwrap(CGContext(data:&pixels,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    invalid.materials=[.init(id:"unsupported-uv1",unlit:true,baseColorTexture:.init(image:image,revision:"1",uvIndex:1))]
    XCTAssertThrowsError(try r.upsert(invalid))
    try r.setCamera(.looking(from:.init(0,0,300),at:.zero));XCTAssertEqual(r.pick(atTopLeft:.init(x:160,y:120),viewport:.init(width:320,height:240))?.objectID,id)
    let frame=try await r.capture(width:320,height:240,transparent:false);XCTAssertGreaterThan(try XCTUnwrap(NSBitmapImageRep(cgImage:frame).colorAt(x:160,y:120)).blueComponent,0.9)
    r.reset();XCTAssertEqual(r.diagnostics.componentCount,0);XCTAssertEqual(r.diagnostics.meshCacheBytes,0);XCTAssertEqual(r.diagnostics.textureCacheBytes,0)
  }
  func testNormalStrengthUsesLinearVectorDataAndRetainsSource()throws {
    let bytes:[UInt8]=[191,128,238,255],provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
    let source=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let flat=try SceneTextureProcessing.normalMap(source,strength:0),strong=try SceneTextureProcessing.normalMap(source,strength:2)
    let flatBytes=try XCTUnwrap(flat.dataProvider?.data) as Data,strongBytes=try XCTUnwrap(strong.dataProvider?.data) as Data
    XCTAssertEqual(flatBytes[0],128);XCTAssertEqual(flatBytes[1],128);XCTAssertEqual(flatBytes[2],255)
    XCTAssertGreaterThan(strongBytes[0],191);XCTAssertLessThan(strongBytes[2],238)
    XCTAssertEqual(try XCTUnwrap(source.dataProvider?.data) as Data,Data(bytes))
    XCTAssertThrowsError(try SceneTextureProcessing.normalMap(source,strength:.nan))
  }
  @MainActor func testLinearImportedColorFactorsAreNotInterpretedAsEncodedSRGB()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared;let r=try RealityKitSceneRenderer()
    try r.setCamera(.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:180)))
    var values=[CGFloat]()
    for encoding in [SceneColorEncoding.srgb,.linearSRGB] {
      try r.upsert(.init(componentID:"triangle",objectID:UUID(),mesh:mesh(),materials:[.init(id:"gray-"+encoding.rawValue,baseColor:.init(0.5,0.5,0.5,1),colorEncoding:encoding,unlit:true)]))
      let frame=try await r.capture(width:240,height:240,transparent:true),color=try XCTUnwrap(NSBitmapImageRep(cgImage:frame).colorAt(x:120,y:120)?.usingColorSpace(.sRGB))
      XCTAssertEqual(color.redComponent,color.greenComponent,accuracy:0.01)
      values.append(color.redComponent)
    }
    // Both pass through the chosen photographic tone curve; the linear glTF
    // factor must remain physically brighter than the encoded sRGB value.
    XCTAssertGreaterThan(values[1],values[0]+0.15)
  }
  @MainActor func testMultipleMaterialSlotsProduceIndependentGPUColors()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared;let r=try RealityKitSceneRenderer()
    let quad=SceneMeshPayload(id:"quad",revision:"1",positionsMM:[.init(-50,-50,0),.init(50,-50,0),.init(50,50,0),.init(-50,50,0)],normals:Array(repeating:.init(0,0,1),count:4),parts:[.init(materialIndex:0,triangleIndices:[0,1,2]),.init(materialIndex:1,triangleIndices:[0,2,3])])
    try r.upsert(.init(componentID:"quad",objectID:UUID(),mesh:quad,materials:[.init(id:"red",baseColor:.init(1,0,0,1),unlit:true),.init(id:"blue",baseColor:.init(0,0,1,1),unlit:true)]))
    try r.setCamera(.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:180)))
    let frame=try await r.capture(width:320,height:240,transparent:true),rep=NSBitmapImageRep(cgImage:frame)
    XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:200,y:150)).redComponent,0.95)
    XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:120,y:80)).blueComponent,0.95)
  }

  @MainActor func testTextureRowsUseTopLeftUVOrigin()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared;let r=try RealityKitSceneRenderer()
    // Decoded image row zero is the top row: red above blue.
    let bytes:[UInt8]=[255,0,0,255,255,0,0,255,0,0,255,255,0,0,255,255]
    let provider=try XCTUnwrap(CGDataProvider(data:Data(bytes) as CFData))
    let image=try XCTUnwrap(CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    let quad=SceneMeshPayload(id:"uv-quad",revision:"1",positionsMM:[.init(-50,-50,0),.init(50,-50,0),.init(50,50,0),.init(-50,50,0)],normals:Array(repeating:.init(0,0,1),count:4),uvs:[.init(0,1),.init(1,1),.init(1,0),.init(0,0)],parts:[.init(triangleIndices:[0,1,2,0,2,3])])
    try r.upsert(.init(componentID:"quad",objectID:UUID(),mesh:quad,materials:[.init(id:"image",unlit:true,baseColorTexture:.init(image:image,revision:"rows",wrapS:.clamp,wrapT:.clamp))]))
    try r.setCamera(.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:140)))
    let frame=try await r.capture(width:280,height:280,transparent:true),rep=NSBitmapImageRep(cgImage:frame)
    let top=try XCTUnwrap(rep.colorAt(x:140,y:65)),bottom=try XCTUnwrap(rep.colorAt(x:140,y:215))
    XCTAssertGreaterThan(top.redComponent,top.blueComponent+0.5)
    XCTAssertGreaterThan(bottom.blueComponent,bottom.redComponent+0.5)
  }
  @MainActor func testLargeWorldCoordinatesRetainMillimeterProjectionAndSharedInstances()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared;let r=try RealityKitSceneRenderer(),id=UUID(),offset=SIMD3<Double>(1_000_000_000,2_000_000_000,-1_000_000_000)
    let material=SceneMaterialPayload(id:"red",baseColor:.init(1,0,0,1),unlit:true)
    for i in 0..<12 {try r.upsert(.init(componentID:"triangle-\(i)",objectID:i==0 ? id:UUID(),mesh:mesh(),materials:[material],transform:.init(translationMM:offset+SIMD3(Double(i)*200,0,0))))}
    try r.setCamera(.looking(from:offset+SIMD3(0,0,300),at:offset,projection:.orthographic(verticalSpanMM:180)))
    XCTAssertEqual(r.diagnostics.meshBuilds,1);XCTAssertEqual(r.diagnostics.materialBuilds,1)
    XCTAssertGreaterThan(simd_length(r.floatingOriginMM),1_000_000)
    XCTAssertEqual(r.pick(atTopLeft:.init(x:160,y:120),viewport:.init(width:320,height:240))?.objectID,id)
    let image=try await r.capture(width:320,height:240,transparent:true),rep=NSBitmapImageRep(cgImage:image)
    XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:160,y:120)).redComponent,0.95)
    XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:160,y:65)).alphaComponent,0.95)
  }

  @MainActor func testSixtyFourDenseSharedInstancesPickTheCorrectObjectWithinInteractiveBudget()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared;let renderer=try RealityKitSceneRenderer(),side=129
    let positions=(0..<side).flatMap{y in (0..<side).map{x in SIMD3<Double>(Double(x)-64,Double(y)-64,0)}}
    var indices=[UInt32]()
    for y in 0..<side-1 {for x in 0..<side-1 {let a=UInt32(y*side+x),b=a+1,c=a+UInt32(side),d=c+1;indices += [a,b,d,a,d,c]}}
    let dense=SceneMeshPayload(id:"shared-dense-grid",revision:"1",positionsMM:positions,normals:Array(repeating:.init(0,0,1),count:positions.count),parts:[.init(triangleIndices:indices,semanticID:"surface")])
    let selected=UUID(),material=SceneMaterialPayload(id:"shared-material",baseColor:.init(0.4,0.5,0.6,1),unlit:true)
    for y in 0..<8 {for x in 0..<8 {try renderer.upsert(.init(componentID:"instance-\(x)-\(y)",objectID:x==4 && y==4 ? selected:UUID(),mesh:dense,materials:[material],transform:.init(translationMM:.init(Double(x)*160,Double(y)*160,0))))}}
    try renderer.setCamera(.looking(from:.init(640,640,300),at:.init(640,640,0),projection:.orthographic(verticalSpanMM:180)))
    var milliseconds=[Double]()
    for _ in 0..<20 {
      let start=CFAbsoluteTimeGetCurrent(),hit=renderer.pick(atTopLeft:.init(x:200,y:200),viewport:.init(width:400,height:400))
      milliseconds.append((CFAbsoluteTimeGetCurrent()-start)*1000)
      XCTAssertEqual(hit?.objectID,selected);XCTAssertEqual(hit?.componentID,"instance-4-4");XCTAssertEqual(hit?.partID,"surface")
    }
    XCTAssertEqual(renderer.diagnostics.meshBuilds,1);XCTAssertEqual(renderer.diagnostics.materialBuilds,1)
    XCTAssertEqual(renderer.diagnostics.componentCount,64)
    let sorted=milliseconds.sorted(),p95=sorted[Int(Double(sorted.count-1)*0.95)]
    // A broad interaction budget detects accidental whole-scene triangle scans
    // while tolerating CI/GPU host scheduling. Keep the measured cost visible.
    XCTAssertLessThan(p95,100,"Picking 64 instances of a 32,768-triangle shared mesh must remain interactive.")
    print("LAB_RENDERER_PICK_STRESS",["instances":64,"visible_triangles":dense.triangleCount*64,"p95_ms":p95,"maximum_ms":sorted.last!])
  }

  @MainActor func testAsyncUploadsSurviveRepeatedShortLivedRendererCapturesAndReset()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("A Metal device is required.")}
    _=NSApplication.shared
    for _ in 0..<5 {
      let renderer=try RealityKitSceneRenderer(),id=UUID()
      try await renderer.upsertAsync(.init(componentID:"source",objectID:id,mesh:mesh(),materials:[.init(id:"red",baseColor:.init(1,0,0,1),unlit:true)]))
      try renderer.setCamera(.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:180)))
      let image=try await renderer.capture(width:160,height:120,transparent:true)
      XCTAssertGreaterThan(try XCTUnwrap(NSBitmapImageRep(cgImage:image).colorAt(x:80,y:60)).redComponent,0.95)
      XCTAssertEqual(renderer.diagnostics.meshBuilds,1)
    }
    let renderer=try RealityKitSceneRenderer();var started=false
    let upload=Task { @MainActor in
      started=true
      try await renderer.upsertAsync(.init(componentID:"late",objectID:UUID(),mesh:mesh(),materials:[.init(id:"default")]))
    }
    while !started {await Task.yield()}
    renderer.reset()
    do {try await upload.value}catch {XCTAssertTrue(error is SceneRendererError || error is CancellationError)}
    XCTAssertEqual(renderer.diagnostics.componentCount,0,"An older asynchronous upload cannot repopulate a reset project scene.")
  }

}
