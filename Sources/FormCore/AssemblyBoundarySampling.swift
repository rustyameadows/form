import Foundation

struct AssemblyEdgePoint:Hashable {
  var edge:UUID
  var fraction:Int64
  init(_ edge:UUID,_ fraction:Double) {self.edge=edge;self.fraction=Int64((fraction*1_000_000_000_000).rounded())}
}
struct AssemblyPanelBoundary {
  var rings:[[Point2]]
  var vertexForSample:[AssemblyEdgePoint:Int]
  var sourceOrigin:Point2
  var materialSize:Point2
  var sourceArea:Double
  var maximumDeviationMm:Double
}
enum AssemblyBoundarySampling {
  private struct Sample {var fraction:Double;var point:Point2;var required:Bool}
  static func make(_ boundaries:[SewingBoundary],spacing:Double,tolerance:Double,required:[UUID:[Double]],budget:inout AssemblyBuildBudget)throws -> AssemblyPanelBoundary {
    guard !boundaries.isEmpty,boundaries.count<=AssemblyMesher.maximumRings else {throw FormError.invalid("Choose one outer material contour and up to15 holes.")}
    let points=boundaries.flatMap(\.points),minX=points.map(\.x).min()!,minY=points.map(\.y).min()!,width=points.map(\.x).max()!-minX,height=points.map(\.y).max()!-minY
    guard (1...2000).contains(width),(1...2000).contains(height) else {throw FormError.invalid("Assembly panel spans must be1–2000mm in material coordinates.")}
    let origin=Point2(minX,minY)
    var result:[[Point2]]=[],mapping:[AssemblyEdgePoint:Int]=[:],offset=0,maximumDeviation=0.0
    for boundary in boundaries {
      var ring:[Point2]=[]
      for edge in boundary.edges {
        guard let id=edge.id,edge.endID != nil else {throw FormError.invalid("Prepare stable original source edge identities before assembly.")}
        let samples=try simplify(edge,spacing:spacing,tolerance:tolerance,required:required[id] ?? [],budget:&budget)
        let start=offset+ring.count
        for sample in samples.dropLast() {mapping[.init(id,sample.fraction)]=offset+ring.count;ring.append(.init(sample.point.x-minX,sample.point.y-minY))}
        for fraction in required[id] ?? [] where fraction<1 {
          try budget.charge(samples.count)
          if let i=samples.firstIndex(where:{abs($0.fraction-fraction)<1e-10}) {mapping[.init(id,fraction)]=start+i}
        }
        maximumDeviation=max(maximumDeviation,try deviation(edge.points,from:samples.map(\.point),budget:&budget))
      }
      // An edge's final sample is the next original edge's first source vertex.
      for i in boundary.edges.indices {
        let edge=boundary.edges[i],next=boundary.edges[(i+1)%boundary.edges.count]
        mapping[.init(edge.id!,1)]=mapping[.init(next.id!,0)]
      }
      guard ring.count>=3 else {throw FormError.invalid("Assembly boundary sampling collapsed a contour.")};result.append(ring);offset+=ring.count
    }
    guard offset<=AssemblyMesher.maximumBoundaryVertices,maximumDeviation<=tolerance+1e-7 else {throw FormError.invalid("Boundary sampling exceeds its vertex/deviation budget; simplify the source or use a declared coarser tolerance.")}
    let area=boundaries.reduce(0.0){sum,b in sum+(b.isHole ? -1:1)*abs(polygonArea(b.points))}
    return .init(rings:result,vertexForSample:mapping,sourceOrigin:origin,materialSize:.init(width,height),sourceArea:area,maximumDeviationMm:maximumDeviation)
  }
  static func arcFractions(_ edge:SewingBoundaryEdge,spacing:Double,tolerance:Double,required:[Double],budget:inout AssemblyBuildBudget)throws -> [Double] {
    try simplify(edge,spacing:spacing,tolerance:tolerance,required:required,budget:&budget).map(\.fraction)
  }
  private static func simplify(_ edge:SewingBoundaryEdge,spacing:Double,tolerance:Double,required requested:[Double],budget:inout AssemblyBuildBudget)throws -> [Sample] {
    try budget.charge(edge.points.count*2)
    let lengths=zip(edge.points,edge.points.dropFirst()).map{hypot($1.x-$0.x,$1.y-$0.y)},total=lengths.reduce(0,+)
    guard total>0,edge.points.count<=8192 else {throw FormError.invalid("Invalid source arc for cloth sampling.")}
    let count=max(1,Int(ceil(edge.length/spacing))),fractions=([0.0,1.0]+requested+(0...count).map{Double($0)/Double(count)}).sorted()
    guard fractions.allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw FormError.invalid("Choose source edge fractions from0–1.")}
    var values:[Sample]=[],consumed=0.0
    for i in edge.points.indices {let f=consumed/total;values.append(.init(fraction:i==edge.points.count-1 ? 1:f,point:edge.points[i],required:i==0 || i==edge.points.count-1));if i<lengths.count {consumed+=lengths[i]}}
    for f in fractions {
      try budget.charge(values.count+edge.points.count*2)
      if let i=values.firstIndex(where:{abs($0.fraction-f)<1e-11}) {values[i].required=true}
      else {values.append(.init(fraction:f,point:edge.sample(fraction:f).point,required:true))}
    }
    values.sort{$0.fraction<$1.fraction}
    // Adaptive source tessellation points are not anchors. Keeping whichever
    // source-polyline point Douglas–Peucker selects can place a free vertex
    // arbitrarily close to an exact seam fraction. Bisect physical arc spans
    // instead, preserving all required anchors and the same measured deviation.
    let anchors=values.filter(\.required)
    var sampled:[Sample]=[anchors[0]]
    for i in 1..<anchors.count {try subdivide(edge,source:values,from:anchors[i-1],to:anchors[i],tolerance:tolerance,depth:0,result:&sampled,budget:&budget)}
    return sampled
  }
  private static func subdivide(_ edge:SewingBoundaryEdge,source:[Sample],from a:Sample,to b:Sample,tolerance:Double,depth:Int,result:inout [Sample],budget:inout AssemblyBuildBudget)throws {
    try budget.charge(source.count)
    let maximum=source.lazy.filter{$0.fraction>a.fraction && $0.fraction<b.fraction}.map{distance($0.point,to:a.point,b.point)}.max() ?? 0
    if maximum<=tolerance {result.append(b);return}
    guard depth<32,result.count<AssemblyMesher.maximumBoundaryVertices else{throw FormError.invalid("Source boundary refinement exceeds its balanced subdivision budget.")}
    let fraction=(a.fraction+b.fraction)/2;try budget.charge(edge.points.count*2)
    let middle=Sample(fraction:fraction,point:edge.sample(fraction:fraction).point,required:false)
    try subdivide(edge,source:source,from:a,to:middle,tolerance:tolerance,depth:depth+1,result:&result,budget:&budget)
    try subdivide(edge,source:source,from:middle,to:b,tolerance:tolerance,depth:depth+1,result:&result,budget:&budget)
  }
  private static func distance(_ point:Point2,to a:Point2,_ b:Point2)->Double {
    let dx=b.x-a.x,dy=b.y-a.y,n=dx*dx+dy*dy,t=n>0 ? min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/n)):0
    return hypot(point.x-a.x-dx*t,point.y-a.y-dy*t)
  }
  private static func deviation(_ source:[Point2],from sampled:[Point2],budget:inout AssemblyBuildBudget)throws -> Double {
    guard sampled.count>=2 else {throw FormError.invalid("No sampled source edge.")}
    try budget.charge(source.count*(sampled.count-1))
    return source.map{p in zip(sampled,sampled.dropFirst()).map{distance(p,to:$0.0,$0.1)}.min()!}.max() ?? 0
  }
  static func polygonArea(_ points:[Point2])->Double {points.indices.reduce(0){sum,i in let a=points[i],b=points[(i+1)%points.count];return sum+a.x*b.y-b.x*a.y}/2}
}
