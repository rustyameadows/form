import AppKit
import FormCore
import FormGeometry
import simd
import CryptoKit

/// General project-defined implicit construction. Every consumer obtains the
/// same indexed surface; object names and recipe IDs have no special meaning.
@MainActor enum SolidRecipeGeometry {
  private final class Surface:NSObject {
    let positions:[SIMD3<Double>],indices:[UInt32]
    init(_ p:[SIMD3<Double>],_ i:[UInt32]){positions=p;indices=i}
  }
  private static let cache:NSCache<NSString,Surface> = {let c=NSCache<NSString,Surface>();c.totalCostLimit=96_000_000;c.countLimit=12;return c}()
  static func surface(_ definition:ParametricSolid,parameters:[String:Double])throws->(positions:[SIMD3<Double>],indices:[UInt32]) {
    var signature=try JSONEncoder.form.encode(definition);signature.append(try JSONEncoder.form.encode(parameters))
    let key=SHA256.hash(data:signature).map{String(format:"%02x",$0)}.joined() as NSString
    if let cached=cache.object(forKey:key){return(cached.positions,cached.indices)}
    let construction=try definition.evaluate(parameters);var solid=OrganicSolid()
    for primitive in construction.primitives {
      let v=primitive.values,center=SIMD3(v["x"]!,v["y"]!,v["z"]!)
      if primitive.kind=="segment" {
        solid.segment(center,.init(v["endX"]!,v["endY"]!,v["endZ"]!),v["radius"]!,v["endRadius"]!,aspect:v["aspect"] ?? 1,endAspect:v["endAspect"] ?? 1,roll:v["roll"] ?? 0,blend:v["blend"] ?? 0)
      }else{
        solid.ellipsoid(center,radii:.init(v["radiusX"]!,v["radiusY"]!,v["radiusZ"]!),axis:.init(v["axisX"] ?? 0,v["axisY"] ?? 1,v["axisZ"] ?? 0),roll:v["roll"] ?? 0,blend:v["blend"] ?? 0)
      }
    }
    var mesh=try solid.mesh(spacing:construction.spacing,floorY:construction.floorY,fillVoids:construction.fillVoids)
    if let height=construction.normalizeHeight {
      let low=mesh.positions.map(\.y).min()!,high=mesh.positions.map(\.y).max()!,scale=height/(high-low)
      mesh.positions=mesh.positions.map{.init($0.x*scale,($0.y-low)*scale,$0.z*scale)}
    }
    cache.setObject(Surface(mesh.positions,mesh.indices),forKey:key,cost:mesh.positions.count*24+mesh.indices.count*4)
    return mesh
  }
  static func make(_ object:ProductObject,definition:ParametricSolid,project:Project)throws->MeshNode {
    let mesh=try surface(definition,parameters:object.parameters)
    let root=MeshNode();root.name="solid.construction"
    var normals=Array(repeating:SIMD3<Double>.zero,count:mesh.positions.count)
    for i in stride(from:0,to:mesh.indices.count,by:3) {
      let a=Int(mesh.indices[i]),b=Int(mesh.indices[i+1]),c=Int(mesh.indices[i+2]),n=simd_cross(mesh.positions[b]-mesh.positions[a],mesh.positions[c]-mesh.positions[a]);normals[a]+=n;normals[b]+=n;normals[c]+=n
    }
    let ns=normals.map{simd_length_squared($0)>1e-24 ? simd_normalize($0):SIMD3<Double>(0,1,0)},material=GeometryFactory.material(object,project:project)
    for offset in stride(from:0,to:mesh.indices.count,by:600_000) {
      let end=min(offset+600_000,mesh.indices.count),ids=Array(mesh.indices[offset..<end]);var map:[UInt32:Int32]=[:],p:[MeshVector3]=[],n:[MeshVector3]=[],indices:[Int32]=[]
      for id in ids {if let local=map[id]{indices.append(local)}else{let local=Int32(p.count);map[id]=local;p.append(.init(mesh.positions[Int(id)]/100));n.append(.init(ns[Int(id)]));indices.append(local)}}
      let geometry=MeshGeometry(sources:[.init(vertices:p),.init(normals:n)],elements:[.init(indices:indices,primitiveType:.triangles)])
      let node=GeometryFactory.solid(geometry,material);node.name="solid.surface.\(offset/600_000)";root.addChildNode(node)
    }
    return root
  }
}
