import Foundation
import simd

public enum SceneProjection {
  public static func ray(camera:SceneCameraPayload,atTopLeft point:CGPoint,viewport:CGSize)->SceneRay? {
    guard viewport.width>0,viewport.height>0,point.x.isFinite,point.y.isFinite else{return nil}
    let x=2*point.x/viewport.width-1,y=1-2*point.y/viewport.height,aspect=viewport.width/viewport.height
    let origin:SIMD4<Double>,direction:SIMD4<Double>
    switch camera.projection {
    case .perspective(let degrees):let t=tan(degrees * .pi/360);origin = .init(0,0,0,1);direction = .init(x*aspect*t,y*t,-1,0)
    case .orthographic(let span):origin = .init(x*aspect*span/2,y*span/2,0,1);direction = .init(0,0,-1,0)
    }
    let o=camera.worldFromCameraMM*origin,d=camera.worldFromCameraMM*direction
    return .init(originMM:.init(o.x,o.y,o.z),direction:.init(d.x,d.y,d.z))
  }
  public static func project(_ pointMM:SIMD3<Double>,camera:SceneCameraPayload,viewport:CGSize)->CGPoint? {
    guard viewport.width>0,viewport.height>0 else{return nil}
    let p=simd_inverse(camera.worldFromCameraMM)*SIMD4(pointMM,1),depth = -p.z
    guard depth>=camera.nearMM,depth<=camera.farMM else{return nil}
    let x:Double,y:Double,aspect=viewport.width/viewport.height
    switch camera.projection {case .perspective(let degrees):let t=tan(degrees * .pi/360);x=p.x/(depth*t*aspect);y=p.y/(depth*t)
    case .orthographic(let span):x=p.x/(span*aspect/2);y=p.y/(span/2)}
    return .init(x:(x+1)*viewport.width/2,y:(1-y)*viewport.height/2)
  }
  public static func intersect(_ ray:SceneRay,planePointMM:SIMD3<Double>,normal:SIMD3<Double>)->SIMD3<Double>? {
    let divisor=simd_dot(ray.direction,normal);guard abs(divisor)>1e-12 else{return nil}
    let t=simd_dot(planePointMM-ray.originMM,normal)/divisor;guard t.isFinite,t>=0 else{return nil};return ray.originMM+ray.direction*t
  }
  /// Exact triangle intersections, semantic ownership and transforms remain
  /// independent of any renderer's collision-shape approximation.
  public static func pick(ray:SceneRay,in payload:SceneRenderablePayload,localBounds:(low:SIMD3<Double>,high:SIMD3<Double>)?=nil)->ScenePick? {
    guard payload.visible,payload.pickable else{return nil}
    let inverse=simd_inverse(payload.transform.matrixMM),o=inverse*SIMD4(ray.originMM,1),d=inverse*SIMD4(ray.direction,0)
    let origin=SIMD3(o.x,o.y,o.z),direction=SIMD3(d.x,d.y,d.z),positions=payload.mesh.positionsMM
    guard let first=positions.first else{return nil}
    let low:SIMD3<Double>,high:SIMD3<Double>
    if let localBounds {low=localBounds.low;high=localBounds.high}
    else {var lower=first,upper=first;for p in positions.dropFirst(){lower=simd_min(lower,p);upper=simd_max(upper,p)};low=lower;high=upper}
    var entry = -Double.infinity,exit = Double.infinity
    for axis in 0..<3 {
      if abs(direction[axis])<1e-15 {if origin[axis]<low[axis] || origin[axis]>high[axis]{return nil}}
      else {let a=(low[axis]-origin[axis])/direction[axis],b=(high[axis]-origin[axis])/direction[axis];entry=max(entry,min(a,b));exit=min(exit,max(a,b))}
    }
    guard exit>=max(0,entry) else{return nil}
    var result:ScenePick?,nearest=Double.infinity
    for part in payload.mesh.parts {
      for i in stride(from:0,to:part.triangleIndices.count,by:3) {
        guard i+2<part.triangleIndices.count else{continue}
        let ia=Int(part.triangleIndices[i]),ib=Int(part.triangleIndices[i+1]),ic=Int(part.triangleIndices[i+2])
        guard ia<positions.count,ib<positions.count,ic<positions.count else{continue}
        let a=positions[ia],b=positions[ib],c=positions[ic]
        let e1=b-a,e2=c-a,p=simd_cross(direction,e2),det=simd_dot(e1,p)
        guard abs(det)>1e-14 else{continue}
        let inv=1/det,t=origin-a,u=simd_dot(t,p)*inv
        guard u>=(-1e-10),u<=1+1e-10 else{continue}
        let q=simd_cross(t,e1),v=simd_dot(direction,q)*inv
        guard v>=(-1e-10),u+v<=1+1e-10 else{continue}
        let distance=simd_dot(e2,q)*inv
        if distance>=0,distance<nearest {nearest=distance;result = .init(objectID:payload.objectID,componentID:payload.componentID,partID:part.semanticID,triangle:i/3,distanceMM:distance,pointMM:ray.originMM+ray.direction*distance)}
      }
    }
    return result
  }
}
