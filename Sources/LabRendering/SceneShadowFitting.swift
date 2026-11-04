import Foundation
import simd

/// Millimeter bounds of actual subjects, excluding background/technical guides.
struct SceneShadowSubject {
  var minimumMM:SIMD3<Double>,maximumMM:SIMD3<Double>
  var worldFromLocalMM:simd_double4x4
}

/// A kilometre-long automatic range wastes directional-shadow precision on a
/// millimetre-scale layered object. Fit the camera-visible physical subjects,
/// with room for their ground shadow, without changing geometry or lighting.
enum SceneShadowFitting {
  static func maximumDistanceMetres(camera:SceneCameraPayload,viewport:CGSize,subjects:[SceneShadowSubject])->Float {
    let matrix=camera.worldFromCameraMM,eye=SIMD3(matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z)
    let right=SIMD3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z)
    let up=SIMD3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z)
    let forward = -SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z)
    let aspect=max(0.01,Double(viewport.width/max(1,viewport.height)))
    var furthest:Double?
    for subject in subjects {
      var points=[SIMD3<Double>]()
      for x in [subject.minimumMM.x,subject.maximumMM.x] {
        for y in [subject.minimumMM.y,subject.maximumMM.y] {
          for z in [subject.minimumMM.z,subject.maximumMM.z] {
            let p=subject.worldFromLocalMM*SIMD4(x,y,z,1),delta=SIMD3(p.x,p.y,p.z)-eye
            points.append(.init(simd_dot(delta,right),simd_dot(delta,up),simd_dot(delta,forward)))
          }
        }
      }
      guard points.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),
        !points.allSatisfy({$0.z<camera.nearMM}),!points.allSatisfy({$0.z>camera.farMM}) else{continue}
      switch camera.projection {
      case .perspective(let degrees):
        let half=tan(degrees * .pi/360)
        if points.allSatisfy({$0.x < -$0.z*half*aspect}) || points.allSatisfy({$0.x>$0.z*half*aspect})
          || points.allSatisfy({$0.y < -$0.z*half}) || points.allSatisfy({$0.y>$0.z*half}) {continue}
      case .orthographic(let span):
        if points.allSatisfy({$0.x < -span*aspect/2}) || points.allSatisfy({$0.x>span*aspect/2})
          || points.allSatisfy({$0.y < -span/2}) || points.allSatisfy({$0.y>span/2}) {continue}
      }
      let depth=points.map(\.z).max()!
      furthest=max(furthest ?? depth,depth)
    }
    // No physical subject: retain the SDK's ordinary five-metre viewing range.
    // For a subject, the padding follows its viewing depth, not a project name
    // or assumed product size. The camera's own far plane always remains final.
    let distance=furthest.map{$0+max(25,$0*0.25)} ?? 5000
    return Float(max(camera.nearMM,min(camera.farMM,distance))/1000)
  }
}
