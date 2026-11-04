import Foundation

/// Shared contour/material-distance kernel for sheet, roll and sewing layouts.
/// Bounds are only a broad-phase rejection; holes and concave reliefs remain
/// actual material geometry during clearance and overlap checks.
public enum MaterialContourGeometry {
  public static let epsilon=1e-7
  public static func area(_ points:[Point2])->Double {
    guard points.count>=3 else{return 0}
    return abs(points.indices.reduce(0){$0+points[$1].x*points[($1+1)%points.count].y-points[$1].y*points[($1+1)%points.count].x})/2
  }
  public static func materialArea(_ contours:[[Point2]])->Double {
    guard let first=contours.first else{return 0};return max(0,area(first)-contours.dropFirst().reduce(0){$0+area($1)})
  }
  public static func bounds(_ points:[Point2])->Rect2 {
    guard let first=points.first else{return .init(0,0,0,0)}
    let minX=points.reduce(first.x){min($0,$1.x)},minY=points.reduce(first.y){min($0,$1.y)}
    return .init(minX,minY,points.reduce(first.x){max($0,$1.x)}-minX,points.reduce(first.y){max($0,$1.y)}-minY)
  }
  public static func containsMaterial(_ point:Point2,contours:[[Point2]])->Bool {
    guard let first=contours.first,SewingCurves.contains(point,ring:first) else{return false}
    return !contours.dropFirst().contains{SewingCurves.contains(point,ring:$0)}
  }
  private static func subtract(_ a:Point2,_ b:Point2)->Point2 {.init(a.x-b.x,a.y-b.y)}
  private static func cross(_ a:Point2,_ b:Point2)->Double {a.x*b.y-a.y*b.x}
  private static func dot(_ a:Point2,_ b:Point2)->Double {a.x*b.x+a.y*b.y}
  private static func distance(_ p:Point2,_ a:Point2,_ b:Point2)->Double {
    let d=subtract(b,a),length=dot(d,d);if length<=1e-20{return hypot(p.x-a.x,p.y-a.y)}
    let t=max(0,min(1,dot(subtract(p,a),d)/length));return hypot(p.x-a.x-t*d.x,p.y-a.y-t*d.y)
  }
  private static func intersects(_ a:Point2,_ b:Point2,_ c:Point2,_ d:Point2)->Bool {
    let ab=subtract(b,a),cd=subtract(d,c),u=cross(ab,subtract(c,a)),v=cross(ab,subtract(d,a)),w=cross(cd,subtract(a,c)),z=cross(cd,subtract(b,c))
    if ((u>epsilon && v < -epsilon)||(u < -epsilon && v>epsilon)) && ((w>epsilon && z < -epsilon)||(w < -epsilon && z>epsilon)){return true}
    return abs(u)<=epsilon && distance(c,a,b)<=epsilon || abs(v)<=epsilon && distance(d,a,b)<=epsilon || abs(w)<=epsilon && distance(a,c,d)<=epsilon || abs(z)<=epsilon && distance(b,c,d)<=epsilon
  }
  public static func separation(_ a:[[Point2]],_ b:[[Point2]],required:Double,comparisons:inout Int,maximumComparisons:Int=4_000_000)throws->(overlaps:Bool,distance:Double) {
    guard let outerA=a.first,let outerB=b.first,!outerA.isEmpty,!outerB.isEmpty else{throw FormError.invalid("Material contour separation needs two nonempty physical outlines.")}
    let aa=bounds(outerA),bb=bounds(outerB),dx=max(0,max(aa.x-bb.maxX,bb.x-aa.maxX)),dy=max(0,max(aa.y-bb.maxY,bb.y-aa.maxY)),broad=hypot(dx,dy)
    if broad+epsilon>=required{return(false,broad)}
    var closest=Double.infinity
    for ap in a {for bp in b {for i in ap.indices {for j in bp.indices {
      comparisons+=1;guard comparisons<=maximumComparisons else{throw FormError.invalid("Material layout exceeded its bounded exact contour-check budget; split the layout scope.")}
      let p=ap[i],q=ap[(i+1)%ap.count],r=bp[j],s=bp[(j+1)%bp.count]
      if intersects(p,q,r,s){return(true,0)}
      closest=min(closest,distance(p,r,s),distance(q,r,s),distance(r,p,q),distance(s,p,q))
    }}}}
    if containsMaterial(outerA[0],contours:b)||containsMaterial(outerB[0],contours:a){return(true,0)}
    return(false,closest)
  }
}
