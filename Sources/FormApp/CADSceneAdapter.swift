import Foundation
import CryptoKit
import FormCore
import FormCADKernel
import FormCADModel
import FormCADModeling
import LabRendering
import simd

/// Exact body coordinates remain unchanged; only ProductObject occurrence placement is applied.
enum CADSceneAdapter {
  struct Prepared:Sendable {
    var renderables:[SceneRenderablePayload]
    var triangleFaces:[String:[UInt32]]
    var materialColors:[String:[SIMD4<Float>?]]
    var approximateBytes:Int
    var surfaceSlots:[String:[Int:String]]=[:]
  }
  nonisolated static func load(for object:ProductObject,assets:URL,materials:[FormCore.Material]=FormCore.Material.presets)throws->[SceneRenderablePayload] {let prepared=try prepare(for:object,assets:assets);return renderables(prepared,for:object,materials:materials)}
  nonisolated static func prepare(for object:ProductObject,assets:URL)throws->Prepared {
    guard let model=object.cadModel,let representation=object.cadRepresentation else{throw FormError.invalid("The exact CAD source or representation is missing.")}
    try representation.validate(for:model)
    var meshes:[UUID:CADMesh]=[:]
    for component in representation.components {
      try Task.checkCancellation()
      _ = try verifiedAsset(component.brepAsset,sha256:component.brepSHA256,assets:assets,maximumBytes:256*1024*1024)
      let data=try verifiedAsset(component.meshAsset,sha256:component.meshSHA256,assets:assets,maximumBytes:256*1024*1024)
      meshes[component.id]=try CADMeshArchive.decode(data)
    }
    return try prepare(for:object,meshes:meshes)
  }
  /// Review geometry is already verified by the exact evaluator. Reuse the
  /// display conversion without serializing exact bodies merely to preview.
  nonisolated static func prepare(for object:ProductObject,meshes:[UUID:CADMesh])throws->Prepared {
    guard let model=object.cadModel,let representation=object.cadRepresentation else{throw FormError.invalid("The exact CAD source or representation is missing.")}
    try representation.validate(for:model)
    var renderables:[SceneRenderablePayload]=[],maps:[String:[UInt32]]=[:],slots:[String:[SIMD4<Float>?]]=[:],surfaceSlots:[String:[Int:String]]=[:],cost=0
    for component in representation.components {
      try Task.checkCancellation()
      guard let mesh=meshes[component.id] else{throw FormError.invalid("The evaluated CAD display mesh is missing.")}
      guard mesh.positions.count<=2_000_000,mesh.indices.count/3==component.triangleCount else{throw FormError.invalid("The CAD display mesh exceeds the renderer vertex limit or disagrees with the exact source metadata. Regenerate at a coarser display tolerance.")}
      let id="cad:\(object.id.uuidString):\(component.id.uuidString)"
      let source=model.importedAssemblies?.flatMap(\.nodes).first{$0.outputFeatureID==component.id}
      if let source,!source.faceColors.isEmpty{guard source.outputFingerprint==component.featureFingerprint else{throw FormError.invalid("Imported face colors belong to another exact topology revision. Review the source face mapping before applying these edits.")}}
      let colors=source?.faceColors ?? []
      guard colors.allSatisfy({$0.faceIndex<=component.faceCount}) else{throw FormError.invalid("Imported face color references an unavailable source face.")}
      var groupColors:[SIMD4<Float>?]=[nil],byColor:[SIMD4<Float>:Int]=[:],faceGroups:[UInt32:Int]=[:]
      for color in colors.sorted(by:{$0.faceIndex<$1.faceIndex}){let rgba=SIMD4<Float>(Float(color.linearRGBA[0]),Float(color.linearRGBA[1]),Float(color.linearRGBA[2]),Float(color.linearRGBA[3]));let group:Int;if let old=byColor[rgba]{group=old}else{group=groupColors.count;byColor[rgba]=group;groupColors.append(rgba)};faceGroups[color.faceIndex]=group}
      let surfaces=(representation.resolvedSurfaces ?? []).filter{$0.outputFeatureID==component.id}
      var surfacesByGroup:[Int:CADResolvedPlanarSurface]=[:],seenSurfaceFaces=Set<UInt32>()
      for surface in surfaces {
        guard seenSurfaceFaces.insert(surface.faceIndex).inserted else{throw FormError.invalid("Two named artwork surfaces select the same exact face. Choose separate physical faces or one shared artwork surface.")}
        let group=groupColors.count,sourceGroup=faceGroups[surface.faceIndex] ?? 0
        groupColors.append(groupColors[sourceGroup]);surfacesByGroup[group]=surface;faceGroups[surface.faceIndex]=group
      }
      guard groupColors.count<=256 else{throw FormError.invalid("STEP component exceeds 255 distinct face colors. Source metadata is preserved; reduce the display material groups explicitly.")}
      var indices=[[UInt32]](repeating:[],count:groupColors.count),faces=[[UInt32]](repeating:[],count:groupColors.count)
      for triangle in mesh.faceIndices.indices{let face=mesh.faceIndices[triangle],group=faceGroups[face] ?? 0;indices[group].append(contentsOf:mesh.indices[(triangle*3)..<(triangle*3+3)]);faces[group].append(face)}
      var positions=mesh.positions.map{SIMD3<Double>($0.x,$0.y,$0.z)},normals=mesh.normals.map{SIMD3<Float>(Float($0.x),Float($0.y),Float($0.z))},uvs=mesh.textureCoordinates.map{SIMD2<Float>(Float($0.x),Float(1-$0.y))}
      if !surfaces.isEmpty {
        struct VertexKey:Hashable{let original:UInt32,group:Int}
        var vertices:[VertexKey:UInt32]=[:],mappedPositions:[SIMD3<Double>]=[],mappedNormals:[SIMD3<Float>]=[],mappedUVs:[SIMD2<Float>]=[]
        for group in indices.indices {
          for position in indices[group].indices {
            let original=indices[group][position],key=VertexKey(original:original,group:surfacesByGroup[group]==nil ? -1:group)
            if let index=vertices[key]{indices[group][position]=index;continue}
            let index=UInt32(mappedPositions.count),point=positions[Int(original)]
            vertices[key]=index;indices[group][position]=index;mappedPositions.append(point)
            if !normals.isEmpty{mappedNormals.append(normals[Int(original)])}
            if let surface=surfacesByGroup[group] {
              let origin=SIMD3(surface.origin.x,surface.origin.y,surface.origin.z),u=SIMD3(surface.uAxis.x,surface.uAxis.y,surface.uAxis.z),v=SIMD3(surface.vAxis.x,surface.vAxis.y,surface.vAxis.z),offset=point-origin
              mappedUVs.append(.init(Float(simd_dot(offset,u)/surface.width),Float(simd_dot(offset,v)/surface.height)))
            }else{mappedUVs.append(uvs.isEmpty ? .zero:uvs[Int(original)])}
          }
        }
        positions=mappedPositions;normals=mappedNormals;uvs=mappedUVs
      }
      var parts:[SceneMeshPart]=[]
      for group in indices.indices where !indices[group].isEmpty{let part="\(component.id.uuidString):material:\(group)";parts.append(.init(materialIndex:group,triangleIndices:indices[group],semanticID:part));maps[id+"|"+part]=faces[group]}
      let surfaceRevision=surfaces.isEmpty ? "":digest(try canonicalData(surfaces))
      let revision=component.meshSHA256+":"+partitionDigest(indices)+":"+surfaceRevision
      let payload=SceneMeshPayload(id:id,revision:revision,positionsMM:positions,normals:normals,uvs:uvs,parts:parts)
      cost+=payload.approximateBytes+mesh.faceIndices.count*8
      guard cost<=256*1024*1024 else{throw FormError.invalid("The CAD display buffers exceed the 256 MiB interactive budget.")}
      let appearances=groupColors.enumerated().map{material(for:component,object:object,materials:FormCore.Material.presets,faceColor:$0.element,partColor:source?.linearRGBA,slot:$0.offset)}
      try payload.validate(materialCount:appearances.count)
      renderables.append(.init(componentID:id,objectID:object.id,mesh:payload,materials:appearances,transform:placement(object)))
      maps[id]=faces.flatMap{$0};slots[id]=groupColors;surfaceSlots[id]=surfacesByGroup.mapValues(\.id)
    }
    return .init(renderables:renderables,triangleFaces:maps,materialColors:slots,approximateBytes:cost,surfaceSlots:surfaceSlots)
  }
  nonisolated static func renderables(_ prepared:Prepared,for object:ProductObject,materials:[FormCore.Material]=FormCore.Material.presets)->[SceneRenderablePayload] {
    prepared.renderables.map{value in var value=value;value.transform=placement(object);if let component=object.cadRepresentation?.components.first(where:{value.componentID.hasSuffix($0.id.uuidString)}){let partColor=object.cadModel?.importedAssemblies?.flatMap(\.nodes).first{$0.outputFeatureID==component.id}?.linearRGBA;value.materials=(prepared.materialColors[value.componentID] ?? [nil]).enumerated().map{material(for:component,object:object,materials:materials,faceColor:$0.element,partColor:partColor,slot:$0.offset)}};return value}
  }
  private nonisolated static func material(for component:CADComponentRepresentation,object:ProductObject,materials:[FormCore.Material],faceColor:SIMD4<Float>?=nil,partColor:[Double]?=nil,slot:Int=0)->SceneMaterialPayload {
    let material=materials.first{$0.id==(component.materialID ?? object.materialID)} ?? FormCore.Material.presets[1]
    let sourceColor=faceColor ?? partColor.map{SIMD4<Float>(Float($0[0]),Float($0[1]),Float($0[2]),Float($0[3]))}
    let explicit=component.color ?? object.color,color:SIMD4<Float>,encoding:SceneColorEncoding
    if let explicit{color=rgba(explicit);encoding = .srgb}else if let sourceColor{color=sourceColor;encoding = .linearSRGB}else{color=rgba(material.color);encoding = .srgb}
    return .init(id:"cad-material:\(component.id):\(slot)",revision:"\(color):\(material.roughness):\(material.metallic):\(encoding)",baseColor:color,colorEncoding:encoding,metallic:Float(material.metallic),roughness:Float(material.roughness),alphaMode:color.w<1 ? .blend:.opaque)
  }
  private nonisolated static func partitionDigest(_ groups:[[UInt32]])->String {
    var hash=SHA256();for group in groups{var count=UInt64(group.count).littleEndian;withUnsafeBytes(of:&count){hash.update(bufferPointer:$0)};group.withUnsafeBytes{hash.update(bufferPointer:$0)}};return hash.finalize().map{String(format:"%02x",$0)}.joined()
  }
  nonisolated static func placement(_ object:ProductObject)->SceneTransformPayload {
    let half=object.rotation*Double.pi/360
    return .init(translationMM:.init(object.position.x,object.position.y,object.position.z),rotationXYZW:.init(0,sin(half),0,cos(half)))
  }
  nonisolated static func verifiedAsset(_ name:String,sha256:String,assets:URL,maximumBytes:Int)throws->Data {
    guard !name.isEmpty,name.utf8.count<=255,!name.contains("/"),!name.contains("\\"),name != ".",name != ".." else{throw FormError.invalid("Invalid CAD asset path.")}
    let root=assets.standardizedFileURL.resolvingSymlinksInPath(),url=root.appendingPathComponent(name).resolvingSymlinksInPath()
    guard url.deletingLastPathComponent()==root else{throw FormError.invalid("A CAD asset resolves outside the project.")}
    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
    guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=maximumBytes else{throw FormError.invalid("CAD asset is missing or exceeds its allocation limit.")}
    let data=try Data(contentsOf:url)
    guard data.count<=maximumBytes,digest(data)==sha256 else{throw FormError.invalid("CAD asset SHA-256 changed. Regenerate or restore its exact source.")};return data
  }
  nonisolated static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  nonisolated static func canonicalData<T:Encodable>(_ value:T)throws->Data {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)
  }
  private nonisolated static func rgba(_ source:String)->SIMD4<Float> {
    let raw=source.hasPrefix("#") ? String(source.dropFirst()):source
    guard raw.count==6,let hex=UInt32(raw,radix:16) else{return .init(0.8,0.78,0.72,1)}
    return .init(Float((hex>>16)&255)/255,Float((hex>>8)&255)/255,Float(hex&255)/255,1)
  }
}
