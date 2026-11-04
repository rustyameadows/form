import Foundation

/// Physical rectangular wire around a planar installed path. The same corners
/// define display geometry and the full assembly envelope; neither uses an
/// illustrative cylinder or a centerline-only size estimate.
public enum PlanarWireSection {
  public static func corners(pointsMM:[Vector3],widthMM:Double,depthMM:Double)throws->[[Vector3]] {
    guard (3...16).contains(pointsMM.count),pointsMM.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}),
      widthMM.isFinite,depthMM.isFinite,(0.01...4).contains(widthMM),(0.01...4).contains(depthMM) else {
      throw FormError.invalid("Rectangular wire needs a finite bounded path and positive physical section.")
    }
    func add(_ a:Vector3,_ b:Vector3)->Vector3 {.init(a.x+b.x,a.y+b.y,a.z+b.z)}
    func sub(_ a:Vector3,_ b:Vector3)->Vector3 {.init(a.x-b.x,a.y-b.y,a.z-b.z)}
    func mul(_ p:Vector3,_ s:Double)->Vector3 {.init(p.x*s,p.y*s,p.z*s)}
    func dot(_ a:Vector3,_ b:Vector3)->Double {a.x*b.x+a.y*b.y+a.z*b.z}
    func cross(_ a:Vector3,_ b:Vector3)->Vector3 {.init(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)}
    func unit(_ p:Vector3)throws->Vector3 {let length=sqrt(dot(p,p));guard length>1e-8 else{throw FormError.invalid("Rectangular wire contains a collapsed segment.")};return mul(p,1/length)}
    let directions=try zip(pointsMM,pointsMM.dropFirst()).map{pair in try unit(sub(pair.1,pair.0))}
    guard let candidate=zip(directions,directions.dropFirst()).map({pair in cross(pair.0,pair.1)}).first(where:{dot($0,$0)>1e-10}) else {
      throw FormError.invalid("An installed staple must have a crown and non-collinear legs.")
    }
    let normal=try unit(candidate)
    guard pointsMM.allSatisfy({abs(dot(sub($0,pointsMM[0]),normal))<1e-6}) else{throw FormError.invalid("Rectangular staple wire must lie in one installed plane.")}
    let perpendiculars=directions.map{cross(normal,$0)}
    return try pointsMM.indices.map { index in
      let offset:Vector3
      if index==0 {offset=mul(perpendiculars[0],depthMM/2)}
      else if index==pointsMM.count-1 {offset=mul(perpendiculars.last!,depthMM/2)}
      else {
        let miter=try unit(add(perpendiculars[index-1],perpendiculars[index])),denominator=dot(miter,perpendiculars[index])
        guard denominator>=0.25 else{throw FormError.invalid("Rectangular wire bend exceeds its bounded physical miter.")}
        offset=mul(miter,depthMM/2/denominator)
      }
      let width=mul(normal,widthMM/2),point=pointsMM[index]
      return [add(add(point,offset),width),add(sub(point,offset),width),sub(sub(point,offset),width),sub(add(point,offset),width)]
    }
  }
}
