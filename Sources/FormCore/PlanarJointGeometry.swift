import Foundation
import FormCADModel
import CFormClipper

/// Bounded analytic intersections with actual posed, independently stocked rigid material.
/// Curved/recessed receiving material is explicitly unsupported rather than silently filled.
enum PlanarJointGeometry {
  static func add(_ a:Vector3,_ b:Vector3)->Vector3 {.init(a.x+b.x,a.y+b.y,a.z+b.z)}
  static func sub(_ a:Vector3,_ b:Vector3)->Vector3 {.init(a.x-b.x,a.y-b.y,a.z-b.z)}
  static func mul(_ a:Vector3,_ b:Double)->Vector3 {.init(a.x*b,a.y*b,a.z*b)}
  static func dot(_ a:Vector3,_ b:Vector3)->Double {a.x*b.x+a.y*b.y+a.z*b.z}
  static func cross(_ a:Vector3,_ b:Vector3)->Vector3 {.init(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)}
  static func length(_ a:Vector3)->Double {sqrt(dot(a,a))}
  static func unit(_ a:Vector3)throws->Vector3 {
    let n=length(a);guard n.isFinite,n>1e-9 else{throw FormError.invalid("A joint direction must be finite and nonzero.")};return mul(a,1/n)
  }
  static func vector(_ matrix:[Double],_ p:Vector3)->Vector3 {.init(matrix[0]*p.x+matrix[1]*p.y+matrix[2]*p.z,matrix[4]*p.x+matrix[5]*p.y+matrix[6]*p.z,matrix[8]*p.x+matrix[9]*p.y+matrix[10]*p.z)}
  static func inverseVector(_ m:[Double],_ p:Vector3)->Vector3 {.init(m[0]*p.x+m[4]*p.y+m[8]*p.z,m[1]*p.x+m[5]*p.y+m[9]*p.z,m[2]*p.x+m[6]*p.y+m[10]*p.z)}
  static func inversePoint(_ m:[Double],_ p:Vector3)->Vector3 {inverseVector(m,sub(p,.init(m[3],m[7],m[11])))}
  static func area(_ p:[Point2])->Double {guard p.count>=3 else{return 0};return abs(p.indices.reduce(0){sum,i in let q=p[(i+1)%p.count];return sum+p[i].x*q.y-q.x*p[i].y})/2}
  static func intersectionArea(_ first:[[Point2]],_ second:[[Point2]])throws->Double {
    let a=first.flatMap{$0.flatMap{[$0.x,$0.y]}},b=second.flatMap{$0.flatMap{[$0.x,$0.y]}},an=first.map{Int32($0.count)},bn=second.map{Int32($0.count)}
    let value=a.withUnsafeBufferPointer {ap in b.withUnsafeBufferPointer {bp in an.withUnsafeBufferPointer {ac in bn.withUnsafeBufferPointer {bc in
      fc_intersection_area(ap.baseAddress,ac.baseAddress,Int32(an.count),bp.baseAddress,bc.baseAddress,Int32(bn.count))
    }}}}
    guard value.isFinite else{throw FormError.invalid("Joint region clipping failed at the physical contour precision.")};return value
  }
  static func normalizedContours(_ panel:PaperPanel)->[[Point2]] {
    func signed(_ p:[Point2])->Double {p.indices.reduce(0){s,i in let q=p[(i+1)%p.count];return s+p[i].x*q.y-q.x*p[i].y}}
    let outer=signed(panel.polygon)>=0 ? panel.polygon:Array(panel.polygon.reversed())
    return [outer]+(panel.cutouts ?? []).map{signed($0.polygon)<=0 ? $0.polygon:Array($0.polygon.reversed())}
  }
  struct Prism {
    var panel:PaperPanel,matrix:[Double],stock:PaperStock
    var rigidReceivingSupported:Bool
    var half:Double {stock.resolvedThicknessMM/2}
    func point(_ source:Point2,z:Double=0)->Vector3 {PaperRigidMatrix.point(matrix,.init(source.x,-source.y,z))}
    func intervals(origin:Vector3,direction:Vector3,range:ClosedRange<Double>)->[ClosedRange<Double>] {
      let o=PlanarJointGeometry.inversePoint(matrix,origin),d=PlanarJointGeometry.inverseVector(matrix,direction)
      var low=range.lowerBound,high=range.upperBound
      if abs(d.z)<1e-12 {if abs(o.z)>half+1e-9{return []}}
      else {let a=(-half-o.z)/d.z,b=(half-o.z)/d.z;low=max(low,min(a,b));high=min(high,max(a,b))}
      guard high>low+1e-9 else{return []}
      let p=Point2(o.x,-o.y),v=Point2(d.x,-d.y)
      var events=[low,high]
      let squared=v.x*v.x+v.y*v.y
      if squared>1e-20 {
        for polygon in [panel.polygon]+(panel.cutouts ?? []).map(\.polygon) {for i in polygon.indices {
          let a=polygon[i],b=polygon[(i+1)%polygon.count],ex=b.x-a.x,ey=b.y-a.y,dx=a.x-p.x,dy=a.y-p.y
          let denominator=v.x*ey-v.y*ex
          if abs(denominator)>1e-12 {
            let t=(dx*ey-dy*ex)/denominator,u=(dx*v.y-dy*v.x)/denominator
            if u>=(-1e-9),u<=1+1e-9,t>low,t<high {events.append(t)}
          }else if abs(dx*v.y-dy*v.x)<1e-9 {
            for q in [a,b] {let t=((q.x-p.x)*v.x+(q.y-p.y)*v.y)/squared;if t>low,t<high{events.append(t)}}
          }
        }}
      }
      events.sort();var unique=[Double]()
      for t in events where unique.last.map({abs($0-t)>1e-8}) ?? true {unique.append(t)}
      guard unique.count>=2 else{return []}
      var intervals=[ClosedRange<Double>]()
      for i in 0..<(unique.count-1) {
        let a=unique[i],b=unique[i+1],t=(a+b)/2
        if panel.containsMaterial(.init(p.x+v.x*t,p.y+v.y*t)) {
          if let prior=intervals.last,abs(prior.upperBound-a)<1e-8 {intervals[intervals.count-1]=prior.lowerBound...b}
          else{intervals.append(a...b)}
        }
      }
      return intervals
    }
    func contains(_ world:Vector3,margin:Double=0)->Bool {
      let local=PlanarJointGeometry.inversePoint(matrix,world),p=Point2(local.x,-local.y)
      return abs(local.z)<=half-margin+1e-8 && panel.containsMaterial(p) && PlanarJointGeometry.boundaryDistance(p,panel:panel)>=margin-1e-8
    }
    var worldBounds:(Vector3,Vector3) {
      var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
      for p in panel.polygon {for z in [-half,half] {let q=point(p,z:z);low = .init(min(low.x,q.x),min(low.y,q.y),min(low.z,q.z));high = .init(max(high.x,q.x),max(high.y,q.y),max(high.z,q.z))}}
      return (low,high)
    }
  }
  static func boundaryDistance(_ p:Point2,panel:PaperPanel)->Double {
    var minimum=Double.infinity
    for polygon in [panel.polygon]+(panel.cutouts ?? []).map(\.polygon) {for i in polygon.indices {
      let a=polygon[i],b=polygon[(i+1)%polygon.count],dx=b.x-a.x,dy=b.y-a.y,den=dx*dx+dy*dy
      let t=den>0 ? min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/den)):0
      minimum=min(minimum,hypot(p.x-a.x-t*dx,p.y-a.y-t*dy))
    }};return minimum
  }
  static func regions(_ source:PlanarJointSurfaceRegion,prism:Prism,values:[String:Double])throws->(flat:[Point2],world:[Vector3]) {
    let points=try source.polygon.map{try Point2(FormCADModel.CADExpression.evaluate($0.x.expression,variables:values),FormCADModel.CADExpression.evaluate($0.y.expression,variables:values))}
    guard (3...16).contains(points.count),PlanarConstructionDefinition.validJointRegion(points) else{throw FormError.invalid("A bonded or taped region needs 3–16 nondegenerate physical points.")}
    if let edge=source.edgeIndex {
      guard prism.panel.polygon.indices.contains(edge) else{throw FormError.invalid("A joint region references a missing cut edge.")}
      let a=prism.panel.polygon[edge],b=prism.panel.polygon[(edge+1)%prism.panel.polygon.count],n=hypot(b.x-a.x,b.y-a.y)
      guard points.allSatisfy({$0.x>=0 && $0.x<=n && $0.y>=0 && $0.y<=prism.stock.resolvedThicknessMM}) else{throw FormError.invalid("Cut-edge bond coordinates must fit edge length and real board caliper.")}
      return (points,points.map{prism.point(.init(a.x+(b.x-a.x)*$0.x/n,a.y+(b.y-a.y)*$0.x/n),z:$0.y-prism.half)})
    }
    let kept=try intersectionArea([points],normalizedContours(prism.panel))
    guard abs(kept-area(points))<=max(0.01,area(points)*1e-5) else{throw FormError.invalid("A joint region must remain within its target panel material, excluding holes.")}
    return (points,points.map{prism.point($0,z:source.side == .outside ? prism.half:-prism.half)})
  }
  static func toolObstructed(origin:Vector3,axis:Vector3,across:Vector3,depth:Double,halfWidth:Double,halfHeight:Double,prisms:[Prism],ignoring:Set<String>)->String? {
    let normal=cross(axis,across),end=add(origin,mul(axis,depth));var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
    for center in [origin,end] {for a in [-halfWidth,halfWidth] {for b in [-halfHeight,halfHeight] {
      let p=add(center,add(mul(across,a),mul(normal,b)));low = .init(min(low.x,p.x),min(low.y,p.y),min(low.z,p.z));high = .init(max(high.x,p.x),max(high.y,p.y),max(high.z,p.z))
    }}}
    for prism in prisms where !ignoring.contains(prism.panel.id) {
      let (a,b)=prism.worldBounds
      if min(high.x,b.x)>max(low.x,a.x)+1e-6,min(high.y,b.y)>max(low.y,a.y)+1e-6,min(high.z,b.z)>max(low.z,a.z)+1e-6 {return prism.panel.id}
    }
    return nil
  }
}
