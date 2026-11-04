import AppKit
import FormCore
import FormGeometry
import FormGraphics
import simd

/// Caliper-aware, bounded physical wire geometry. No artwork or stock is copied.
@MainActor enum SheetBindingGeometry {
  static let name="sheet.binding"
  static func make(_ source:ResolvedSheetAssembly,leafRoot:MeshNode?=nil)throws->MeshNode? {
    if source.binding?.definition.style == .adhesive || source.binding?.definition.style == .sewn {
      return try gathered(source,leafRoot:leafRoot)
    }
    guard let binding=source.binding,binding.definition.style != .none else{return source.signatures.isEmpty ? nil:try gathered(source,leafRoot:leafRoot)}
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
    if !source.signatures.isEmpty,let folds=try gathered(source,leafRoot:leafRoot) {for node in Array(folds.childNodes){root.addChildNode(node)}}
    return root
  }
  /// Gather folds are actual caliper-bearing paper arcs. Stitches and adhesive
  /// remain separate materials rather than metallic fasteners renamed as thread.
  private static func gathered(_ source:ResolvedSheetAssembly,leafRoot:MeshNode?)throws->MeshNode? {
    let root=MeshNode();root.name=name
    var closedOffsets=[UUID:Double](),accumulated=0.0
    for leaf in source.leaves {closedOffsets[leaf.id]=source.stackThicknessMM-accumulated-leaf.stock.resolvedThicknessMM/2;accumulated+=leaf.stock.resolvedThicknessMM}
    let groups=source.signatures.isEmpty ? [source.parentSheets.map(\.id)]:source.signatures.map(\.parentSheetIDs)
    let thread=MeshMaterial();thread.name="Binding / sewn fiber";thread.diffuse.contents=NSColor(calibratedRed:0.82,green:0.78,blue:0.65,alpha:1);thread.roughness.contents=0.94
    var priorThread:[Double:SIMD3<Double>]=[:]
    for (groupIndex,parents) in groups.enumerated() {
      var outer:(center:Double,radius:Double,height:Double,pose:simd_double4x4)?
      for parent in parents {
        let pair=source.leaves.filter{$0.parentSheetID==parent}
        guard pair.count==2,let first=closedOffsets[pair[0].id],let second=closedOffsets[pair[1].id] else{continue}
        let radius=abs(first-second)/2,center=(first+second)/2,caliper=pair[0].stock.resolvedThicknessMM
        guard radius>=caliper/2-1e-10 else{continue}
        let pose=foldPose(pair,closedOffsets:closedOffsets,root:leafRoot)
        if outer==nil || radius>outer!.radius {outer=(center,radius,pair[0].size.y,pose)}
        let original=try foldRibbon(radius:radius,center:center,height:pair[0].size.y,thickness:caliper)
        let mesh=SheetPanelMeshTransform.apply(original,matrix:pose)
        let material=MeshMaterial();material.name="Paper / gathered fold";material.diffuse.contents=FormColor.color(pair[0].stock.profile?.color ?? "#F2EFE7")
        material.roughness.contents=pair[0].stock.profile?.roughness ?? 0.95;mesh.materials=[material]
        let node=MeshNode(geometry:mesh);node.name="sheet.signature.fold:"+parent.uuidString;root.addChildNode(node)
      }
      if source.binding?.definition.style == .sewn,let outer,let binding=source.binding {
        let r=binding.definition.wireDiameterMM/2
        let positions=try binding.definition.resolvedPositions(heightMM:outer.height)
        for (station,position) in positions.enumerated() {
          let z=position-outer.height/2,span=binding.definition.crownLengthMM/2
          let a=SIMD3<Double>(0,outer.center+outer.radius,z-span),b=SIMD3<Double>(-outer.radius-r,outer.center,z-span)
          let c=SIMD3<Double>(-outer.radius-r,outer.center,z+span),d=SIMD3<Double>(0,outer.center-outer.radius,z+span)
          func posed(_ p:SIMD3<Double>)->SIMD3<Double> {
            let v=outer.pose*SIMD4(p/100,1);return SIMD3(v.x,v.y,v.z)*100
          }
          var path=[a,b,c,d].map(posed)
          if let prior=priorThread[position] {path.insert(prior,at:0)}
          let mesh=try tube(path,radiusMM:r);mesh.materials=[thread]
          let node=MeshNode(geometry:mesh);node.name="sheet.binding.thread:\(groupIndex):\(station)";root.addChildNode(node)
          priorThread[position]=posed(c)
        }
      }
    }
    if let definition=source.binding?.definition,(definition.style == .adhesive || definition.style == .sewn),(definition.adhesiveMM ?? 0.2)>0 {
      let depth=definition.adhesiveMM ?? 0.2
      let mesh=MeshBox(width:depth/100,height:source.stackThicknessMM/100,length:source.trimHeight/100,chamferRadius:min(depth,0.05)/100)
      let material=MeshMaterial();material.name="Binding / flexible adhesive";material.diffuse.contents=NSColor(calibratedRed:0.74,green:0.70,blue:0.56,alpha:1);material.roughness.contents=0.68;mesh.materials=[material]
      let node=MeshNode(geometry:mesh);node.name="sheet.binding.adhesive";node.position = .init(-depth/200,source.stackThicknessMM/200,0);root.addChildNode(node)
    }
    return root.childNodes.isEmpty ? nil:root
  }
  /// A fully turned parent retains its neutral endpoint separation. Follow
  /// those actual leaf anchors with one rigid transform, preserving paper
  /// caliper and neutral length. A parent split by the viewing spread remains
  /// an idealized closed gathering; its page-opening roots do not define a
  /// length-preserving physical fold, so never stretch a ribbon to bridge it.
  private static func foldPose(_ pair:[ResolvedSheetAssemblyLeaf],closedOffsets:[UUID:Double],root:MeshNode?)->simd_double4x4 {
    guard pair.count==2,pair[0].turned==pair[1].turned,let root,
      let a=root.childNode(withName:SheetAssemblyGeometry.leafName(pair[0].id),recursively:true),
      let b=root.childNode(withName:SheetAssemblyGeometry.leafName(pair[1].id),recursively:true),
      let oldA=closedOffsets[pair[0].id],let oldB=closedOffsets[pair[1].id] else{return matrix_identity_double4x4}
    func anchor(_ node:MeshNode,_ height:Double)->SIMD3<Double> {
      let v=(root.worldTransform.raw.inverse*node.worldTransform.raw)*SIMD4<Double>(0,-height/200,0,1)
      return SIMD3(v.x,v.y,v.z)
    }
    let actualA=anchor(a,pair[0].size.y),actualB=anchor(b,pair[1].size.y),delta=actualA-actualB
    let separation=(oldA-oldB)/100
    guard abs(separation)>1e-12,abs(simd_length(delta)-abs(separation))<1e-8,abs(delta.z)<1e-8 else{return matrix_identity_double4x4}
    let angle=atan2(-delta.x/separation,delta.y/separation),pose=MeshNode()
    pose.eulerAngles = .init(0,0,angle)
    let old=pose.transform.raw*SIMD4<Double>(0,oldA/100,0,1)
    pose.position = .init(actualA-SIMD3(old.x,old.y,old.z))
    return pose.transform.raw
  }
  static func foldRibbon(radius:Double,center:Double,height:Double,thickness:Double)throws->MeshGeometry {
    guard radius>=thickness/2-1e-10,thickness>0,height>0 else{throw FormError.invalid("A gathered fold must retain its stock caliper and positive neutral radius.")}
    var vertices=[MeshVector3](),normals=[MeshVector3](),uv=[CGPoint](),indices=[UInt32]()
    func point(_ angle:Double,_ r:Double,_ z:Double)->SIMD3<Double>{.init(-r*sin(angle),center+r*cos(angle),z)}
    func quad(_ a:SIMD3<Double>,_ b:SIMD3<Double>,_ c:SIMD3<Double>,_ d:SIMD3<Double>) {
      let first=simd_cross(b-a,c-a),second=simd_cross(c-a,d-a)
      let validFirst=simd_length_squared(first)>1e-24,validSecond=simd_length_squared(second)>1e-24
      guard validFirst || validSecond else{return}
      let normal=simd_normalize(validFirst ? first:second),start=UInt32(vertices.count)
      for (p,t) in [(a,CGPoint(x:0,y:0)),(b,.init(x:1,y:0)),(c,.init(x:1,y:1)),(d,.init(x:0,y:1))] {vertices.append(.init(p/100));normals.append(.init(normal));uv.append(t)}
      if validFirst {indices += [start,start+1,start+2]};if validSecond {indices += [start,start+2,start+3]}
    }
    let inner=max(0,radius-thickness/2),outer=radius+thickness/2,z=height/2
    for i in 0..<32 {
      let a=Double(i)*Double.pi/32,b=Double(i+1)*Double.pi/32
      quad(point(a,outer,-z),point(b,outer,-z),point(b,outer,z),point(a,outer,z))
      quad(point(a,inner,z),point(b,inner,z),point(b,inner,-z),point(a,inner,-z))
      quad(point(a,inner,-z),point(b,inner,-z),point(b,outer,-z),point(a,outer,-z))
      quad(point(a,outer,z),point(b,outer,z),point(b,inner,z),point(a,inner,z))
    }
    quad(point(0,inner,-z),point(0,outer,-z),point(0,outer,z),point(0,inner,z))
    quad(point(.pi,inner,z),point(.pi,outer,z),point(.pi,outer,-z),point(.pi,inner,-z))
    return MeshGeometry(sources:[.init(vertices:vertices),.init(normals:normals),.init(textureCoordinates:uv)],elements:[.init(indices:indices,primitiveType:.triangles)])
  }
  static func tube(_ control:[SIMD3<Double>],radiusMM:Double)throws->MeshGeometry {
    guard (2...32).contains(control.count),control.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}),radiusMM>0,radiusMM.isFinite else{throw FormError.invalid("A binding wire needs a finite bounded physical path.")}
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
    guard vertices.count<8192,vertices.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.z.isFinite}) else {
      throw FormError.invalid("Physical binding exceeded its bounded wire geometry.")
    }
    return MeshGeometry(sources:[.init(vertices:vertices),.init(normals:normals),.init(textureCoordinates:uv)],
      elements:[.init(indices:indices,primitiveType:.triangles)])
  }
}
