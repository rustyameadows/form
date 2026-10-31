import Foundation
import FormCore

/// Table-only framing for floating controls. Rectangles use top-left viewport
/// points; persisted camera poses and the shared Core framing API stay intact.
enum TableViewportFraming {
  struct Result {
    let camera:CameraState
    let visibleRect:CGRect
    let subjectCenter:Vector3
  }
  private struct Point {let x:Double,y:Double,z:Double}
  private struct Limits {let left:Double,right:Double,bottom:Double,top:Double}
  private struct Interval {var low:Double;var high:Double}

  /// Every maximal useful rectangle has horizontal edges at an obstacle edge
  /// or viewport edge. For each horizontal interval, merge its blocked vertical
  /// intervals instead of reserving entire strips beside short floating cards.
  static func unobstructedRects(viewport:CGSize,occlusions:[CGRect],padding:CGFloat=12)->[CGRect] {
    guard viewport.width.isFinite,viewport.height.isFinite,viewport.width>2*padding,viewport.height>2*padding else{return []}
    let bounds=CGRect(origin:.zero,size:viewport).insetBy(dx:padding,dy:padding)
    var blocked=occlusions.compactMap { raw -> CGRect? in
      guard [raw.minX,raw.minY,raw.width,raw.height].allSatisfy(\.isFinite),raw.width>0,raw.height>0 else{return nil}
      let rect=raw.insetBy(dx:-8,dy:-8).intersection(bounds)
      return rect.isNull || rect.isEmpty ? nil:rect
    }
    // UI supplies a handful of cards. A malformed larger list fails
    // conservatively instead of making an unbounded layout search.
    if blocked.count>32 {blocked=[blocked.reduce(CGRect.null){$0.union($1)}]}
    let xs=Array(Set([bounds.minX,bounds.maxX]+blocked.flatMap{[$0.minX,$0.maxX]})).sorted()
    var result=[CGRect]()
    for left in xs.indices.dropLast() {for right in (left+1)..<xs.count {
      let x0=xs[left],x1=xs[right]
      guard x1-x0>1 else{continue}
      let spans=blocked.filter{$0.minX<x1 && $0.maxX>x0}.map{($0.minY,$0.maxY)}.sorted{$0.0<$1.0}
      var y=bounds.minY
      for span in spans {
        if span.0-y>1 {result.append(.init(x:x0,y:y,width:x1-x0,height:span.0-y))}
        y=max(y,span.1)
      }
      if bounds.maxY-y>1 {result.append(.init(x:x0,y:y,width:x1-x0,height:bounds.maxY-y))}
    }}
    return result
  }

  static func fitted(_ camera:CameraState,points:[Vector3],viewport:CGSize,occlusions:[CGRect],
    fieldOfView:Double=39,margin:Double=1.2)->Result? {
    let points=points.filter{[$0.x,$0.y,$0.z].allSatisfy(\.isFinite)}
    guard let first=points.first else{return nil}
    let rectangles=unobstructedRects(viewport:viewport,occlusions:occlusions)
    guard !rectangles.isEmpty else{return nil}
    var low=first,high=first
    for p in points.dropFirst(){low = .init(min(low.x,p.x),min(low.y,p.y),min(low.z,p.z));high = .init(max(high.x,p.x),max(high.y,p.y),max(high.z,p.z))}
    let center=Vector3((low.x+high.x)/2,(low.y+high.y)/2,(low.z+high.z)/2),basis=CameraNavigation.basis(camera)
    func dot(_ p:Vector3,_ a:Vector3)->Double{p.x*a.x+p.y*a.y+p.z*a.z}
    let local=points.map { p -> Point in
      let d=Vector3(p.x-center.x,p.y-center.y,p.z-center.z)
      return .init(x:dot(d,basis.right),y:dot(d,basis.up),z:dot(d,basis.outward))
    }
    let aspect=Double(viewport.width/viewport.height)
    let orthographic=camera.projection=="orthographic"
    let tangent=tan((fieldOfView.isFinite ? min(150,max(5,fieldOfView)):39)*Double.pi/360)
    let vertical=orthographic ? CameraFraming.orthographicFactor:tangent,horizontal=vertical*aspect
    let depthFloor=max(CameraNavigation.minimumDistance,(local.map(\.z).max() ?? 0)+0.1)
    let padding=(margin.isFinite ? max(1,margin):1.2)*1.002
    func limits(_ rect:CGRect)->Limits {
      let inner=rect.insetBy(dx:rect.width*(1-1/padding)/2,dy:rect.height*(1-1/padding)/2)
      return .init(left:2*inner.minX/viewport.width-1,right:2*inner.maxX/viewport.width-1,
        bottom:1-2*inner.maxY/viewport.height,top:1-2*inner.minY/viewport.height)
    }
    func intervals(_ distance:Double,_ bounds:Limits)->(Interval,Interval)? {
      var x=Interval(low:-Double.infinity,high:Double.infinity),y=x
      for p in local {
        let depth=orthographic ? distance:distance-p.z
        guard depth>0 else{return nil}
        x.low=max(x.low,p.x-bounds.right*horizontal*depth)
        x.high=min(x.high,p.x-bounds.left*horizontal*depth)
        y.low=max(y.low,p.y-bounds.top*vertical*depth)
        y.high=min(y.high,p.y-bounds.bottom*vertical*depth)
      }
      return x.low<=x.high+1e-12 && y.low<=y.high+1e-12 ? (x,y):nil
    }
    var best:(rect:CGRect,bounds:Limits,distance:Double)?
    let initial=CameraFraming.fitted(camera,points:points,aspect:aspect,fieldOfView:fieldOfView,margin:margin).distance
    for rect in rectangles {
      let bounds=limits(rect)
      var low=depthFloor,high=max(depthFloor,initial)
      for _ in 0..<64 {
        if intervals(high,bounds) != nil {break}
        high *= 2
      }
      guard high.isFinite,intervals(high,bounds) != nil else{continue}
      for _ in 0..<36 {let mid=(low+high)/2;if intervals(mid,bounds) != nil {high=mid}else{low=mid}}
      // Pick the region that permits the greatest subject scale. Area breaks
      // equal-distance ties, so a thin subject can use a wide short opening.
      if best == nil || high<best!.distance-1e-10 || abs(high-best!.distance)<=1e-10 && rect.width*rect.height>best!.rect.width*best!.rect.height {
        best=(rect,bounds,high)
      }
    }
    guard let best,let ranges=intervals(best.distance,best.bounds) else{return nil}
    func centered(_ interval:Interval,horizontalAxis:Bool,desired:Double)->Double {
      var low=interval.low,high=interval.high
      let scale=horizontalAxis ? horizontal:vertical
      for _ in 0..<40 {
        let offset=(low+high)/2
        var minimum=Double.infinity,maximum = -Double.infinity
        for p in local {
          let q=((horizontalAxis ? p.x:p.y)-offset)/(scale*(orthographic ? best.distance:best.distance-p.z))
          minimum=min(minimum,q);maximum=max(maximum,q)
        }
        if (minimum+maximum)/2>desired {low=offset}else{high=offset}
      }
      return (low+high)/2
    }
    let x=centered(ranges.0,horizontalAxis:true,desired:(best.bounds.left+best.bounds.right)/2)
    let y=centered(ranges.1,horizontalAxis:false,desired:(best.bounds.bottom+best.bounds.top)/2)
    var result=camera
    result.viewportAspect=aspect;result.distance=best.distance
    // This is an ordinary persisted camera pan, not an unsaved lens shift.
    // Subsequent orbit uses this optical target, matching manual pan semantics.
    result.target = .init(center.x+basis.right.x*x+basis.up.x*y,
      center.y+basis.right.y*x+basis.up.y*y,center.z+basis.right.z*x+basis.up.z*y)
    return .init(camera:result,visibleRect:best.rect,subjectCenter:center)
  }
}
