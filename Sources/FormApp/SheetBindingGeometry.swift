import AppKit
import FormCore
import FormGeometry
import simd

/// Caliper-aware, bounded physical wire geometry. No artwork or stock is copied.
@MainActor enum SheetBindingGeometry {
  static let name="sheet.binding"
  static func make(_ source:ResolvedSheetAssembly)throws->MeshNode? {
    guard let binding=source.binding,binding.definition.style != .none else{return nil}
    let definition=binding.definition,r=definition.wireDiameterMM/2,t=source.stackThicknessMM
    let root=MeshNode();root.name=name
    let material=MeshMaterial();material.name="Binding wire / brushed steel"
    material.diffuse.contents=NSColor(calibratedWhite:0.67,alpha:1)
    material.metalness.contents=0.94;material.roughness.contents=0.26
    let half=source.openingDegrees * .pi/360
    let inward=SIMD3<Double>(cos(half),sin(half),0)
    for (index,position) in binding.positionsMM.enumerated() {
      let crown:SIMD3<Double>,inner:SIMD3<Double>
      if definition.style == .sideStaple {
        crown = .init(definition.edgeInsetMM,t+r,position-source.size.y/2)
        inner = .init(definition.edgeInsetMM,-r,position-source.size.y/2)
      }else if source.openingDegrees==0 || source.activeSpread==0 {
        crown = .init(-r,t/2,position-source.size.y/2)
        inner = .init(binding.penetrationMM+r,t/2,position-source.size.y/2)
      }else if source.activeSpread==source.leaves.count {
        // All leaves turned is a rigid closed-block roll, including the wire.
        let angle=half*2,base=t*(1+cos(angle))/2
        crown = .init(-r*cos(angle)+t/2*sin(angle),base-r*sin(angle)-t/2*cos(angle),position-source.size.y/2)
        inner=crown+SIMD3<Double>(cos(angle),sin(angle),0)*(binding.penetrationMM+2*r)
      }else{
        let base=t*(1+cos(half*2))/2
        crown=SIMD3<Double>(0,base/2,position-source.size.y/2)-inward*r
        inner=crown+inward*(binding.penetrationMM+2*r)
      }
      let axis=SIMD3<Double>(0,0,1),a=definition.crownLengthMM/2,c=definition.clinchLengthMM
      let points=[inner-axis*(a-c),inner-axis*a,crown-axis*a,crown+axis*a,inner+axis*a,inner+axis*(a-c)]
      let mesh=try tube(points,radiusMM:r);mesh.materials=[material]
      let node=MeshNode(geometry:mesh);node.name="sheet.binding.fastener:\(index)";root.addChildNode(node)
    }
    return root
  }
  private static func tube(_ control:[SIMD3<Double>],radiusMM:Double)throws->MeshGeometry {
    guard control.count==6,radiusMM>0 else{throw FormError.invalid("A binding wire needs a finite bounded physical path.")}
    var points=[control[0]]
    for i in 1..<(control.count-1) {
      let before=control[i]-control[i-1],after=control[i+1]-control[i]
      let distance=min(radiusMM*1.4,min(simd_length(before),simd_length(after))*0.3)
      let a=control[i]-simd_normalize(before)*distance,b=control[i]+simd_normalize(after)*distance
      points.append(a)
      for step in 1...4 {let t=Double(step)/4;points.append(a*(1-t)*(1-t)+control[i]*(2*t*(1-t))+b*t*t)}
    }
    points.append(control.last!)
    let segments=12
    var vertices=[MeshVector3](),normals=[MeshVector3](),uv=[CGPoint](),indices=[UInt32]()
    for i in points.indices {
      let tangent=simd_normalize(points[min(i+1,points.count-1)]-points[max(0,i-1)])
      let guide=abs(tangent.x)<0.8 ? SIMD3<Double>(1,0,0):SIMD3<Double>(0,1,0)
      let u=simd_normalize(simd_cross(tangent,guide)),v=simd_cross(tangent,u)
      for side in 0..<segments {
        let angle=Double(side)*2 * .pi/Double(segments),normal=u*cos(angle)+v*sin(angle)
        let p=(points[i]+normal*radiusMM)/100
        vertices.append(.init(p));normals.append(.init(normal));uv.append(.init(x:Double(side)/Double(segments),y:Double(i)/Double(points.count-1)))
        if i>0 {
          let a=UInt32((i-1)*segments+side),b=UInt32((i-1)*segments+(side+1)%segments)
          let c=UInt32(i*segments+side),d=UInt32(i*segments+(side+1)%segments)
          indices += [a,b,c,b,d,c]
        }
      }
    }
    for (ring,reverse) in [(0,true),(points.count-1,false)] {
      let center=UInt32(vertices.count),p=points[ring]/100
      let tangent=simd_normalize(points[min(ring+1,points.count-1)]-points[max(0,ring-1)])*(reverse ? -1.0:1.0)
      vertices.append(.init(p));normals.append(.init(tangent));uv.append(.init(x:0.5,y:0.5))
      for side in 0..<segments {
        let a=UInt32(ring*segments+side),b=UInt32(ring*segments+(side+1)%segments)
        indices += reverse ? [center,b,a]:[center,a,b]
      }
    }
    guard vertices.count<1024,vertices.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}) else {
      throw FormError.invalid("Physical binding exceeded its bounded wire geometry.")
    }
    return MeshGeometry(sources:[.init(vertices:vertices),.init(normals:normals),.init(textureCoordinates:uv)],
      elements:[.init(indices:indices,primitiveType:.triangles)])
  }
}
