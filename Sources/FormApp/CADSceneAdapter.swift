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
  }
  nonisolated static func load(for object:ProductObject,assets:URL,materials:[FormCore.Material]=FormCore.Material.presets)throws->[SceneRenderablePayload] {let prepared=try prepare(for:object,assets:assets);return renderables(prepared,for:object,materials:materials)}
  nonisolated static func prepare(for object:ProductObject,assets:URL)throws->Prepared {
    guard let model=object.cadModel,let representation=object.cadRepresentation else{throw FormError.invalid("The exact CAD source or representation is missing.")}
    try representation.validate(for:model)
    var renderables:[SceneRenderablePayload]=[],maps:[String:[UInt32]]=[:],slots:[String:[SIMD4<Float>?]]=[:],cost=0
    for component in representation.components {
      try Task.checkCancellation()
      _ = try verifiedAsset(component.brepAsset,sha256:component.brepSHA256,assets:assets,maximumBytes:256*1024*1024)
      let data=try verifiedAsset(component.meshAsset,sha256:component.meshSHA256,assets:assets,maximumBytes:256*1024*1024)
      let mesh=try CADMeshArchive.decode(data)
      guard mesh.positions.count<=2_000_000,mesh.indices.count/3==component.triangleCount else{throw FormError.invalid("The CAD display mesh exceeds the renderer vertex limit or disagrees with the exact source metadata. Regenerate at a coarser display tolerance.")}
      let id="cad:\(object.id.uuidString):\(component.id.uuidString)"
      let source=model.importedAssemblies?.flatMap(\.nodes).first{$0.outputFeatureID==component.id}
      if let source,!source.faceColors.isEmpty{guard source.outputFingerprint==component.featureFingerprint else{throw FormError.invalid("Imported face colors belong to another exact topology revision. Review the source face mapping before applying these edits.")}}
      let colors=source?.faceColors ?? []
      guard colors.allSatisfy({$0.faceIndex<=component.faceCount}) else{throw FormError.invalid("Imported face color references an unavailable source face.")}
      var groupColors:[SIMD4<Float>?]=[nil],byColor:[SIMD4<Float>:Int]=[:],faceGroups:[UInt32:Int]=[:]
      for color in colors.sorted(by:{$0.faceIndex<$1.faceIndex}){let rgba=SIMD4<Float>(Float(color.linearRGBA[0]),Float(color.linearRGBA[1]),Float(color.linearRGBA[2]),Float(color.linearRGBA[3]));let group:Int;if let old=byColor[rgba]{group=old}else{group=groupColors.count;byColor[rgba]=group;groupColors.append(rgba)};faceGroups[color.faceIndex]=group}
      guard groupColors.count<=256 else{throw FormError.invalid("STEP component exceeds 255 distinct face colors. Source metadata is preserved; reduce the display material groups explicitly.")}
      var indices=[[UInt32]](repeating:[],count:groupColors.count),faces=[[UInt32]](repeating:[],count:groupColors.count)
      for triangle in mesh.faceIndices.indices{let face=mesh.faceIndices[triangle],group=faceGroups[face] ?? 0;indices[group].append(contentsOf:mesh.indices[(triangle*3)..<(triangle*3+3)]);faces[group].append(face)}
      var parts:[SceneMeshPart]=[]
      for group in indices.indices where !indices[group].isEmpty{let part="\(component.id.uuidString):material:\(group)";parts.append(.init(materialIndex:group,triangleIndices:indices[group],semanticID:part));maps[id+"|"+part]=faces[group]}
      let revision=component.meshSHA256+":"+partitionDigest(indices)
      let payload=SceneMeshPayload(id:id,revision:revision,positionsMM:mesh.positions.map{.init($0.x,$0.y,$0.z)},normals:mesh.normals.map{.init(Float($0.x),Float($0.y),Float($0.z))},uvs:mesh.textureCoordinates.map{.init(Float($0.x),Float(1-$0.y))},parts:parts)
      cost+=payload.approximateBytes+mesh.faceIndices.count*8
      guard cost<=256*1024*1024 else{throw FormError.invalid("The CAD display buffers exceed the 256 MiB interactive budget.")}
      let appearances=groupColors.enumerated().map{material(for:component,object:object,materials:FormCore.Material.presets,faceColor:$0.element,partColor:source?.linearRGBA,slot:$0.offset)}
      try payload.validate(materialCount:appearances.count)
      renderables.append(.init(componentID:id,objectID:object.id,mesh:payload,materials:appearances,transform:placement(object)))
      maps[id]=mesh.faceIndices;slots[id]=groupColors
    }
    return .init(renderables:renderables,triangleFaces:maps,materialColors:slots,approximateBytes:cost)
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
  private nonisolated static func rgba(_ source:String)->SIMD4<Float> {
    let raw=source.hasPrefix("#") ? String(source.dropFirst()):source
    guard raw.count==6,let hex=UInt32(raw,radix:16) else{return .init(0.8,0.78,0.72,1)}
    return .init(Float((hex>>16)&255)/255,Float((hex>>8)&255)/255,Float(hex&255)/255,1)
  }
}
