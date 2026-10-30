import AppKit
import FormGeometry
import LabRendering
import simd

/// Compatibility boundary for procedural recipes. Only this adapter knows that
/// their construction graph still uses 100 mm units; the renderer only sees mm.
@MainActor final class GeometryPayloadAdapter {
  struct Hit {var node:MeshNode;var geometryIndex:Int;var worldCoordinates:MeshVector3;var objectID:UUID}
  private struct Cached {var revision:String;var payload:SceneMeshPayload}
  private var meshes:[String:Cached]=[:]
  private(set) var nodes:[String:MeshNode]=[:]
  private(set) var warnings:[String]=[]
  private let guideID=UUID()
  private let fallbackMaterial=MeshMaterial()
  func clear(){meshes.removeAll();nodes.removeAll();warnings=[]}
  func renderables(scene:MeshScene)->[SceneRenderablePayload] {
    nodes=[:];warnings=[];var output=[SceneRenderablePayload](),used=Set<String>()
    func walk(_ node:MeshNode,path:String,owner:UUID?,hidden:Bool,opacity:Double) {
      var owner=owner,path=path
      if let name=node.name,name.hasPrefix("object:"),let id=UUID(uuidString:String(name.dropFirst(7))) {owner=id;path="object:"+id.uuidString}
      let hidden=hidden || node.isHidden,opacity=opacity*node.opacity
      if let geometry=node.geometry {
        geometry.prepare();let identity=geometry.resourceID.uuidString,physicalID=Self.paperPhysicalID(geometry),key=physicalID ?? "identity:\(identity)";used.insert(key)
        let materials=geometry.materials.isEmpty ? [fallbackMaterial]:geometry.materials
        let uvRevision=materials.map{Self.meshUVRevision($0)}.joined(separator:";")
        let revision="\(geometry.resourceRevision):\(uvRevision)"
        let mesh:SceneMeshPayload
        if let cached=meshes[key],cached.revision==revision {mesh=cached.payload}
        else {mesh=Self.mesh(geometry,id:physicalID ?? "recipe:\(identity)",revision:revision,materials:materials);meshes[key] = .init(revision:revision,payload:mesh)}
        if !mesh.positionsMM.isEmpty,!mesh.parts.isEmpty {
          let component="graph/"+path;nodes[component]=node
          let transform=Self.transform(node.worldTransform.raw)
          output.append(.init(componentID:component,objectID:owner ?? guideID,mesh:mesh,
            materials:materials.map{Self.material($0,opacity:opacity)},transform:transform,visible:!hidden,
            pickable:owner != nil && node.categoryBitMask & 2 != 0))
          for material in materials {
            let mapped=[material.diffuse,material.normal,material.roughness,material.metalness,material.emission].filter{Self.hasImage($0.contents)}
            if let first=mapped.first,mapped.dropFirst().contains(where:{$0.contentsTransform.raw != first.contentsTransform.raw}) {warnings.append("Different texture channel UV transforms on \(component) cannot share procedural UV0; incompatible channel textures are omitted while source mappings remain unchanged.")}
          }
        }
      }
      var occurrences:[String:Int]=[:]
      for (i,child) in node.childNodes.enumerated(){
        let key:String
        if let name=child.name {
          let occurrence=occurrences[name,default:0];occurrences[name]=occurrence+1
          key=name+(occurrence==0 ? "":"#\(occurrence)")
        } else {key="node:\(i)"}
        walk(child,path:path+"/"+key,owner:owner,hidden:hidden,opacity:opacity)
      }
    }
    walk(scene.rootNode,path:"root",owner:nil,hidden:false,opacity:1)
    meshes=meshes.filter{used.contains($0.key)};return output
  }
  /// Reserved for PaperGeometry's content-addressed immutable buffer templates.
  /// Mutated buffers and all other recipe names retain ordinary identity caching.
  private static func paperPhysicalID(_ geometry:MeshGeometry)->String? {
    guard geometry.resourceRevision==0,let name=geometry.name,name.hasPrefix("paper.mesh:"),name.utf8.count==75,
      name.utf8.dropFirst(11).allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else{return nil}
    return name
  }
  private static func uvRevision(_ material:MeshMaterial)->String {
    [material.diffuse,material.normal,material.roughness,material.metalness,material.emission].map{"\($0.resourceID):\($0.resourceRevision):\($0.intensity):\($0.wrapS):\($0.wrapT)"}.joined(separator:",")
  }
  private static func meshUVRevision(_ material:MeshMaterial)->String {
    let primary=[material.diffuse,material.normal,material.roughness,material.metalness,material.emission].first{hasImage($0.contents)}
    let m=primary?.contentsTransform.raw ?? matrix_identity_double4x4
    return (0..<4).flatMap{column in (0..<4).map{String(m[column,$0])}}.joined(separator:",")
  }
  private static func transform(_ matrix:simd_double4x4)->SceneTransformPayload {
    let x=SIMD3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z),y=SIMD3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z),z=SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z)
    var scale=SIMD3(simd_length(x),simd_length(y),simd_length(z));if simd_dot(simd_cross(x,y),z)<0 {scale.z = -scale.z}
    let rotation=simd_quatd(simd_double3x3(columns:(x/max(1e-12,scale.x),y/max(1e-12,scale.y),z/(abs(scale.z)>1e-12 ? scale.z:1))))
    return .init(translationMM:SIMD3(matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z)*100,rotationXYZW:rotation.vector,scale:scale)
  }
  private static func mesh(_ geometry:MeshGeometry,id:String,revision:String,materials:[MeshMaterial])->SceneMeshPayload {
    let vertices=geometry.sources(for:.vertex).first?.vectors.map{$0.simd*100} ?? []
    let normals=geometry.sources(for:.normal).first?.vectors.map{SIMD3<Float>($0.simd)} ?? []
    let uv=geometry.sources(for:.texcoord).first?.points ?? []
    var positions=[SIMD3<Double>](),ns=[SIMD3<Float>](),uvs=[SIMD2<Float>](),parts=[SceneMeshPart]()
    for (partIndex,element) in geometry.elements.enumerated() {
      let slot=partIndex % materials.count,material=materials[slot],indices=element.indices
      let mapped=[material.diffuse,material.normal,material.roughness,material.metalness,material.emission].first{hasImage($0.contents)}
      let matrix=mapped?.contentsTransform.raw ?? matrix_identity_double4x4
      var triangles=[UInt32]()
      func append(_ index:UInt32) {
        guard Int(index)<vertices.count else{return};let i=Int(index)
        triangles.append(UInt32(positions.count));positions.append(vertices[i])
        if normals.count==vertices.count {ns.append(normals[i])}
        if uv.count==vertices.count {let q=matrix*SIMD4(Double(uv[i].x),Double(uv[i].y),0,1);uvs.append(.init(Float(q.x),Float(q.y)))}
      }
      switch element.primitiveType {
      case .triangles:
        for start in stride(from:0,to:indices.count-2,by:3) where indices[start..<start+3].allSatisfy({Int($0)<vertices.count}) {for index in indices[start..<start+3] {append(index)}}
      case .triangleStrip:
        if indices.count>=3 {for i in 0..<indices.count-2 {let t=i%2==0 ? [indices[i],indices[i+1],indices[i+2]]:[indices[i+1],indices[i],indices[i+2]];if t.allSatisfy({Int($0)<vertices.count}) {for index in t{append(index)}}}}
      case .line:
        // Thin square tubes preserve true 3D depth and all line consumers:
        // table grid, selection bounds, bed grids and sliced toolpaths.
        if indices.count>=2 {for i in stride(from:0,to:indices.count-1,by:2) where Int(indices[i])<vertices.count && Int(indices[i+1])<vertices.count {
          let a=vertices[Int(indices[i])],b=vertices[Int(indices[i+1])],d=b-a
          guard simd_length_squared(d)>1e-16 else{continue}
          let direction=simd_normalize(d),basis=abs(direction.y)<0.9 ? SIMD3<Double>(0,1,0):SIMD3<Double>(1,0,0)
          let radius=0.16,x=simd_normalize(simd_cross(direction,basis))*radius,y=simd_normalize(simd_cross(direction,x))*radius
          let box=[a-x-y,a+x-y,a+x+y,a-x+y,b-x-y,b+x-y,b+x+y,b-x+y]
          let ix=[0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,1,2,6,1,6,5,2,3,7,2,7,6,3,0,4,3,4,7]
          let base=UInt32(positions.count);positions += box;triangles += ix.map{base+UInt32($0)}
        }}
      case .point:break
      }
      if !triangles.isEmpty {parts.append(.init(materialIndex:slot,triangleIndices:triangles,semanticID:"element:\(partIndex)"))}
    }
    return .init(id:id,revision:revision,positionsMM:positions,normals:ns.count==positions.count ? ns:[],uvs:uvs.count==positions.count ? uvs:[],parts:parts)
  }
  private final class ImageBox:NSObject {let image:CGImage;init(_ image:CGImage){self.image=image}}
  private static let imageCache=NSCache<NSString,ImageBox>()
  private static func hasImage(_ value:Any?)->Bool {value is NSImage || value is URL || (value.map{CFGetTypeID($0 as AnyObject)==CGImage.typeID} ?? false)}
  private static func image(_ contents:Any?)->CGImage? {
    if let value=contents,CFGetTypeID(value as AnyObject)==CGImage.typeID{return (value as! CGImage)}
    if let image=contents as? NSImage{return image.cgImage(forProposedRect:nil,context:nil,hints:nil)}
    if let url=contents as? URL,let image=NSImage(contentsOf:url){return image.cgImage(forProposedRect:nil,context:nil,hints:nil)}
    return nil
  }
  static func color(_ value:Any?,fallback:NSColor = .white)->SIMD4<Float> {
    let c=((value as? NSColor) ?? fallback).usingColorSpace(.sRGB) ?? fallback
    return .init(Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),Float(c.alphaComponent))
  }
  private static func texture(_ p:MeshMaterialProperty)->SceneTexturePayload? {
    let key="\(p.resourceID):\(p.resourceRevision)" as NSString
    let cached=imageCache.object(forKey:key)?.image
    guard let image=cached ?? image(p.contents) else{return nil}
    if cached == nil {imageCache.totalCostLimit=128*1024*1024;imageCache.setObject(ImageBox(image),forKey:key,cost:image.bytesPerRow*image.height)}
    func wrap(_ value:MeshWrapMode)->SceneTextureWrap{switch value{case .clamp:return .clamp;case .repeat:return .repeatMode;case .mirror:return .mirror}}
    return .init(image:image,revision:"\(p.resourceID):\(p.resourceRevision)",wrapS:wrap(p.wrapS),wrapT:wrap(p.wrapT))
  }
  private static func material(_ m:MeshMaterial,opacity:Double)->SceneMaterialPayload {
    let id="recipe-material:\(ObjectIdentifier(m))"
    let rev=uvRevision(m)+":\(m.transparency):\(opacity):\(m.isDoubleSided):\(m.readsFromDepthBuffer):\(m.writesToDepthBuffer):\(m.lightingModel)"
    var color=color(m.diffuse.contents);color.w *= Float(m.transparency*opacity)
    let primary=[m.diffuse,m.normal,m.roughness,m.metalness,m.emission].first{hasImage($0.contents)}
    func mappedTexture(_ property:MeshMaterialProperty)->SceneTexturePayload? {
      if let primary,hasImage(property.contents),property.contentsTransform.raw != primary.contentsTransform.raw {return nil}
      return texture(property)
    }
    let emissive=Self.color(m.emission.contents,fallback:.black),diffuseTexture=mappedTexture(m.diffuse)
    var payload=SceneMaterialPayload(id:id,revision:rev,baseColor:color)
    payload.colorEncoding = .srgb
    payload.emissiveColor = .init(emissive.x,emissive.y,emissive.z)
    payload.emissiveIntensity=Float(m.emission.intensity);payload.emissiveTexture=mappedTexture(m.emission)
    let metallicTexture=mappedTexture(m.metalness),roughnessTexture=mappedTexture(m.roughness)
    // A texture already contains its scalar coverage. Multiplying metallic by
    // the scalar fallback zero silently erased every procedural foil mask.
    payload.metallic=Float((m.metalness.contents as? NSNumber)?.doubleValue ?? (metallicTexture == nil ? 0:m.metalness.intensity))
    payload.roughness=Float((m.roughness.contents as? NSNumber)?.doubleValue ?? (roughnessTexture == nil ? 0.6:m.roughness.intensity))
    payload.doubleSided=m.isDoubleSided;payload.readsDepth=m.readsFromDepthBuffer;payload.writesDepth=m.writesToDepthBuffer
    let textureHasAlpha=diffuseTexture.map{![CGImageAlphaInfo.none,.noneSkipFirst,.noneSkipLast].contains($0.image.alphaInfo)} ?? false
    payload.unlit=m.lightingModel == .constant;payload.alphaMode=color.w<0.999 || textureHasAlpha ? .blend:.opaque
    payload.normalScale=Float(m.normal.intensity);payload.baseColorTexture=diffuseTexture;payload.normalTexture=mappedTexture(m.normal)
    payload.metallicTexture=metallicTexture;payload.roughnessTexture=roughnessTexture
    return payload
  }
}
