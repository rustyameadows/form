import Foundation
import simd

public struct ClothBounds:Codable,Equatable,Sendable {
  public var minimumMm:Vector3
  public var maximumMm:Vector3
  public var centerMm:Vector3 {.init((minimumMm.x+maximumMm.x)/2,(minimumMm.y+maximumMm.y)/2,(minimumMm.z+maximumMm.z)/2)}
  public init(positionsMm:[Vector3])throws {
    guard let first=positionsMm.first,positionsMm.count<=ClothMesh.maximumVertices,positionsMm.allSatisfy({ClothMath.finite($0) && ClothMath.maximum($0)<=10_000_000}) else {throw FormError.invalid("Cloth bounds need a bounded finite surface frame.")}
    var minimum=ClothMath.vector(first),maximum=minimum
    for position in positionsMm {let p=ClothMath.vector(position);minimum=simd_min(minimum,p);maximum=simd_max(maximum,p)}
    minimumMm=ClothMath.point(minimum);maximumMm=ClothMath.point(maximum)
  }
}
/// Stable rest-topology binding, distinct for the two sides of a seamed panel.
/// Barycentric weights follow the same material point through simulated motion.
public struct ClothSurfaceAnchor:Codable,Equatable,Sendable {
  public var triangle:Int
  public var weights:Vector3
  public var normalOffsetMm:Double
  public init(triangle:Int,weights:Vector3,normalOffsetMm:Double = 0) {self.triangle=triangle;self.weights=weights;self.normalOffsetMm=normalOffsetMm}
  public func placement(mesh:ClothMesh,frame:ClothFrame)throws -> ClothSurfacePlacement {
    guard mesh.triangles.indices.contains(triangle),frame.positionsMm.count==mesh.restPositionsMm.count,frame.normals.count==mesh.restPositionsMm.count,
      mesh.uv.count==mesh.restPositionsMm.count,ClothMath.finite(weights),min(weights.x,weights.y,weights.z)>=0,
      abs(weights.x+weights.y+weights.z-1)<1e-8,normalOffsetMm.isFinite,abs(normalOffsetMm)<=1000 else {throw FormError.invalid("Cloth attachment needs a valid triangle, material UVs and normalized nonnegative barycentric weights.")}
    let t=mesh.triangles[triangle],indices=[t.a,t.b,t.c]
    guard indices.allSatisfy({frame.positionsMm.indices.contains($0) && ClothMath.finite(frame.positionsMm[$0]) && ClothMath.maximum(frame.positionsMm[$0])<=10_000_000 && ClothMath.finite(frame.normals[$0]) && ClothMath.maximum(frame.normals[$0])<=1.001}) else {throw FormError.invalid("Cloth attachment frame contains invalid positions or normals.")}
    let a=ClothMath.vector(frame.positionsMm[t.a]),b=ClothMath.vector(frame.positionsMm[t.b]),c=ClothMath.vector(frame.positionsMm[t.c]),w=ClothMath.vector(weights)
    let n=ClothMath.vector(frame.normals[t.a])*w.x+ClothMath.vector(frame.normals[t.b])*w.y+ClothMath.vector(frame.normals[t.c])*w.z
    let u=mesh.uv[t.a],v=mesh.uv[t.b],z=mesh.uv[t.c],du1=v.x-u.x,dv1=v.y-u.y,du2=z.x-u.x,dv2=z.y-u.y,determinant=du1*dv2-du2*dv1
    guard abs(determinant)>1e-12,simd_length_squared(n)>1e-16 else {throw FormError.invalid("This cloth attachment has collapsed material coordinates or surface normal.")}
    let normal=simd_normalize(n),du=((b-a)*dv2-(c-a)*dv1)/determinant,tangent=du-normal*simd_dot(du,normal)
    guard simd_length_squared(tangent)>1e-16 else {throw FormError.invalid("The current cloth surface has collapsed at this attachment.")}
    return .init(positionMm:ClothMath.point(a*w.x+b*w.y+c*w.z+normal*normalOffsetMm),normal:ClothMath.point(normal),materialTangent:ClothMath.point(simd_normalize(tangent)))
  }
}
public struct ClothSurfacePlacement:Codable,Equatable,Sendable {
  public var positionMm:Vector3
  public var normal:Vector3
  public var materialTangent:Vector3
}


extension ClothMesh {
  public func panelID(forTriangle index:Int)->Int {
    guard triangles.indices.contains(index),let panelIDs,panelIDs.indices.contains(triangles[index].a) else {return 0}
    return panelIDs[triangles[index].a]
  }
  public func materialPoint(_ anchor:ClothSurfaceAnchor)throws -> Point2 {
    guard triangles.indices.contains(anchor.triangle),uv.count==restPositionsMm.count else {throw FormError.invalid("Cloth attachment has no valid material triangle.")}
    let t=triangles[anchor.triangle],w=anchor.weights
    return .init(uv[t.a].x*w.x+uv[t.b].x*w.y+uv[t.c].x*w.z,uv[t.a].y*w.x+uv[t.b].y*w.y+uv[t.c].y*w.z)
  }
  public func anchor(at point:Point2,panel:Int = 0,normalOffsetMm:Double = 0)throws -> ClothSurfaceAnchor {
    guard point.x.isFinite,point.y.isFinite,uv.count==restPositionsMm.count,(0...63).contains(panel) else {throw FormError.invalid("Choose finite material coordinates and an existing cloth panel.")}
    for (index,t) in triangles.enumerated() where panelID(forTriangle:index)==panel {
      let a=uv[t.a],b=uv[t.b],c=uv[t.c],du1=b.x-a.x,dv1=b.y-a.y,du2=c.x-a.x,dv2=c.y-a.y,det=du1*dv2-du2*dv1
      guard abs(det)>1e-12 else {continue}
      let x=point.x-a.x,y=point.y-a.y,v=(x*dv2-y*du2)/det,w=(du1*y-dv1*x)/det,u=1-v-w
      if min(u,v,w)>=(-1e-9) {
        let sum=max(0,u)+max(0,v)+max(0,w)
        return .init(triangle:index,weights:.init(max(0,u)/sum,max(0,v)/sum,max(0,w)/sum),normalOffsetMm:normalOffsetMm)
      }
    }
    throw FormError.invalid("This material point is outside the chosen cloth panel.")
  }
}

extension ClothMesh {
  public func closestAnchor(to pointMm:Vector3,frame:ClothFrame,panel:Int = 0,normalOffsetMm:Double = 0)throws -> ClothSurfaceAnchor {
    guard ClothMath.finite(pointMm),ClothMath.maximum(pointMm)<=10_000_000,frame.positionsMm.count==restPositionsMm.count else {throw FormError.invalid("Choose a finite point on the current cloth frame.")}
    let point=ClothMath.vector(pointMm)
    var found:ClothSurfaceAnchor?,distance=Double.infinity
    for (index,t) in triangles.enumerated() where panelID(forTriangle:index)==panel {
      let closest=ClothContactGeometry.closestPoint(point,a:ClothMath.vector(frame.positionsMm[t.a]),b:ClothMath.vector(frame.positionsMm[t.b]),c:ClothMath.vector(frame.positionsMm[t.c])),d=simd_distance_squared(point,closest.point)
      if d<distance {distance=d;found = .init(triangle:index,weights:ClothMath.point(closest.weights),normalOffsetMm:normalOffsetMm)}
    }
    guard let found else {throw FormError.invalid("The chosen cloth panel has no surface triangles.")};return found
  }
}
