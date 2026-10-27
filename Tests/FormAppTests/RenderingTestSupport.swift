import AppKit
import FormGeometry
import LabRendering
import simd
@testable import FormApp

extension MeshNode {
  var simdWorldRight:SIMD3<Double> {let v=worldTransform.raw.columns.0;return simd_normalize(.init(v.x,v.y,v.z))}
  var simdWorldUp:SIMD3<Double> {let v=worldTransform.raw.columns.1;return simd_normalize(.init(v.x,v.y,v.z))}
  var simdWorldOrientation:simd_quatf {simd_quatf(simd_float3x3(columns:(SIMD3<Float>(simdWorldRight),SIMD3<Float>(simdWorldUp),simd_cross(SIMD3<Float>(simdWorldRight),SIMD3<Float>(simdWorldUp)))))}
}
@MainActor enum RenderingTestSupport {
  static func capture(_ scene:MeshScene,camera:MeshNode,size:CGSize)async throws->NSImage {
    let adapter=GeometryPayloadAdapter(),renderer=try RealityKitSceneRenderer()
    for payload in adapter.renderables(scene:scene){try renderer.upsert(payload)}
    let lens=camera.camera ?? MeshCamera();var matrix=camera.worldTransform.raw;matrix.columns.3.x *= 100;matrix.columns.3.y *= 100;matrix.columns.3.z *= 100
    try renderer.setCamera(.init(worldFromCameraMM:matrix,projection:lens.usesOrthographicProjection ? .orthographic(verticalSpanMM:lens.orthographicScale*200):.perspective(verticalFieldOfViewDegrees:lens.fieldOfView),nearMM:lens.zNear*100,farMM:lens.zFar*100))
    try renderer.setLighting(.init(background:GeometryPayloadAdapter.color(scene.background.contents)))
    return NSImage(cgImage:try await renderer.capture(width:Int(size.width),height:Int(size.height)),size:size)
  }
}
