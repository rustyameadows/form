import AppKit
import CryptoKit
import FormCore
import FormGeometry

/// Derived final-view displacement. The physical stock mesh, process masks and
/// manufacturing outputs remain independent of this finite display budget.
/// The high-resolution normal map provides finish slopes and substrate tooth;
/// planar cap normals here avoid applying those slopes twice.
@MainActor enum PaperReliefGeometry {
  nonisolated static let maximumTrianglesPerFace = 24_000
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
    let signature="v1:\(base.name ?? ""):\(front.reliefRevision ?? "none"):\(back.reliefRevision ?? "none"):\(triangleBudget):\(thicknessMM)"
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
      let map=maps[side],source=base.elements[side].indices,originalCount=source.count/3
      guard originalCount>0,originalCount<=triangleBudget else{continue}
      let affordable=max(1,Int(sqrt(Double(triangleBudget)/Double(originalCount))))
      let requested=max(2,Int(ceil(Double(max(map.width,map.height))/12)))
      let divisions=min(128,min(affordable,requested))
      var output=[UInt32](),shared=[String:UInt32]()
      output.reserveCapacity(originalCount*divisions*divisions*3)
      func vertex(_ point:MeshVector3,_ uv:CGPoint)->UInt32 {
        let key="\(Int64((point.x*1e10).rounded())):\(Int64((point.y*1e10).rounded()))"
        if let index=shared[key]{return index}
        let physical=Point2(point.x*100,-point.y*100)
        let clearance=edges.map{distance(physical,$0.0,$0.1)}.min() ?? 0
        let taper=max(0,min(1,(clearance-guardMM)/0.12))
        let raw=sample(map,at:physical)
        // Opposing impressions cannot make the displayed sheet invert. Raised
        // deposited ink/emboss intent does not consume the stock's caliper.
        let height=max(-thicknessMM*0.45,raw)*taper
        let index=UInt32(positions.count),sign=side==0 ? 1.0:-1.0
        positions.append(.init(point.x,point.y,point.z+sign*height/100))
        normals.append(.init(0,0,sign));coordinates.append(uv);shared[key]=index
        return index
      }
      for offset in stride(from:0,to:source.count,by:3) {
        let ids=(0..<3).map{Int(source[offset+$0])}
        guard ids.allSatisfy({originalPositions.indices.contains($0)}) else {
          throw FormError.invalid("Paper relief found an invalid cap index.")
        }
        let a=originalPositions[ids[0]],b=originalPositions[ids[1]],c=originalPositions[ids[2]]
        let auv=originalCoordinates[ids[0]],buv=originalCoordinates[ids[1]],cuv=originalCoordinates[ids[2]]
        var grid=[[UInt32]]()
        for i in 0...divisions {
          var row=[UInt32]()
          for j in 0...(divisions-i) {
            let u=Double(i)/Double(divisions),v=Double(j)/Double(divisions),w=1-u-v
            row.append(vertex(.init(a.x*w+b.x*u+c.x*v,a.y*w+b.y*u+c.y*v,a.z*w+b.z*u+c.z*v),
              .init(x:auv.x*w+buv.x*u+cuv.x*v,y:auv.y*w+buv.y*u+cuv.y*v)))
          }
          grid.append(row)
        }
        for i in 0..<divisions {for j in 0..<(divisions-i) {
          output += [grid[i][j],grid[i+1][j],grid[i][j+1]]
          if i+j<divisions-1 {output += [grid[i+1][j],grid[i+1][j+1],grid[i][j+1]]}
        }}
      }
      elements[side]=MeshGeometryElement(indices:output,primitiveType:.triangles)
    }
    // Complex caps that already exhaust the display budget keep their physical
    // mesh and high-resolution shading. Do not label an unchanged mesh relief.
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
