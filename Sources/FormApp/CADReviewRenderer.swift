import AppKit
import FormCore
import LabRendering
import simd

/// A read-only image of an evaluated, uncommitted model. Its camera and scene
/// never borrow or mutate the project's editing viewport or saved presentation.
@MainActor enum CADReviewRenderer {
  static func render(scene:[SceneRenderablePayload],view:String,width:Int,height:Int,transparent:Bool)async throws->NSImage {
    let camera=try camera(scene:scene,view:view,width:width,height:height)
    try Task.checkCancellation()
    let renderer=try RealityKitSceneRenderer()
    for payload in scene where payload.visible {try await renderer.upsertAsync(payload)}
    try renderer.setCamera(camera)
    try renderer.setLighting(.init(keyIntensity:3200,fillIntensity:700))
    let pixels=try await renderer.capture(width:width,height:height,transparent:transparent)
    try Task.checkCancellation()
    let bitmap=NSBitmapImageRep(cgImage:pixels);bitmap.size = .init(width:width,height:height)
    let image=NSImage(size:bitmap.size);image.addRepresentation(bitmap);return image
  }
  static func camera(scene:[SceneRenderablePayload],view:String,width:Int,height:Int)throws->SceneCameraPayload {
    guard width>0,height>0,width<=8192,height<=8192,Double(width)*Double(height)<=32_000_000 else{throw FormError.invalid("CAD review requires positive pixel dimensions, at most 8192 per edge and 32 megapixels.")}
    guard !scene.isEmpty,scene.count<=256,Set(scene.map(\.componentID)).count==scene.count else{throw FormError.invalid("CAD review requires 1–256 uniquely identified components.")}
    guard ["perspective","front","top"].contains(view) else{throw FormError.invalid("CAD review view must be perspective, front or top.")}
    var points=[SIMD3<Double>](),bytes=0
    for payload in scene where payload.visible {
      try payload.mesh.validate(materialCount:payload.materials.count);try payload.transform.validate()
      bytes+=payload.mesh.approximateBytes
      guard bytes<=256*1024*1024 else{throw FormError.invalid("CAD review source display buffers exceed 256 MiB.")}
      guard let first=payload.mesh.positionsMM.first else{continue}
      var low=first,high=first
      for point in payload.mesh.positionsMM.dropFirst(){low=simd_min(low,point);high=simd_max(high,point)}
      let matrix=payload.transform.matrixMM
      for x in [low.x,high.x]{for y in [low.y,high.y]{for z in [low.z,high.z]{
        let p=matrix*SIMD4(x,y,z,1),point=SIMD3(p.x,p.y,p.z)
        guard point.x.isFinite,point.y.isFinite,point.z.isFinite,simd_reduce_max(simd_abs(point))<=1e12 else{throw FormError.invalid("CAD review bounds exceed the supported finite millimeter domain.")}
        points.append(point)
      }}}
    }
    guard let first=points.first else{throw FormError.invalid("The evaluated model has no visible geometry to review.")}
    var low=first,high=first
    for point in points.dropFirst(){low=simd_min(low,point);high=simd_max(high,point)}
    let center=low+(high-low)/2,radius=max(0.001,simd_length(high-low)/2),aspect=Double(width)/Double(height)
    var state=CameraState()
    if view=="front" {state.azimuth=0;state.elevation=0}
    if view=="top" {state.azimuth=0;state.elevation = .pi/2}
    let basis=CameraNavigation.basis(state)
    let right=SIMD3(basis.right.x,basis.right.y,basis.right.z),up=SIMD3(basis.up.x,basis.up.y,basis.up.z),outward=SIMD3(basis.outward.x,basis.outward.y,basis.outward.z)
    let padding=1.2,tangent=tan(39.0 * .pi/360)
    var extent=max(0.001,radius*0.01),distance=radius*2
    for point in points {
      let p=point-center,e=max(abs(simd_dot(p,up)),abs(simd_dot(p,right))/aspect)
      extent=max(extent,e)
      distance=max(distance,simd_dot(p,outward)+padding*e/tangent)
    }
    let eye=center+outward*distance,near=max(0.000001,min(1,radius*0.001)),far=max(near*100,distance+radius*4)
    let projection:SceneCameraProjection=view=="perspective" ? .perspective(verticalFieldOfViewDegrees:39):.orthographic(verticalSpanMM:2*extent*padding)
    let camera=SceneCameraPayload(worldFromCameraMM:.init(SIMD4(right,0),SIMD4(up,0),SIMD4(outward,0),SIMD4(eye,1)),projection:projection,nearMM:near,farMM:far)
    try camera.validate();return camera
  }
}
