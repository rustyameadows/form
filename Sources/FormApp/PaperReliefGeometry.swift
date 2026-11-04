import AppKit
import CryptoKit
import FormCore
import FormGeometry

/// Derived final-view displacement. The physical stock mesh, process masks and
/// manufacturing outputs remain independent of this finite display budget.
/// The high-resolution normal map provides finish slopes and substrate tooth;
/// planar cap normals here avoid applying those slopes twice.
@MainActor enum PaperReliefGeometry {
  nonisolated static let maximumTrianglesPerFace = 200_000
  private final class Template: NSObject {
    let sources: [MeshGeometrySource], elements: [MeshGeometryElement], name: String
    var cost: Int { sources.reduce(0){$0+$1.data.count}+elements.reduce(0){$0+$1.data.count} }
    init(_ mesh: MeshGeometry, name: String) {sources=mesh.sources;elements=mesh.elements;self.name=name}
    func instance() -> MeshGeometry {
      let mesh=MeshGeometry(sources:sources,elements:elements);mesh.name=name;return mesh
    }
  }
  private static let cache: NSCache<NSString,Template> = {
    let value=NSCache<NSString,Template>();value.countLimit=32;value.totalCostLimit=64*1024*1024;return value
  }()
  private(set) static var builds = 0

  static func make(base: MeshGeometry, front: PaperSurfaceRasterizer.Maps,
    back: PaperSurfaceRasterizer.Maps, panel: PaperPanel, thicknessMM: Double,
    triangleBudget: Int = maximumTrianglesPerFace) throws -> MeshGeometry {
    guard thicknessMM.isFinite,thicknessMM>0,(1...maximumTrianglesPerFace).contains(triangleBudget) else {
      throw FormError.invalid("Paper relief requires positive stock and a bounded display mesh budget.")
    }
    let maps=[front,back]
    for map in maps {
      if let field=map.finishReliefMM {
        guard field.count==map.width*map.height,field.allSatisfy({$0.isFinite}) else {
          throw FormError.invalid("Paper relief requires a finite registered finish field.")
        }
      }
    }
    let active=maps.map{$0.finishReliefMM?.contains(where:{abs($0)>0.0000001}) == true}
    guard active.contains(true) else{return base}
    let signature="v2:\(base.name ?? ""):\(front.reliefRevision ?? "none"):\(back.reliefRevision ?? "none"):\(triangleBudget):\(thicknessMM)"
    let name="paper.relief.render:"+SHA256.hash(data:Data(signature.utf8)).map{String(format:"%02x",$0)}.joined()
    if let entry=cache.object(forKey:name as NSString){return entry.instance()}
    var positions=base.sources(for:.vertex).first?.vectors ?? []
    var normals=base.sources(for:.normal).first?.vectors ?? []
    var coordinates=base.sources(for:.texcoord).first?.points ?? []
    guard !positions.isEmpty,normals.count==positions.count,coordinates.count==positions.count,base.elements.count>=2 else {
      throw FormError.invalid("Paper relief requires registered cap geometry and matching source buffers.")
    }
    let originalPositions=positions,originalCoordinates=coordinates
    var elements=base.elements
    let edges=([panel.polygon]+(panel.cutouts ?? []).map(\.polygon)).flatMap { ring in
      ring.indices.map{(ring[$0],ring[($0+1)%ring.count])}
    }
    // Existing single-ply caps stop at a small bevel. Keep displacement zero at
    // that seam so the unchanged cut walls and bonded ply edges stay closed.
    let guardMM=min(thicknessMM*0.22,0.06)+0.005
    func distance(_ point:Point2,_ a:Point2,_ b:Point2)->Double {
      let dx=b.x-a.x,dy=b.y-a.y,denominator=dx*dx+dy*dy
      let t=denominator>0 ? max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/denominator)):0
      return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy)
    }
    for side in 0..<2 where active[side] {
      let map=maps[side],source=base.elements[side].indices
      guard !source.isEmpty,let values=map.finishReliefMM else{continue}
      let field=PaperReliefTessellator.Field(width:map.width,height:map.height,
        origin:.init(map.rectMM.x,map.rectMM.y),size:.init(map.rectMM.width,map.rectMM.height),values:values)
      func height(_ point:SIMD2<Double>)->Double {
        let physical=Point2(point.x,point.y)
        var clearance=Double.infinity
        for edge in edges {clearance=min(clearance,distance(physical,edge.0,edge.1))}
        let taper=max(0,min(1,(clearance-guardMM)/0.12))
        // Opposing impressions cannot consume the full stock caliper.
        return max(-thicknessMM*0.45,sample(map,at:physical))*taper
      }
      var initial=[PaperReliefTessellator.Vertex](),indices=[UInt32](),mapping=[UInt32:UInt32]()
      for id in source {
        guard originalPositions.indices.contains(Int(id)) else {
          throw FormError.invalid("Paper relief found an invalid cap index.")
        }
        if let mapped=mapping[id] {indices.append(mapped);continue}
        let point=originalPositions[Int(id)],uv=originalCoordinates[Int(id)]
        let physical=SIMD2(point.x*100,-point.y*100),mapped=UInt32(initial.count)
        initial.append(.init(point:physical,uv:.init(uv.x,uv.y),baseZ:point.z,height:height(physical)))
        mapping[id]=mapped;indices.append(mapped)
      }
      let refined=try PaperReliefTessellator.make(vertices:initial,indices:indices,field:field,
        triangleBudget:triangleBudget,sample:height)
      let offset=UInt32(positions.count),sign=side==0 ? 1.0:-1.0
      for vertex in refined.vertices {
        positions.append(.init(vertex.point.x/100,-vertex.point.y/100,vertex.baseZ+sign*vertex.height/100))
        normals.append(.init(0,0,sign));coordinates.append(.init(x:vertex.uv.x,y:vertex.uv.y))
      }
      elements[side]=MeshGeometryElement(indices:refined.indices.map{$0+offset},primitiveType:.triangles)
    }
    // Zero-relief faces retain their source buffers and material slots exactly.
    guard positions.count>originalPositions.count else{return base}
    let mesh=MeshGeometry(sources:[.init(vertices:positions),.init(normals:normals),.init(textureCoordinates:coordinates)],elements:elements)
    let template=Template(mesh,name:name);builds+=1
    if template.cost<=cache.totalCostLimit{cache.setObject(template,forKey:name as NSString,cost:template.cost)}
    return template.instance()
  }

  static func sample(_ maps:PaperSurfaceRasterizer.Maps,at point:Point2)->Double {
    guard let field=maps.finishReliefMM,!field.isEmpty,
      point.x>=maps.rectMM.x,point.y>=maps.rectMM.y,
      point.x<=maps.rectMM.x+maps.rectMM.width,point.y<=maps.rectMM.y+maps.rectMM.height else{return 0}
    let x=max(0,min(Double(maps.width-1),(point.x-maps.rectMM.x)/maps.rectMM.width*Double(maps.width)-0.5))
    let y=max(0,min(Double(maps.height-1),(point.y-maps.rectMM.y)/maps.rectMM.height*Double(maps.height)-0.5))
    let x0=Int(floor(x)),y0=Int(floor(y)),x1=min(maps.width-1,x0+1),y1=min(maps.height-1,y0+1)
    let u=x-Double(x0),v=y-Double(y0)
    return Double(field[y0*maps.width+x0])*(1-u)*(1-v)+Double(field[y0*maps.width+x1])*u*(1-v)
      + Double(field[y1*maps.width+x0])*(1-u)*v+Double(field[y1*maps.width+x1])*u*v
  }
}
