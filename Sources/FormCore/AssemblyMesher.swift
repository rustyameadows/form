import Foundation
import CFormMesher

public struct AssemblyMesh2D:Equatable,Sendable {
  public var points:[Point2]
  public var triangles:[ClothTriangle]
  public var boundaries:[[Int]]
  public var areaMm2:Double
  public var boundaryLengthMm:Double
  public var minimumTriangleAreaMm2:Double
  public var maximumEdgeMm:Double
  public var operations:Int
}
/// Bounded seed triangulation, physical interior seeding and conforming
/// longest-edge bisection with boundary-preserving quality flips.
/// Output quality is measured, never described as a Delaunay/fit guarantee.
public enum AssemblyMesher {
  public static let maximumBoundaryVertices=512
  public static let maximumRings=16
  public static let maximumOperations=32_000_000
  private struct Budget {
    var used=0,limit:Int
    mutating func charge(_ count:Int = 1)throws {try Task.checkCancellation();guard count>=0,used<=limit-count else {throw FormError.invalid("Pattern meshing exceeded its declared work budget. Simplify the piece or use larger mesh spacing.")};used+=count}
  }
  private struct Edge:Hashable,Comparable {
    var a:Int,b:Int
    init(_ x:Int,_ y:Int) {a=min(x,y);b=max(x,y)}
    static func <(a:Self,b:Self)->Bool {a.a==b.a ? a.b<b.b:a.a<b.a}
  }
  private struct Use {var triangle:Int,a:Int,b:Int,opposite:Int}
  private static func cross(_ a:Point2,_ b:Point2,_ c:Point2)->Double {(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)}
  private static func distance2(_ a:Point2,_ b:Point2)->Double {pow(a.x-b.x,2)+pow(a.y-b.y,2)}
  private static func area(_ ring:[Point2])->Double {ring.indices.reduce(0){sum,i in let a=ring[i],b=ring[(i+1)%ring.count];return sum+a.x*b.y-b.x*a.y}/2}
  private static func onSegment(_ p:Point2,_ a:Point2,_ b:Point2)->Bool {
    let length=sqrt(distance2(a,b));guard length>1e-12,abs(cross(a,b,p))<=1e-8*length else {return false}
    return p.x>=min(a.x,b.x)-1e-8 && p.x<=max(a.x,b.x)+1e-8 && p.y>=min(a.y,b.y)-1e-8 && p.y<=max(a.y,b.y)+1e-8
  }
  private static func intersects(_ a:Point2,_ b:Point2,_ c:Point2,_ d:Point2)->Bool {
    if max(a.x,b.x)<min(c.x,d.x)-1e-8 || max(c.x,d.x)<min(a.x,b.x)-1e-8 || max(a.y,b.y)<min(c.y,d.y)-1e-8 || max(c.y,d.y)<min(a.y,b.y)-1e-8 {return false}
    let abC=cross(a,b,c),abD=cross(a,b,d),cdA=cross(c,d,a),cdB=cross(c,d,b)
    if abC*abD<0,cdA*cdB<0 {return true}
    return onSegment(c,a,b) || onSegment(d,a,b) || onSegment(a,c,d) || onSegment(b,c,d)
  }
  private static func contains(_ p:Point2,_ ring:[Point2])->Bool {
    var inside=false
    for i in ring.indices {
      let a=ring[i],b=ring[(i+1)%ring.count]
      if onSegment(p,a,b) {return false}
      if (a.y>p.y) != (b.y>p.y),p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x {inside.toggle()}
    };return inside
  }
  private static func oriented(_ a:Int,_ b:Int,_ c:Int,points:[Point2])throws -> ClothTriangle {
    let value=cross(points[a],points[b],points[c]);guard abs(value)>1e-10 else {throw FormError.invalid("Pattern triangulation contains a degenerate face.")}
    return value>0 ? .init(a,b,c):.init(a,c,b)
  }
  private static func edges(_ triangles:[ClothTriangle],budget:inout Budget)throws -> [Edge:[Use]] {
    try budget.charge(triangles.count*3);var result:[Edge:[Use]]=[:]
    for (i,t) in triangles.enumerated() {for (a,b,c) in [(t.a,t.b,t.c),(t.b,t.c,t.a),(t.c,t.a,t.b)] {result[Edge(a,b),default:[]].append(.init(triangle:i,a:a,b:b,opposite:c))}}
    guard result.values.allSatisfy({$0.count<=2}) else {throw FormError.invalid("Pattern triangulation is nonmanifold.")};return result
  }
  /// Lawson-style interior flips preserve the boundary, holes and every vertex.
  /// The deterministic queue is budgeted. Ties are left unchanged; independent
  /// topology/area/crossing audits still validate the resulting triangulation.
  private static func legalize(points:[Point2],triangles:inout [ClothTriangle],budget:inout Budget)throws {
    var map=try edges(triangles,budget:&budget),queue=map.keys.sorted(),cursor=0,flips=0
    func insideCircumcircle(_ a:Point2,_ b:Point2,_ c:Point2,_ d:Point2)->Bool {
      let ax=a.x-d.x,ay=a.y-d.y,bx=b.x-d.x,by=b.y-d.y,cx=c.x-d.x,cy=c.y-d.y
      let aa=ax*ax+ay*ay,bb=bx*bx+by*by,cc=cx*cx+cy*cy
      let value=aa*(bx*cy-cx*by)-bb*(ax*cy-cx*ay)+cc*(ax*by-bx*ay),scale=max(aa,bb,cc),epsilon=max(1e-12,scale*scale*1e-12)
      return cross(a,b,c)>0 ? value>epsilon:value < -epsilon
    }
    func pairs(_ t:ClothTriangle)->[(Int,Int,Int)] {[(t.a,t.b,t.c),(t.b,t.c,t.a),(t.c,t.a,t.b)]}
    while cursor<queue.count {
      try budget.charge();let edge=queue[cursor];cursor+=1
      guard let uses=map[edge],uses.count==2 else{continue}
      let a=edge.a,b=edge.b,c=uses[0].opposite,d=uses[1].opposite
      guard c != d,map[Edge(c,d)]==nil else{continue}
      let x=points[a],y=points[b],u=points[c],v=points[d]
      // Only a strictly convex two-face union admits the alternative diagonal.
      guard cross(x,y,u)*cross(x,y,v) < -1e-16,cross(u,v,x)*cross(u,v,y) < -1e-16,insideCircumcircle(x,y,u,v) else{continue}
      guard flips<min(100000,triangles.count*32),queue.count<650000 else{throw FormError.invalid("Pattern quality legalization exceeded its bounded flip work. Simplify the source or use larger spacing.")}
      flips+=1;try budget.charge(12)
      let first=uses[0].triangle,second=uses[1].triangle
      for index in [first,second] {for (p,q,_) in pairs(triangles[index]) {let key=Edge(p,q);map[key]?.removeAll{$0.triangle==index};if map[key]?.isEmpty==true {map[key]=nil}}}
      triangles[first]=try oriented(c,d,a,points:points);triangles[second]=try oriented(d,c,b,points:points)
      var affected=Set<Edge>()
      for index in [first,second] {for (p,q,o) in pairs(triangles[index]) {let key=Edge(p,q);map[key,default:[]].append(.init(triangle:index,a:p,b:q,opposite:o));affected.insert(key)}}
      queue += affected.sorted()
    }
  }
  /// Interior Steiner points prevent a curved boundary-only seed from forming
  /// long, almost collinear fans. Coordinates remain in the original physical
  /// material space. Boundary/seam/pin vertices are never removed or moved.
  private static func seedInterior(points:inout [Point2],triangles:inout [ClothTriangle],rings:[[Point2]],spacing:Double,maximumVertices:Int,budget:inout Budget)throws {
    let step=spacing*0.8,clearance=step*0.28,minX=rings[0].map(\.x).min()!,maxX=rings[0].map(\.x).max()!,minY=rings[0].map(\.y).min()!,maxY=rings[0].map(\.y).max()!
    let columns=Int(ceil((maxX-minX)/step)),rows=Int(ceil((maxY-minY)/step))
    guard columns<=2000,rows<=2000,columns*rows<=100000 else {throw FormError.invalid("The declared cloth spacing exceeds its bounded interior sampling budget.")}
    func segmentDistance2(_ p:Point2,_ a:Point2,_ b:Point2)->Double {let dx=b.x-a.x,dy=b.y-a.y,n=dx*dx+dy*dy,t=min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/n));return pow(p.x-a.x-t*dx,2)+pow(p.y-a.y-t*dy,2)}
    for row in 0..<rows {for column in 0..<columns {
      try budget.charge(rings.reduce(0){$0+$1.count})
      let point=Point2(minX+(Double(column)+0.5)*step,minY+(Double(row)+0.5)*step)
      guard contains(point,rings[0]),!rings.dropFirst().contains(where:{contains(point,$0)}) else{continue}
      guard rings.allSatisfy({ring in ring.indices.allSatisfy{segmentDistance2(point,ring[$0],ring[($0+1)%ring.count])>=clearance*clearance}}) else{continue}
      try budget.charge(triangles.count)
      guard let index=triangles.firstIndex(where:{t in cross(points[t.a],points[t.b],point) >= -1e-8 && cross(points[t.b],points[t.c],point) >= -1e-8 && cross(points[t.c],points[t.a],point) >= -1e-8}) else{throw FormError.invalid("An interior cloth sample has no containing material face.")}
      guard points.count<maximumVertices,triangles.count+2<=ClothMesh.maximumTriangles else{throw FormError.invalid("The requested interior cloth spacing exceeds its mesh budget. Use larger spacing or fewer panels.")}
      let t=triangles[index],vertex=points.count
      let edge=[(t.a,t.b,t.c),(t.b,t.c,t.a),(t.c,t.a,t.b)].first {abs(cross(points[$0.0],points[$0.1],point))<=1e-8}
      points.append(point)
      if let (a,b,c)=edge {
        // A regular grid can land exactly on an interior diagonal. Split both
        // incident faces so this does not create a T-junction or zero-area face.
        let shared=try edges(triangles,budget:&budget)[Edge(a,b)]!
        guard shared.count==2 else{throw FormError.invalid("Interior seeding unexpectedly reached a material boundary.")}
        triangles[index]=try oriented(a,vertex,c,points:points);triangles.append(try oriented(vertex,b,c,points:points))
        let other=shared.first{$0.triangle != index}!
        triangles[other.triangle]=try oriented(other.a,vertex,other.opposite,points:points);triangles.append(try oriented(vertex,other.b,other.opposite,points:points))
      } else {
        triangles[index]=try oriented(t.a,t.b,vertex,points:points);triangles.append(try oriented(t.b,t.c,vertex,points:points));triangles.append(try oriented(t.c,t.a,vertex,points:points))
      }
    }}
  }
  public static func mesh(contours input:[[Point2]],maximumEdgeMm:Double = 12,maximumVertices:Int = 2048,workLimit:Int = 8_000_000)throws -> AssemblyMesh2D {
    guard maximumEdgeMm.isFinite,(2...100).contains(maximumEdgeMm),(3...ClothMesh.maximumVertices).contains(maximumVertices),(1000...maximumOperations).contains(workLimit),(1...maximumRings).contains(input.count) else {throw FormError.invalid("Declare 2–100mm mesh spacing, bounded vertices/rings and an explicit meshing work limit.")}
    var budget=Budget(limit:workLimit),rings=input
    for i in rings.indices {if rings[i].count>1,distance2(rings[i][0],rings[i].last!)<1e-18 {rings[i].removeLast()}}
    guard rings.allSatisfy({$0.count>=3}),rings.reduce(0,{$0+$1.count})<=maximumBoundaryVertices else {throw FormError.invalid("A panel seed supports 3–512 total boundary vertices and up to 16 rings.")}
    var points=rings.flatMap{$0};guard points.count<=maximumVertices else {throw FormError.invalid("The declared boundary already exceeds the panel vertex budget.")}
    guard points.allSatisfy({$0.x.isFinite && $0.y.isFinite && max(abs($0.x),abs($0.y))<=100000}) else {throw FormError.invalid("Pattern meshing needs finite physical millimeter coordinates.")}
    for i in points.indices {for j in 0..<i {try budget.charge();guard distance2(points[i],points[j])>1e-16 else {throw FormError.invalid("Pattern boundaries cannot repeat or touch at the same vertex.")}}}
    for r in rings.indices {
      guard abs(area(rings[r]))>1e-6 else {throw FormError.invalid("Pattern ring area is zero.")}
      for i in rings[r].indices {for s in 0...r {for j in rings[s].indices {
        if s==r && (j>=i || j==(i+1)%rings[r].count || i==(j+1)%rings[r].count) {continue}
        try budget.charge()
        guard !intersects(rings[r][i],rings[r][(i+1)%rings[r].count],rings[s][j],rings[s][(j+1)%rings[s].count]) else {throw FormError.invalid("Pattern rings must be simple, disjoint and free of touching/self-crossing edges.")}
      }}}
      if r>0 {guard contains(rings[r][0],rings[0]) else {throw FormError.invalid("Every pattern hole must lie strictly inside its outer contour.")}
        for s in 1..<r {guard !contains(rings[r][0],rings[s]),!contains(rings[s][0],rings[r]) else {throw FormError.invalid("Nested holes require an explicit supported source.")}}
      }
    }
    var indices:[[Int]]=[],at=0
    for ring in rings {indices.append(Array(at..<at+ring.count));at+=ring.count}
    let xy=points.flatMap{[$0.x,$0.y]},sizes=rings.map{UInt32($0.count)}
    var output=FMIndexBuffer(indices:nil,count:0)
    let status=xy.withUnsafeBufferPointer {coordinates in sizes.withUnsafeBufferPointer {counts in fm_triangulate(coordinates.baseAddress,points.count,counts.baseAddress,counts.count,&output)}}
    defer {fm_free_indices(&output)}
    guard status==0,let raw=output.indices,output.count%3==0 else {throw FormError.invalid("The bounded polygon seed could not triangulate this source; simplify it explicitly.")}
    var triangles:[ClothTriangle]=[]
    for i in stride(from:0,to:Int(output.count),by:3) {triangles.append(try oriented(Int(raw[i]),Int(raw[i+1]),Int(raw[i+2]),points:points))}
    // Ear slicing can omit collinear boundary points. Recover every declared
    // seam/pin sample as a true vertex on its existing boundary edge.
    let used=Set(triangles.flatMap{[$0.a,$0.b,$0.c]})
    for index in points.indices where !used.contains(index) {
      let map=try edges(triangles,budget:&budget)
      guard let entry=map.keys.sorted().first(where:{edge in map[edge]!.count==1 && onSegment(points[index],points[edge.a],points[edge.b])}) else {throw FormError.invalid("The triangulation omitted a source boundary vertex that cannot be recovered safely.")}
      let use=map[entry]![0];triangles[use.triangle]=try oriented(use.a,index,use.opposite,points:points);triangles.append(try oriented(index,use.b,use.opposite,points:points))
    }
    try seedInterior(points:&points,triangles:&triangles,rings:rings,spacing:maximumEdgeMm,maximumVertices:maximumVertices,budget:&budget)
    try legalize(points:points,triangles:&triangles,budget:&budget)
    // Split all oversized edges in one conforming round. Shared midpoints are
    // allocated once, avoiding quadratic full-mesh rebuilds per individual split.
    for round in 0..<24 {
      let map=try edges(triangles,budget:&budget)
      let marked=map.keys.sorted().filter {distance2(points[$0.a],points[$0.b])>maximumEdgeMm*maximumEdgeMm+1e-10}
      try budget.charge(map.count)
      if marked.isEmpty {break}
      guard round<23,points.count+marked.count<=maximumVertices else {throw FormError.invalid("The requested cloth spacing exceeds its mesh budget. Use larger spacing or fewer panels.")}
      var midpoint:[Edge:Int]=[:]
      for edge in marked {let a=points[edge.a],b=points[edge.b];midpoint[edge]=points.count;points.append(.init((a.x+b.x)/2,(a.y+b.y)/2))}
      var refined:[ClothTriangle]=[]
      for t in triangles {
        try budget.charge()
        var a=t.a,b=t.b,c=t.c
        let count=[Edge(a,b),Edge(b,c),Edge(c,a)].filter {midpoint[$0] != nil}.count
        if count==0 {refined.append(t);continue}
        if count==3 {
          let p=midpoint[Edge(a,b)]!,q=midpoint[Edge(b,c)]!,r=midpoint[Edge(c,a)]!
          refined += [try oriented(a,p,r,points:points),try oriented(p,b,q,points:points),try oriented(r,q,c,points:points),try oriented(p,q,r,points:points)]
        } else {
          for _ in 0..<3 {
            let ab=midpoint[Edge(a,b)] != nil,bc=midpoint[Edge(b,c)] != nil
            if count==1 && ab || count==2 && ab && bc {break}
            (a,b,c)=(b,c,a)
          }
          let p=midpoint[Edge(a,b)]!
          if count==1 {refined += [try oriented(a,p,c,points:points),try oriented(p,b,c,points:points)]}
          else {let q=midpoint[Edge(b,c)]!;refined += [try oriented(b,q,p,points:points),try oriented(a,p,c,points:points),try oriented(p,q,c,points:points)]}
        }
      }
      guard refined.count<=ClothMesh.maximumTriangles else {throw FormError.invalid("Pattern refinement exceeds its triangle budget.")}
      triangles=refined
      try legalize(points:points,triangles:&triangles,budget:&budget)
      for r in indices.indices {
        let prior=indices[r];var next:[Int]=[]
        for i in prior.indices {try budget.charge();next.append(prior[i]);if let p=midpoint[Edge(prior[i],prior[(i+1)%prior.count])] {next.append(p)}}
        indices[r]=next
      }
    }
    let map=try edges(triangles,budget:&budget),actualBoundary=Set(map.filter{$0.value.count==1}.map(\.key)),declaredBoundary=Set(indices.flatMap{ring in ring.indices.map{Edge(ring[$0],ring[($0+1)%ring.count])}})
    guard actualBoundary==declaredBoundary,Set(triangles.flatMap{[$0.a,$0.b,$0.c]}).count==points.count else {throw FormError.invalid("The derived mesh does not preserve every source boundary or contains an unused vertex.")}
    let targetArea=abs(area(rings[0]))-rings.dropFirst().reduce(0){$0+abs(area($1))},areas=triangles.map{cross(points[$0.a],points[$0.b],points[$0.c])/2},total=areas.reduce(0,+)
    guard targetArea>0,abs(total-targetArea)<=max(1e-6,targetArea*1e-8) else {throw FormError.invalid("Triangle area disagrees with the original outer-minus-hole material area.")}
    for t in triangles {try budget.charge();let a=points[t.a],b=points[t.b],c=points[t.c],center=Point2((a.x+b.x+c.x)/3,(a.y+b.y+c.y)/3)
      guard contains(center,rings[0]),!rings.dropFirst().contains(where:{contains(center,$0)}) else {throw FormError.invalid("A generated face lies outside material or inside a hole.")}}
    // Independent sweep check rejects crossing/overlapping nonadjacent mesh edges.
    let ordered=map.keys.sorted {a,b in let x=min(points[a.a].x,points[a.b].x),y=min(points[b.a].x,points[b.b].x);return x==y ? a<b:x<y}
    for i in ordered.indices {let e=ordered[i],xmax=max(points[e.a].x,points[e.b].x)
      for j in i+1..<ordered.count {let f=ordered[j];if min(points[f.a].x,points[f.b].x)>xmax+1e-8 {break};try budget.charge()
        if e.a==f.a || e.a==f.b || e.b==f.a || e.b==f.b {continue}
        guard !intersects(points[e.a],points[e.b],points[f.a],points[f.b]) else {throw FormError.invalid("Derived mesh edges cross outside their declared shared vertices.")}
      }
    }
    let perimeter=indices.reduce(0){sum,ring in sum+ring.indices.reduce(0){$0+sqrt(distance2(points[ring[$1]],points[ring[($1+1)%ring.count]]))}}
    return .init(points:points,triangles:triangles,boundaries:indices,areaMm2:total,boundaryLengthMm:perimeter,minimumTriangleAreaMm2:areas.min()!,maximumEdgeMm:sqrt(map.keys.map{distance2(points[$0.a],points[$0.b])}.max()!),operations:budget.used)
  }
}
