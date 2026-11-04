import Foundation
import FormCore
import FormGeometry
import simd

/// A physical neutral-axis hinge: width is material arc length, and all stock
/// strata share its radius. UVs stay in their undeformed source coordinates.
@MainActor enum SheetPanelFlexGeometry {
  struct Sample {var distanceMM:Double,heightMM:Double,angle:Double,curvature:Double}
  static func sample(_ distance:Double,widthMM:Double,angleDegrees:Double)->Sample {
    let value=ResolvedSheetPanelFlex.circularSample(atMM:distance,widthMM:widthMM,angleDegrees:angleDegrees)
    return .init(distanceMM:value.xMM,heightMM:value.yMM,angle:value.angleRadians,curvature:value.curvaturePerMM)
  }
  static func make(_ base:MeshGeometry,size:Point2,edge:String,widthMM:Double,angleDegrees:Double,final:Bool,tailRiseMM:Double=0,curve:SheetPanelNeutralCurveProfile?=nil)throws->MeshGeometry {
    guard widthMM>0,widthMM.isFinite,angleDegrees.isFinite,abs(angleDegrees)<=180 else{throw FormError.invalid("A sheet hinge needs a finite physical width and an angle within 180 degrees.")}
    let horizontal=edge=="left" || edge=="right",reverse=edge=="right" || edge=="tail"
    let extent=horizontal ? size.x:size.y
    guard widthMM<=extent else{throw FormError.invalid("The sheet hinge must fit within its material extent.")}
    let tailLength=extent-widthMM
    guard tailRiseMM.isFinite,abs(tailRiseMM)<=tailLength/2 else{throw FormError.invalid("The free hinge tail bend must remain within half its physical material length.")}
    var tailAngle=0.0
    if tailRiseMM != 0 {
      var low=0.0,high=Double.pi/2
      for _ in 0..<40 {let a=(low+high)/2;if tailLength*(1-cos(a))/a<abs(tailRiseMM){low=a}else{high=a}}
      tailAngle=(low+high)/2*(tailRiseMM<0 ? -1:1)
    }
    func flexSample(_ d:Double)->Sample {
      if let curve {let v=curve.sample(atMM:d);return .init(distanceMM:v.xMM,heightMM:v.yMM,angle:v.angleRadians,curvature:v.curvaturePerMM)}
      let hinge=sample(d,widthMM:widthMM,angleDegrees:angleDegrees)
      guard d>widthMM,tailAngle != 0 else{return hinge}
      let end=sample(widthMM,widthMM:widthMM,angleDegrees:angleDegrees),r=tailLength/tailAngle,a=end.angle+(d-widthMM)/r
      return .init(distanceMM:end.distanceMM+r*(sin(a)-sin(end.angle)),heightMM:end.heightMM+r*(cos(end.angle)-cos(a)),angle:a,curvature:1/r)
    }
    let positions=base.sources(for:.vertex).first?.vectors ?? [],normals=base.sources(for:.normal).first?.vectors ?? [],uv=base.sources(for:.texcoord).first?.points ?? []
    guard !positions.isEmpty,positions.count==normals.count,positions.count==uv.count else{throw FormError.invalid("Sheet flex requires matched physical mesh buffers.")}
    let half=positions.map{abs($0.z*100)}.max() ?? 0
    try curve?.validateCaliper(maximumNormalOffsetMM:half)
    if curve==nil,angleDegrees != 0 {guard abs(widthMM/(angleDegrees * .pi/180))>half else{throw FormError.invalid("A hinge radius must exceed the physical stock caliper.")}}
    struct Vertex {var p:SIMD3<Double>,n:SIMD3<Double>,uv:CGPoint
      func mix(_ b:Vertex,_ t:Double)->Vertex{.init(p:p+(b.p-p)*t,n:n+(b.n-n)*t,uv:.init(x:uv.x+(b.uv.x-uv.x)*t,y:uv.y+(b.uv.y-uv.y)*t))}}
    func distance(_ p:SIMD3<Double>)->Double{let d=(horizontal ? p.x:-p.y)*100;return reverse ? extent-d:d}
    func clip(_ polygon:[Vertex],at cut:Double,lower:Bool)->[Vertex] {
      guard var previous=polygon.last else{return []};var result=[Vertex](),prior=distance(previous.p)
      var priorInside=lower ? prior>=cut-1e-9:prior<=cut+1e-9
      for vertex in polygon {let current=distance(vertex.p),inside=lower ? current>=cut-1e-9:current<=cut+1e-9
        if inside != priorInside {result.append(previous.mix(vertex,(cut-prior)/(current-prior)))}
        if inside {result.append(vertex)};previous=vertex;prior=current;priorInside=inside
      };return result
    }
    let count=curve==nil ? (final ? 48:24):(final ? 160:80)
    let materialDistances=positions.map{distance($0.simd)},minimum=materialDistances.min() ?? 0,maximum=materialDistances.max() ?? extent
    var cuts=[min(0,minimum)]+(0...count).map{widthMM*Double($0)/Double(count)}
    if tailLength>1e-9 {cuts += (1...count).map{widthMM+tailLength*Double($0)/Double(count)}}
    cuts.append(max(extent,maximum));cuts=Array(Set(cuts)).sorted()
    var output=[MeshVector3](),outputNormals=[MeshVector3](),outputUV=[CGPoint](),elements=[MeshGeometryElement]()
    func append(_ v:Vertex)throws->UInt32 {
      guard output.count<500_000 else{throw FormError.invalid("Sheet flex exceeded its bounded physical geometry allocation.")}
      let d=distance(v.p),s=flexSample(d),z=v.p.z*100
      let direction=reverse ? -1.0:1.0,c=cos(s.angle),sn=sin(s.angle),scale=1-s.curvature*z
      guard scale>0 else{throw FormError.invalid("Sheet flex folds through its stock caliper.")}
      var p=v.p,n=v.n
      let axis=(reverse ? extent:0)+direction*(s.distanceMM-sn*z)
      let axisNormal=(horizontal ? v.n.x:-v.n.y)*direction/scale
      let rotated=axisNormal*c-v.n.z*sn,nz=axisNormal*sn+v.n.z*c
      if horizontal {p.x=axis/100;n.x=direction*rotated}else{p.y = -axis/100;n.y = -direction*rotated}
      p.z=(s.heightMM+c*z)/100;n.z=nz
      let i=UInt32(output.count);output.append(.init(p));outputNormals.append(.init(simd_normalize(n)));outputUV.append(v.uv);return i
    }
    for element in base.elements {
      guard element.primitiveType == .triangles else{throw FormError.invalid("Sheet flex supports physical triangle surfaces.")};var indices=[UInt32]()
      for i in stride(from:0,to:element.indices.count,by:3) where i+2<element.indices.count {
        let ids=Array(element.indices[i..<i+3]).map(Int.init)
        guard ids.allSatisfy({positions.indices.contains($0)}) else{throw FormError.invalid("Sheet flex encountered an invalid mesh index.")}
        let triangle=ids.map{Vertex(p:positions[$0].simd,n:normals[$0].simd,uv:uv[$0])}
        let lo=triangle.map{distance($0.p)}.min()!,hi=triangle.map{distance($0.p)}.max()!
        for j in 0..<(cuts.count-1) where cuts[j+1]>cuts[j]+1e-9 && cuts[j]<=hi+1e-9 && cuts[j+1]>=lo-1e-9 {
          let polygon=clip(clip(triangle,at:cuts[j],lower:true),at:cuts[j+1],lower:false)
          guard polygon.count>=3 else{continue};let values=try polygon.map(append)
          for k in 1..<(values.count-1) where simd_length_squared(simd_cross(polygon[k].p-polygon[0].p,polygon[k+1].p-polygon[0].p))>1e-24 {indices += [values[0],values[k],values[k+1]]}
        }
      };elements.append(.init(indices:indices,primitiveType:.triangles))
    }
    let mesh=MeshGeometry(sources:[.init(vertices:output),.init(normals:outputNormals),.init(textureCoordinates:outputUV)],elements:elements)
    mesh.materials=base.materials;mesh.name="sheet.panel-flex:\(base.name ?? ""):\(edge):\(widthMM):\(angleDegrees)";return mesh
  }
}
