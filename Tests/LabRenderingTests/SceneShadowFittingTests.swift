import AppKit
import Metal
import simd
import XCTest
@testable import LabRendering

final class SceneShadowFittingTests:XCTestCase {
  private let size=CGSize(width:640,height:480)
  private func subject(scale:Double=1,offset:SIMD3<Double> = .zero)->SceneShadowSubject {
    var transform=matrix_identity_double4x4;transform.columns.3 = .init(offset,1)
    return .init(minimumMM:.init(-100,-30,-2)*scale,maximumMM:.init(100,30,0.28)*scale,worldFromLocalMM:transform)
  }
  func testDirectionalRangeFitsActualCameraVisibleMillimetersAndScalesWithSubjects() {
    let camera=SceneCameraPayload.looking(from:.init(0,0,300),at:.zero)
    let distance=SceneShadowFitting.maximumDistanceMetres(camera:camera,viewport:size,subjects:[subject()])
    XCTAssertEqual(distance,0.3775,accuracy:1e-6)
    var distant=subject();distant.worldFromLocalMM.columns.3 = .init(1_000_000,0,-500_000,1)
    XCTAssertEqual(SceneShadowFitting.maximumDistanceMetres(camera:camera,viewport:size,subjects:[subject(),distant]),distance,
      "Offscreen subjects must not consume a focused object's shadow precision.")
    var largeCamera=SceneCameraPayload.looking(from:.init(0,0,300_000),at:.zero);largeCamera.farMM=1_000_000
    XCTAssertEqual(SceneShadowFitting.maximumDistanceMetres(camera:largeCamera,viewport:size,subjects:[subject(scale:1000)]),distance*1000,accuracy:0.001)
  }
  func testShadowFitPreservesFloatingWorldOffsetsOrthographicViewsAndFarClipping() {
    let offset=SIMD3<Double>(1_000_000,-200_000,300_000)
    let a=SceneCameraPayload.looking(from:.init(0,0,300),at:.zero,projection:.orthographic(verticalSpanMM:180))
    let b=SceneCameraPayload.looking(from:offset+SIMD3(0,0,300),at:offset,projection:.orthographic(verticalSpanMM:180))
    XCTAssertEqual(SceneShadowFitting.maximumDistanceMetres(camera:a,viewport:size,subjects:[subject()]),
      SceneShadowFitting.maximumDistanceMetres(camera:b,viewport:size,subjects:[subject(offset:offset)]))
    var clipped=a;clipped.farMM=310
    XCTAssertLessThanOrEqual(SceneShadowFitting.maximumDistanceMetres(camera:clipped,viewport:size,subjects:[subject()]),0.31)
  }
  private func slab(id:String,ring:[SIMD2<Double>],low:Double,high:Double)->SceneMeshPayload {
    var points=[SIMD3<Double>](),normals=[SIMD3<Float>](),triangles=[UInt32]()
    for top in [false,true] {
      let start=UInt32(points.count);points+=ring.map{.init($0.x,$0.y,top ? high:low)}
      normals+=Array(repeating:.init(0,0,top ? 1:-1),count:ring.count)
      for i in 1..<ring.count-1 {triangles+=top ? [start,start+UInt32(i),start+UInt32(i+1)]:[start,start+UInt32(i+1),start+UInt32(i)]}
    }
    for i in ring.indices {
      let j=(i+1)%ring.count,a=ring[i],b=ring[j],d=b-a,n=simd_normalize(SIMD3<Float>(Float(d.y),Float(-d.x),0)),start=UInt32(points.count)
      points += [.init(a.x,a.y,low),.init(b.x,b.y,low),.init(b.x,b.y,high),.init(a.x,a.y,high)]
      normals+=Array(repeating:n,count:4);triangles += [start,start+1,start+2,start,start+2,start+3]
    }
    return .init(id:id,revision:"1",positionsMM:points,normals:normals,parts:[.init(triangleIndices:triangles)])
  }
  @MainActor func testActualGPUClassicLightOnThinLayeredMaterialDoesNotCreateTriangleShadows()async throws {
    guard MTLCreateSystemDefaultDevice() != nil else{throw XCTSkip("Actual RealityKit shadow review requires Metal.")}
    _=NSApplication.shared
    let renderer=try RealityKitSceneRenderer(),id=UUID(),background=UUID()
    let board=slab(id:"generic-support",ring:[.init(-100,-30),.init(100,-30),.init(100,30),.init(-100,30)],low:-2,high:0)
    let facing=slab(id:"generic-tapered-facing",ring:[.init(-100,-30),.init(100,-30),.init(100.28,-28),.init(100.28,28),.init(100,30),.init(-100,30),.init(-100.28,28),.init(-100.28,-28)],low:0.04,high:0.28)
    try renderer.upsert(.init(componentID:"support",objectID:id,mesh:board,materials:[.init(id:"support-stock",baseColor:.init(0.3,0.32,0.3,1),roughness:0.9)]))
    try renderer.upsert(.init(componentID:"facing",objectID:id,mesh:facing,materials:[.init(id:"facing-stock",baseColor:.init(0.12,0.25,0.21,1),roughness:0.88)]))
    let floor=SceneMeshPayload(id:"large-background",revision:"1",positionsMM:[.init(-1_000_000,-35,-1_000_000),.init(-1_000_000,-35,1_000_000),.init(1_000_000,-35,1_000_000),.init(1_000_000,-35,-1_000_000)],normals:Array(repeating:.init(0,1,0),count:4),parts:[.init(triangleIndices:[0,1,2,0,2,3])])
    try renderer.upsert(.init(componentID:"background",objectID:background,mesh:floor,materials:[.init(id:"background-stock",baseColor:.init(0.94,0.94,0.94,1),roughness:1)],pickable:false))
    let camera=SceneCameraPayload.looking(from:.init(171,65,263),at:.zero)
    try renderer.setCamera(camera)
    var lighting=SceneLightingPayload(keyDirection:.init(6,-12,-7),keyIntensity:3000,fillIntensity:600,shadows:true)
    try renderer.setLighting(lighting);let on=try await renderer.capture(width:640,height:480)
    lighting.shadows=false;try renderer.setLighting(lighting);let off=try await renderer.capture(width:640,height:480)
    let lit=NSBitmapImageRep(cgImage:on),reference=NSBitmapImageRep(cgImage:off)
    var differences=[Double]()
    for y in [-20.0,-10,0,10,20] {for x in [-70.0,-35,0,35,70] {
      let pixel=try XCTUnwrap(SceneProjection.project(.init(x,y,0.28),camera:camera,viewport:size))
      let a=try XCTUnwrap(lit.colorAt(x:Int(pixel.x),y:Int(pixel.y))?.usingColorSpace(.sRGB))
      let b=try XCTUnwrap(reference.colorAt(x:Int(pixel.x),y:Int(pixel.y))?.usingColorSpace(.sRGB))
      differences.append(Double(max(abs(a.redComponent-b.redComponent),abs(a.greenComponent-b.greenComponent),abs(a.blueComponent-b.blueComponent))))
    }}
    let maximum=differences.max() ?? 1
    let supplied=ProcessInfo.processInfo.environment["LAB_SHADOW_EVIDENCE_DIR"]
    let folder=supplied.map{URL(fileURLWithPath:$0)} ?? FileManager.default.temporaryDirectory.appendingPathComponent("lab-shadow-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    for (name,image) in [("classic-shadow-on.png",on),("classic-shadow-off.png",off)] {
      try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])).write(to:folder.appendingPathComponent(name))
    }
    let proof:[String:Any]=["sample_count":differences.count,"maximum_unoccluded_face_difference":maximum,"source_gap_mm":0.04,"cover_caliper_mm":0.24,"normal_map_used":false,"light_direction":[6,-12,-7],"output_folder":folder.path]
    try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("shadow-comparison.json"))
    print("LAB_SHADOW_EVIDENCE",folder.path,"maximum face difference",maximum)
    XCTAssertLessThan(maximum,0.08,"An unoccluded planar facing cannot acquire a broad triangle from its underlying stock's directional shadow.")
  }
}
