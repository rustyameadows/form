import Foundation
import simd

/// Analytic closest point on a closed triangle, with barycentric gradients.
/// Interior plane projection competes with each bounded edge projection;
/// degenerate current triangles safely reduce to their segments/vertices.
enum ClothContactGeometry {
  static func closestPoint(_ point:SIMD3<Double>,a:SIMD3<Double>,b:SIMD3<Double>,c:SIMD3<Double>)->(point:SIMD3<Double>,weights:SIMD3<Double>) {
    let ab=b-a,ac=c-a,ap=point-a,d00=simd_dot(ab,ab),d01=simd_dot(ab,ac),d11=simd_dot(ac,ac),d20=simd_dot(ap,ab),d21=simd_dot(ap,ac),denominator=d00*d11-d01*d01
    if denominator>max(1e-30,1e-12*d00*d11) {
      let v=(d11*d20-d01*d21)/denominator,w=(d00*d21-d01*d20)/denominator,u=1-v-w
      if u>=0,v>=0,w>=0 {return(a*u+b*v+c*w,.init(u,v,w))}
    }
    var best=a,weights=SIMD3<Double>(1,0,0),distance=simd_distance_squared(point,a)
    let endpoints=[(a,b,SIMD3<Double>(1,0,0),SIMD3<Double>(0,1,0)),(b,c,SIMD3<Double>(0,1,0),SIMD3<Double>(0,0,1)),(c,a,SIMD3<Double>(0,0,1),SIMD3<Double>(1,0,0))]
    for (start,end,wa,wb) in endpoints {
      let axis=end-start,length=simd_length_squared(axis),t=length>1e-24 ? min(1,max(0,simd_dot(point-start,axis)/length)):0
      let candidate=start+axis*t,d=simd_distance_squared(point,candidate)
      if d<distance {best=candidate;weights=wa*(1-t)+wb*t;distance=d}
    }
    return(best,weights)
  }
}
