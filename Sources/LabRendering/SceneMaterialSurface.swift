import Foundation
import simd

/// A frozen triangular material surface. Coordinates are physical patch-plane
/// millimeters (x,z); positions and normals describe the selected parent panel.
/// Only derived rendering buffers pass through this mapping.
public struct SceneMaterialSurface: Sendable {
  public struct Limits: Sendable {
    public var toleranceMM=0.005
    public var maximumTriangles=200_000
    public var maximumWork=16_000_000
    public var maximumCurveKeys=2_000_000
    public var maximumKeysPerCurve=4097
    public init() {}
  }
  public struct Budget: Sendable {
    public fileprivate(set) var work=0,triangles=0,curveKeys=0
    public init() {}
  }
  public let revision:String
  public let coordinatesMM:[SIMD2<Double>]
  public let positionsMM:[SIMD3<Double>]
  public let normals:[SIMD3<Double>]
  public let triangles:[SIMD3<UInt32>]
  public let normalOffsetMM:Double
  public let limits:Limits
  private var initialWork=0
  private struct Cell:Hashable,Sendable {var x:Int;var y:Int}
  private var cells:[Cell:[Int]]=[:]
  private let cellSize:Double
  private static func failure(_ message:String)->SceneRendererError {.invalidMesh(message)}
  private static func cross(_ a:SIMD2<Double>,_ b:SIMD2<Double>)->Double {a.x*b.y-a.y*b.x}
  private static func xz(_ p:SIMD3<Double>)->SIMD2<Double> {.init(p.x,p.z)}
  public init(revision:String,coordinatesMM:[SIMD2<Double>],positionsMM:[SIMD3<Double>],normals:[SIMD3<Double>],triangles:[SIMD3<UInt32>],normalOffsetMM:Double,limits:Limits = .init())throws {
    guard !revision.isEmpty,!triangles.isEmpty,triangles.count<=8192,coordinatesMM.count<=4096,
      positionsMM.count==coordinatesMM.count,normals.count==coordinatesMM.count,
      limits.toleranceMM.isFinite,(0.0001...0.1).contains(limits.toleranceMM),
      (1...200_000).contains(limits.maximumTriangles),(1...32_000_000).contains(limits.maximumWork),
      (2...2_000_000).contains(limits.maximumCurveKeys),(5...4097).contains(limits.maximumKeysPerCurve),
      normalOffsetMM.isFinite,abs(normalOffsetMM)<=1000,
      coordinatesMM.allSatisfy({$0.x.isFinite && $0.y.isFinite && simd_reduce_max(simd_abs($0))<=1_000_000}),
      positionsMM.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_reduce_max(simd_abs($0))<=1e12}),
      normals.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_length_squared($0)>1e-12}) else {
      throw Self.failure("The attached rendering surface exceeds its finite material-coordinate or work limits.")
    }
    self.revision=revision;self.coordinatesMM=coordinatesMM;self.positionsMM=positionsMM
    self.normals=normals.map{simd_normalize($0)};self.triangles=triangles;self.normalOffsetMM=normalOffsetMM;self.limits=limits
    let lo=coordinatesMM.reduce(SIMD2<Double>(repeating:.infinity),simd_min),hi=coordinatesMM.reduce(SIMD2<Double>(repeating:-.infinity),simd_max)
    cellSize=max(0.01,simd_reduce_max(hi-lo)/max(1,sqrt(Double(triangles.count))))
    var entries=0
    for (index,t) in triangles.enumerated() {
      guard t.x<coordinatesMM.count,t.y<coordinatesMM.count,t.z<coordinatesMM.count else {throw Self.failure("An attached surface triangle has an invalid vertex.")}
      let a=coordinatesMM[Int(t.x)],b=coordinatesMM[Int(t.y)],c=coordinatesMM[Int(t.z)]
      guard abs(Self.cross(b-a,c-a))>1e-12 else {throw Self.failure("The attached panel has collapsed material coordinates.")}
      let low=simd_min(a,simd_min(b,c)),high=simd_max(a,simd_max(b,c))
      for y in Int(floor(low.y/cellSize))...Int(floor(high.y/cellSize)) {
        for x in Int(floor(low.x/cellSize))...Int(floor(high.x/cellSize)) {
          entries+=1;if entries.isMultiple(of:1024) {try Task.checkCancellation()};guard entries<=min(2_000_000,limits.maximumWork) else {throw Self.failure("The attached material surface exceeds its spatial-index or work budget.")}
          cells[.init(x:x,y:y),default:[]].append(index)
        }
      }
    }
    var work=entries
    for (index,t) in triangles.enumerated() {
      let points=[coordinatesMM[Int(t.x)],coordinatesMM[Int(t.y)],coordinatesMM[Int(t.z)]]
      let low=points.reduce(SIMD2<Double>(repeating:.infinity),simd_min),high=points.reduce(SIMD2<Double>(repeating:-.infinity),simd_max)
      for other in try candidates(low:low,high:high,work:&work) where other>index {
        try charge(&work)
        let vertices=points.map{Vertex(p:.init($0.x,0,$0.y),n:.init(0,1,0),uv:.zero,uv1:.zero,color:.one,tangent:.init(1,0,0,1))}
        let overlap=clipped(vertices,support:other)
        var area=0.0
        if overlap.count>=3 {for i in 1..<overlap.count-1 {area+=simd_length(simd_cross(overlap[i].p-overlap[0].p,overlap[i+1].p-overlap[0].p))/2}}
        guard area<=1e-9 else {throw Self.failure("The selected parent panel has overlapping material triangles; attached rendering needs an unambiguous material chart.")}
        for vertex in overlap {
          let a=try sample(Self.xz(vertex.p),triangle:index),b=try sample(Self.xz(vertex.p),triangle:other)
          guard simd_distance(a.p,b.p)<=1e-7,simd_distance(a.normal,b.normal)<=1e-7 else {throw Self.failure("The attached material chart has a discontinuous seam. Keep the decoration within one continuous panel.")}
        }
      }
    }
    initialWork=work
  }
  public func makeBudget()->Budget {var result=Budget();result.work=initialWork;return result}
  private func charge(_ work:inout Int,_ count:Int=1)throws {
    let before=work;work+=count
    guard work<=limits.maximumWork else {throw Self.failure("Attached surface mapping exhausted its work budget.")}
    if before/1024 != work/1024 {try Task.checkCancellation()}
  }
  private func candidates(low:SIMD2<Double>,high:SIMD2<Double>,work:inout Int)throws->[Int] {
    var result=Set<Int>()
    let x0=Int(floor(low.x/cellSize)),x1=Int(floor(high.x/cellSize)),y0=Int(floor(low.y/cellSize)),y1=Int(floor(high.y/cellSize))
    guard x1-x0<=4096,y1-y0<=4096 else {throw Self.failure("An attached object extends beyond the bounded material surface.")}
    for y in y0...y1 {for x in x0...x1 {
      try charge(&work)
      for index in cells[.init(x:x,y:y)] ?? [] {try charge(&work);result.insert(index)}
    }}
    return result.sorted()
  }
  private func weights(_ p:SIMD2<Double>,triangle:Int)->SIMD3<Double> {
    let t=triangles[triangle],a=coordinatesMM[Int(t.x)],b=coordinatesMM[Int(t.y)],c=coordinatesMM[Int(t.z)],d=Self.cross(b-a,c-a)
    let v=Self.cross(p-a,c-a)/d,w=Self.cross(b-a,p-a)/d;return .init(1-v-w,v,w)
  }
  private func owner(_ p:SIMD2<Double>,work:inout Int)throws->Int {
    let list=cells[.init(x:Int(floor(p.x/cellSize)),y:Int(floor(p.y/cellSize)))] ?? []
    for index in list {try charge(&work);if simd_reduce_min(weights(p,triangle:index)) >= -1e-8 {return index}}
    throw Self.failure("The attached object leaves its original material panel or enters a source hole.")
  }
  private struct Sample {
    var p:SIMD3<Double>,rawNormal:SIMD3<Double>,px:SIMD3<Double>,pz:SIMD3<Double>,nx:SIMD3<Double>,nz:SIMD3<Double>
    var normal:SIMD3<Double> {simd_normalize(rawNormal)}
    func position(_ height:Double)->SIMD3<Double> {p+normal*height}
    func jacobian(_ height:Double)throws->simd_double3x3 {
      let n=normal,r=simd_length(rawNormal)
      guard r>1e-6 else {throw SceneMaterialSurface.failure("The attached surface normal collapses across this panel.")}
      let dx=(nx-n*simd_dot(n,nx))/r,dz=(nz-n*simd_dot(n,nz))/r
      let result=simd_double3x3(columns:(px+dx*height,n,pz+dz*height))
      guard simd_determinant(result)>1e-10 else {throw SceneMaterialSurface.failure("The attached caliper folds through the parent surface. Reduce the offset or caliper.")}
      return result
    }
  }
  private func sample(_ p:SIMD2<Double>,triangle:Int)throws->Sample {
    let t=triangles[triangle],ids=[Int(t.x),Int(t.y),Int(t.z)],a=coordinatesMM[ids[0]],b=coordinatesMM[ids[1]],c=coordinatesMM[ids[2]],d=Self.cross(b-a,c-a),w=weights(p,triangle:triangle)
    let p0=positionsMM[ids[0]],p1=positionsMM[ids[1]],p2=positionsMM[ids[2]],n0=normals[ids[0]],n1=normals[ids[1]],n2=normals[ids[2]]
    let raw=n0*w.x+n1*w.y+n2*w.z
    guard simd_length_squared(raw)>1e-12 else {throw Self.failure("The attached surface normal collapses across this panel.")}
    return .init(p:p0*w.x+p1*w.y+p2*w.z,rawNormal:raw,
      px:((p1-p0)*(c.y-a.y)-(p2-p0)*(b.y-a.y))/d,pz:((p2-p0)*(b.x-a.x)-(p1-p0)*(c.x-a.x))/d,
      nx:((n1-n0)*(c.y-a.y)-(n2-n0)*(b.y-a.y))/d,nz:((n2-n0)*(b.x-a.x)-(n1-n0)*(c.x-a.x))/d)
  }
  public func position(_ local:SIMD3<Double>)throws->SIMD3<Double> {
    var work=0;return try position(local,work:&work)
  }
  private func position(_ local:SIMD3<Double>,work:inout Int)throws->SIMD3<Double> {
    let value=try sample(Self.xz(local),triangle:owner(Self.xz(local),work:&work))
    _=try value.jacobian(normalOffsetMM+local.y)
    return value.position(normalOffsetMM+local.y)
  }
  private struct Cubic {
    var p:[SIMD3<Double>]
    init(_ values:[SIMD3<Double>]) {p=values}
    init(keys:[SIMD3<Double>],span:Int) {
      let a=keys[max(0,span-1)],b=keys[span],c=keys[span+1],d=keys[min(keys.count-1,span+2)]
      p=[b,b+(c-a)/6,c-(d-b)/6,c]
    }
    func split(_ t:Double)->(Self,Self) {
      let a=p[0]+(p[1]-p[0])*t,b=p[1]+(p[2]-p[1])*t,c=p[2]+(p[3]-p[2])*t,d=a+(b-a)*t,e=b+(c-b)*t,f=d+(e-d)*t
      return (.init([p[0],a,d,f]),.init([f,e,c,p[3]]))
    }
    func at(_ t:Double)->SIMD3<Double> {split(t).0.p[3]}
    func restricted(_ lo:Double,_ hi:Double)->Self {
      if lo==0 {return split(hi).0}
      return split(lo).1.split((hi-lo)/(1-lo)).0
    }
  }
  private static func roots(_ f:[Double])->[Double] {
    let a = -f[0]+3*f[1]-3*f[2]+f[3],b=3*f[0]-6*f[1]+3*f[2],c = -3*f[0]+3*f[1],d=f[0]
    func value(_ t:Double)->Double {((a*t+b)*t+c)*t+d}
    let epsilon=max(1e-12,f.map{abs($0)}.max()!*1e-13)
    if f.allSatisfy({abs($0)<=epsilon}) {return []}
    var divisions=[0.0,1.0]
    if abs(a)<=epsilon {if abs(b)>epsilon {let t = -c/(2*b);if t>0,t<1 {divisions.append(t)}}}
    else {
      let discriminant=4*b*b-12*a*c
      if discriminant>=0 {for t in [(-2*b-sqrt(discriminant))/(6*a),(-2*b+sqrt(discriminant))/(6*a)] where t>0 && t<1 {divisions.append(t)}}
    }
    divisions.sort();var result=divisions.filter{abs(value($0))<=epsilon}
    for i in 0..<divisions.count-1 {
      var lo=divisions[i],hi=divisions[i+1];let sign=value(lo)>0
      guard sign != (value(hi)>0),abs(value(lo))>epsilon,abs(value(hi))>epsilon else {continue}
      for _ in 0..<56 {let mid=(lo+hi)/2;if (value(mid)>0)==sign {lo=mid}else{hi=mid}}
      result.append((lo+hi)/2)
    }
    return result
  }
  private func boundaries(_ curve:Cubic,work:inout Int)throws->[Double] {
    let chart=curve.p.map(Self.xz),low=chart.reduce(SIMD2<Double>(repeating:.infinity),simd_min),high=chart.reduce(SIMD2<Double>(repeating:-.infinity),simd_max)
    // A cubic lies inside its Bézier control hull. Dense stitch profiles often
    // have many short spans contained in one parent triangle; certifying that
    // convex hull avoids searching every nearby triangle edge for roots.
    let containing=try owner(Self.xz(curve.at(0.5)),work:&work)
    try charge(&work,4)
    if chart.allSatisfy({simd_reduce_min(weights($0,triangle:containing))>=0}) {return [0,1]}
    var result=[0.0,1.0]
    for index in try candidates(low:low,high:high,work:&work) {
      let t=triangles[index],points=[coordinatesMM[Int(t.x)],coordinatesMM[Int(t.y)],coordinatesMM[Int(t.z)]]
      for edge in 0..<3 {
        try charge(&work)
        let a=points[edge],d=points[(edge+1)%3]-a,length=simd_length(d)
        let signed=chart.map{Self.cross(d,$0-a)/length}
        // One strict Bernstein sign excludes every root, including an
        // interior tangent. Only a hull straddling this edge needs isolation.
        if signed.allSatisfy({$0>0}) || signed.allSatisfy({$0<0}) {continue}
        try charge(&work,64)
        for root in Self.roots(signed) where root>1e-12 && root<1-1e-12 {
          let p=Self.xz(curve.at(root)),fraction=simd_dot(p-a,d)/simd_length_squared(d)
          if fraction>=(-1e-9),fraction<=1+1e-9 {result.append(root)}
        }
      }
    }
    result.sort();var unique=[Double]()
    for value in result where unique.isEmpty || value-unique.last!>1e-11 {unique.append(value)}
    guard unique.count<=32_768 else {throw Self.failure("A stitch crosses too many parent material boundaries.")}
    return unique
  }
  /// Convex Bézier bounds certify the complete interpolated curve, including
  /// points between renderer keys. D0 is an exact cubic; the residual bounds
  /// normalization around the interval's midpoint normal on one support cell.
  private func certifies(_ reference:Cubic,_ rendered:Cubic,support:Int,depth:Int,work:inout Int)throws->Bool {
    try charge(&work)
    let inside=reference.p.allSatisfy{simd_reduce_min(weights(Self.xz($0),triangle:support)) >= -1e-9}
    if inside {
      let samples=try reference.p.map{try sample(Self.xz($0),triangle:support)}
      let middle=try sample(Self.xz(reference.at(0.5)),triangle:support),n=middle.normal
      let r=samples.map{simd_dot($0.rawNormal,n)}.min()!
      if r>1e-6 {
        var polynomial=0.0,height=0.0,normalVariation=0.0
        for i in 0..<4 {
          let h=normalOffsetMM+reference.p[i].y
          polynomial=max(polynomial,simd_distance(samples[i].p+n*h,rendered.p[i]))
          height=max(height,abs(h));normalVariation=max(normalVariation,simd_distance(samples[i].rawNormal,middle.rawNormal))
        }
        let bound=polynomial+height*normalVariation/r
        if bound<=limits.toleranceMM,try regular(reference.p,support:support) {return true}
        let exact=middle.position(normalOffsetMM+reference.at(0.5).y)
        if simd_distance(exact,rendered.at(0.5))>limits.toleranceMM {return false}
      }
    }
    guard depth<20 else {return false}
    let a=reference.split(0.5),b=rendered.split(0.5)
    return try certifies(a.0,b.0,support:support,depth:depth+1,work:&work) && certifies(a.1,b.1,support:support,depth:depth+1,work:&work)
  }
  public func deformCurve(_ source:[SIMD3<Double>])throws->[SIMD3<Double>] {var budget=makeBudget();return try deformCurve(source,budget:&budget)}
  public func deformCurve(_ source:[SIMD3<Double>],budget:inout Budget)throws->[SIMD3<Double>] {
    guard (2...limits.maximumKeysPerCurve).contains(source.count),source.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_reduce_max(simd_abs($0))<=1_000_000}) else {throw Self.failure("An attached stitch exceeds its finite source-key budget.")}
    let originals=(0..<source.count-1).map{Cubic(keys:source,span:$0)}
    var work=budget.work,subdivisions=1
    defer {budget.work=work}
    let crossings=try originals.map{try boundaries($0,work:&work)}
    // Checking each chart interval also detects narrow holes that might fall
    // between authored keys. A missing material interval is never bridged.
    for span in originals.indices {for i in 0..<crossings[span].count-1 {
      _=try owner(Self.xz(originals[span].at((crossings[span][i]+crossings[span][i+1])/2)),work:&work)
    }}
    while (source.count-1)*subdivisions+1<=limits.maximumKeysPerCurve {
      try Task.checkCancellation();var mapped=[SIMD3<Double>]()
      guard budget.curveKeys+(source.count-1)*subdivisions+1<=limits.maximumCurveKeys else {throw Self.failure("The attached object exceeds its aggregate curve-key budget.")}
      for curve in originals {for key in 0..<subdivisions {try charge(&work);mapped.append(try position(curve.at(Double(key)/Double(subdivisions)),work:&work))}}
      mapped.append(try position(source.last!,work:&work));var certified=true
      for index in 0..<mapped.count-1 {
        let span=index/subdivisions,step=index%subdivisions,lo=Double(step)/Double(subdivisions),hi=Double(step+1)/Double(subdivisions)
        let reference=originals[span].restricted(lo,hi),rendered=Cubic(keys:mapped,span:index)
        let cuts=[0.0]+crossings[span].filter{$0>lo+1e-12 && $0<hi-1e-12}.map{($0-lo)/(hi-lo)}+[1.0]
        for cut in 0..<cuts.count-1 {
          let a=cuts[cut],b=cuts[cut+1],support=try owner(Self.xz(reference.at((a+b)/2)),work:&work)
          if try !certifies(reference.restricted(a,b),rendered.restricted(a,b),support:support,depth:0,work:&work) {certified=false;break}
        }
        if !certified {break}
      }
      if certified {budget.curveKeys+=mapped.count;return mapped}
      subdivisions*=2
    }
    throw Self.failure("The attached stitch cannot meet its interpolated surface error target within the key budget.")
  }
  private struct Vertex {
    var p:SIMD3<Double>,n:SIMD3<Double>,uv:SIMD2<Float>,uv1:SIMD2<Float>,color:SIMD4<Float>,tangent:SIMD4<Double>
    func interpolated(_ other:Self,_ t:Double)->Self {
      .init(p:p+(other.p-p)*t,n:n+(other.n-n)*t,uv:uv+(other.uv-uv)*Float(t),uv1:uv1+(other.uv1-uv1)*Float(t),color:color+(other.color-color)*Float(t),tangent:tangent+(other.tangent-tangent)*t)
    }
  }
  private struct Face {var a:Vertex,b:Vertex,c:Vertex;var support:Int;var part:Int;var area:Double {simd_length(simd_cross(b.p-a.p,c.p-a.p))/2}}
  private struct PointKey:Hashable,Comparable {
    var x:Int64,y:Int64,z:Int64
    init(_ p:SIMD3<Double>) {x=Int64((p.x*1e8).rounded());y=Int64((p.y*1e8).rounded());z=Int64((p.z*1e8).rounded())}
    static func <(a:Self,b:Self)->Bool {a.x != b.x ? a.x<b.x:a.y != b.y ? a.y<b.y:a.z<b.z}
  }
  private struct Edge:Hashable {var a:PointKey,b:PointKey;init(_ p:SIMD3<Double>,_ q:SIMD3<Double>){let x=PointKey(p),y=PointKey(q);a=min(x,y);b=max(x,y)}}
  private func clipped(_ polygon:[Vertex],support:Int)->[Vertex] {
    let t=triangles[support],points=[coordinatesMM[Int(t.x)],coordinatesMM[Int(t.y)],coordinatesMM[Int(t.z)]]
    let sign=Self.cross(points[1]-points[0],points[2]-points[0])>0 ? 1.0:-1.0
    var polygon=polygon
    for i in 0..<3 {
      let a=points[i],b=points[(i+1)%3]
      func distance(_ v:Vertex)->Double {sign*Self.cross(b-a,Self.xz(v.p)-a)}
      var output=[Vertex]()
      guard !polygon.isEmpty else {return []}
      var previous=polygon.last!,pd=distance(previous)
      for current in polygon {
        let cd=distance(current),pin=pd>=0,cin=cd>=0
        if pin != cin {output.append(previous.interpolated(current,pd/(pd-cd)))}
        if cin {output.append(current)}
        previous=current;pd=cd
      }
      polygon=output
    }
    // Intersections at an existing parent vertex can repeat that same boundary
    // point by a few floating-point ulps. Keep collinear distinct vertices,
    // but remove these zero-length edges before the conforming interior fan.
    var cleaned=[Vertex]()
    for vertex in polygon where cleaned.isEmpty || simd_distance(cleaned.last!.p,vertex.p)>1e-9 {cleaned.append(vertex)}
    if cleaned.count>1,simd_distance(cleaned[0].p,cleaned.last!.p)<=1e-9 {cleaned.removeLast()}
    return cleaned
  }
  /// The affine parent position cancels from linear interpolation error. This
  /// conservative bound covers y*normalize(n) using ||D normalize||<=1/r and
  /// ||D² normalize||<=6/r² over the convex triangle, including side walls.
  private func errorBound(_ face:Face)throws->Double {
    let vertices=[face.a,face.b,face.c],raw=try vertices.map{try sample(Self.xz($0.p),triangle:face.support).rawNormal}
    let direction=simd_normalize(raw.reduce(.zero,+)),r=raw.map{simd_dot($0,direction)}.min()!
    guard r>1e-4 else {throw Self.failure("The attached parent normals turn too far within one rendering cell.")}
    var dy=0.0,dn=0.0
    for i in 0..<3 {for j in i+1..<3 {dy=max(dy,abs(vertices[i].p.y-vertices[j].p.y));dn=max(dn,simd_distance(raw[i],raw[j]))}}
    let height=vertices.map{abs(normalOffsetMM+$0.p.y)}.max()!
    return dy*dn/r+3*height*dn*dn/(r*r)
  }
  /// A positive center determinant plus a perturbation smaller than a lower
  /// bound on its smallest singular value certifies invertibility throughout
  /// this convex material cell. Refinement tightens the conservative enclosure.
  private func regular(_ points:[SIMD3<Double>],support:Int)throws->Bool {
    let center=points.reduce(.zero,+)/Double(points.count),middle=try sample(Self.xz(center),triangle:support)
    let raw=try points.map{try sample(Self.xz($0),triangle:support).rawNormal},n=middle.normal
    let r=raw.map{simd_dot($0,n)}.min()!
    guard r>1e-4 else {return false}
    let dn=raw.map{simd_distance($0,middle.rawNormal)}.max()!,dy=points.map{abs($0.y-center.y)}.max()!,height=points.map{abs(normalOffsetMM+$0.y)}.max()!
    let dx=dy*simd_length(middle.nx)/r+height*6*simd_length(middle.nx)*dn/(r*r)
    let dz=dy*simd_length(middle.nz)/r+height*6*simd_length(middle.nz)*dn/(r*r)
    let variation=sqrt(dx*dx+dz*dz+dn*dn/(r*r)),inverse=try middle.jacobian(normalOffsetMM+center.y).inverse
    let minimum=1/sqrt(simd_length_squared(inverse.columns.0)+simd_length_squared(inverse.columns.1)+simd_length_squared(inverse.columns.2))
    return variation<minimum*0.95
  }
  public func deform(_ source:SceneMeshPayload)throws->SceneMeshPayload {var budget=makeBudget();return try deform(source,budget:&budget)}
  public func deform(_ source:SceneMeshPayload,budget:inout Budget)throws->SceneMeshPayload {
    try source.validate(materialCount:(source.parts.map(\.materialIndex).max() ?? 0)+1)
    guard source.triangleCount<=limits.maximumTriangles,source.positionsMM.allSatisfy({simd_reduce_max(simd_abs($0))<=1_000_000}) else {throw Self.failure("An attached render mesh exceeds its source geometry budget.")}
    var faces=[Face](),work=budget.work
    defer {budget.work=work}
    let remainingTriangles=limits.maximumTriangles-budget.triangles
    for (partIndex,part) in source.parts.enumerated() {
      for start in stride(from:0,to:part.triangleIndices.count,by:3) {
        if start.isMultiple(of:768) {try Task.checkCancellation()}
        let ids=(0..<3).map{Int(part.triangleIndices[start+$0])},fallback=simd_cross(source.positionsMM[ids[1]]-source.positionsMM[ids[0]],source.positionsMM[ids[2]]-source.positionsMM[ids[0]])
        guard simd_length_squared(fallback)>1e-24 else {continue}
        let vertices=ids.map {i in Vertex(p:source.positionsMM[i],n:source.normals.isEmpty ? simd_normalize(fallback):SIMD3<Double>(source.normals[i]),uv:source.uvs.isEmpty ? .zero:source.uvs[i],uv1:source.uvs1.isEmpty ? .zero:source.uvs1[i],color:source.colors.isEmpty ? .one:source.colors[i],tangent:source.tangents.isEmpty ? .init(1,0,0,1):SIMD4<Double>(source.tangents[i]))}
        let low=vertices.map{Self.xz($0.p)}.reduce(SIMD2<Double>(repeating:.infinity),simd_min),high=vertices.map{Self.xz($0.p)}.reduce(SIMD2<Double>(repeating:-.infinity),simd_max)
        let area=simd_length(fallback)/2;var covered=0.0
        for support in try candidates(low:low,high:high,work:&work) {
          try charge(&work)
          let polygon=clipped(vertices,support:support)
          guard polygon.count>=3 else {continue}
          let center=polygon.reduce(SIMD3<Double>.zero){$0+$1.p}/Double(polygon.count)
          // Vertical sides project to a line. A shared parent edge must own
          // that nonzero 3D face once rather than duplicate or discard it.
          guard try owner(Self.xz(center),work:&work)==support else {continue}
          // A fan from a boundary vertex may skip collinear boundary keys and
          // create a T-junction against the neighboring cell. An interior fan
          // preserves every nonzero polygon edge, including vertical walls.
          var centerVertex=polygon[0]
          for i in 1..<polygon.count {centerVertex=centerVertex.interpolated(polygon[i],1/Double(i+1))}
          let pieces=polygon.count==3 ? [(polygon[0],polygon[1],polygon[2])]:polygon.indices.map{(centerVertex,polygon[$0],polygon[($0+1)%polygon.count])}
          for (a,b,c) in pieces {
            let face=Face(a:a,b:b,c:c,support:support,part:partIndex)
            guard face.area>1e-16 else {continue};covered+=face.area;faces.append(face)
            guard faces.count<=remainingTriangles else {throw Self.failure("Attached surface clipping exceeds its triangle budget.")}
          }
        }
        guard abs(covered-area)<=max(1e-8,area*1e-7) else {throw Self.failure("The attached object leaves its original material panel or crosses a source hole.")}
      }
    }
    for _ in 0..<20 {
      try Task.checkCancellation();var split=Set<Edge>()
      for face in faces {
        try charge(&work)
        if try errorBound(face)>limits.toleranceMM || !regular([face.a.p,face.b.p,face.c.p],support:face.support) {split.insert(Edge(face.a.p,face.b.p));split.insert(Edge(face.b.p,face.c.p));split.insert(Edge(face.c.p,face.a.p))}
      }
      if split.isEmpty {break}
      var next=[Face]();next.reserveCapacity(min(limits.maximumTriangles,faces.count*2))
      for face in faces {
        try charge(&work)
        let v=[face.a,face.b,face.c],marked=(0..<3).map{split.contains(Edge(v[$0].p,v[($0+1)%3].p))},count=marked.filter{$0}.count
        func append(_ a:Vertex,_ b:Vertex,_ c:Vertex){next.append(.init(a:a,b:b,c:c,support:face.support,part:face.part))}
        if count==0 {next.append(face)}
        else if count==3 {
          let ab=v[0].interpolated(v[1],0.5),bc=v[1].interpolated(v[2],0.5),ca=v[2].interpolated(v[0],0.5)
          append(v[0],ab,ca);append(ab,v[1],bc);append(ca,bc,v[2]);append(ab,bc,ca)
        } else if count==1 {
          let i=marked.firstIndex(of:true)!,a=v[i],b=v[(i+1)%3],c=v[(i+2)%3],m=a.interpolated(b,0.5)
          append(a,m,c);append(m,b,c)
        } else {
          let i=marked.firstIndex(of:false)!,a=v[i],b=v[(i+1)%3],c=v[(i+2)%3],bc=b.interpolated(c,0.5),ca=c.interpolated(a,0.5)
          append(c,ca,bc);append(a,b,bc);append(a,bc,ca)
        }
        guard next.count<=remainingTriangles else {throw Self.failure("The attached surface cannot meet its physical error target within the triangle budget.")}
      }
      faces=next
    }
    guard try faces.allSatisfy({try errorBound($0)<=limits.toleranceMM && regular([$0.a.p,$0.b.p,$0.c.p],support:$0.support)}) else {throw Self.failure("The attached surface exceeded its bounded refinement depth.")}
    var result=SceneMeshPayload(id:source.id+":material-surface",revision:source.revision+":"+revision,positionsMM:[],parts:source.parts.map{.init(materialIndex:$0.materialIndex,triangleIndices:[],semanticID:$0.semanticID)})
    for face in faces {
      for vertex in [face.a,face.b,face.c] {
        try charge(&work)
        let s=try sample(Self.xz(vertex.p),triangle:face.support),height=normalOffsetMM+vertex.p.y,j=try s.jacobian(height)
        let n=simd_normalize(j.inverse.transpose*vertex.n)
        result.parts[face.part].triangleIndices.append(UInt32(result.positionsMM.count));result.positionsMM.append(s.position(height));result.normals.append(SIMD3<Float>(n))
        if !source.uvs.isEmpty {result.uvs.append(vertex.uv)};if !source.uvs1.isEmpty {result.uvs1.append(vertex.uv1)}
        if !source.colors.isEmpty {result.colors.append(vertex.color)}
        if !source.tangents.isEmpty {let tangent=simd_normalize(j*SIMD3(vertex.tangent.x,vertex.tangent.y,vertex.tangent.z));result.tangents.append(.init(Float(tangent.x),Float(tangent.y),Float(tangent.z),Float(vertex.tangent.w)))}
      }
    }
    try result.validate(materialCount:(source.parts.map(\.materialIndex).max() ?? 0)+1);budget.triangles+=result.triangleCount;return result
  }
}
