import Foundation

public struct MeshAssetPartSummary:Codable,Equatable,Sendable,Identifiable {
  public var id:String,name:String,nodeID:String
  public var meshIndex:Int,primitiveIndex:Int
  public var materialIndex:Int?
  public var vertexCount:Int,triangleCount:Int
  public var uvSets:[Int]
  public init(id:String,name:String,nodeID:String,meshIndex:Int,primitiveIndex:Int,materialIndex:Int?,vertexCount:Int,triangleCount:Int,uvSets:[Int]) {self.id=id;self.name=name;self.nodeID=nodeID;self.meshIndex=meshIndex;self.primitiveIndex=primitiveIndex;self.materialIndex=materialIndex;self.vertexCount=vertexCount;self.triangleCount=triangleCount;self.uvSets=uvSets}
}
public struct MeshAssetMaterialSummary:Codable,Equatable,Sendable,Identifiable {
  public var index:Int,name:String
  public var baseColor:[Double]
  public var metallic:Double,roughness:Double
  public var textureChannels:[String]
  public var alphaMode:String
  public var id:Int {index}
  public init(index:Int,name:String,baseColor:[Double],metallic:Double,roughness:Double,textureChannels:[String],alphaMode:String) {self.index=index;self.name=name;self.baseColor=baseColor;self.metallic=metallic;self.roughness=roughness;self.textureChannels=textureChannels;self.alphaMode=alphaMode}
}
public struct MeshAssetMaterialOverride:Codable,Equatable,Sendable {
  public var materialIndex:Int
  public var colorHex:String?
  public var metallic:Double?,roughness:Double?,opacity:Double?
  public init(materialIndex:Int,colorHex:String?=nil,metallic:Double?=nil,roughness:Double?=nil,opacity:Double?=nil) {self.materialIndex=materialIndex;self.colorHex=colorHex;self.metallic=metallic;self.roughness=roughness;self.opacity=opacity}
  public func validate()throws {
    guard materialIndex>=0,[metallic,roughness,opacity].compactMap({$0}).allSatisfy({$0.isFinite && (0...1).contains($0)}),colorHex==nil || colorHex!.range(of:"^#[0-9A-Fa-f]{6}$",options:.regularExpression) != nil else{throw MeshAssetError.invalid("A mesh material override needs a valid slot, RGB hex color and unit-range PBR factors.")}
  }
}
public struct MeshAssetArtworkSize:Codable,Equatable,Sendable {
  public var width:Double,height:Double
  public init(width:Double,height:Double) {self.width=width;self.height=height}
}
public struct MeshAssetArtworkBinding:Codable,Equatable,Sendable {
  /// ProductObject.artworkSourceID / artwork remains the single source owner.
  public var materialIndex:Int
  public var primitiveIDs:[String]
  public var uvSet:Int
  public var physicalScaleVerified:Bool
  public init(materialIndex:Int,primitiveIDs:[String]=[],uvSet:Int=0) {self.materialIndex=materialIndex;self.primitiveIDs=primitiveIDs;self.uvSet=uvSet;self.physicalScaleVerified=false}
}

/// Small portable product-graph metadata. The normalized immutable resource contains the detailed buffers.
public struct MeshAssetReference:Codable,Equatable,Sendable,Identifiable {
  public var id:UUID
  public var sourceAsset:String,sourceSHA256:String,normalizedAsset:String,normalizedSHA256:String
  public var sourceFileName:String,name:String,format:String
  public var sourceUnit:MeshSourceUnit,unitDeclaration:String,coordinateConvention:String
  public var boundsMM:MeshAssetBounds
  public var vertexCount:Int,triangleCount:Int,instanceTriangleCount:Int
  public var parts:[MeshAssetPartSummary]
  public var materials:[MeshAssetMaterialSummary]
  public var warnings:[String]
  public var editability:String
  public var tableAnchor:String
  public var materialOverrides:[MeshAssetMaterialOverride]
  public var artworkBindings:[MeshAssetArtworkBinding]
  public var artworkSizeMM:MeshAssetArtworkSize?
  public init(document:MeshAssetDocument,sourceAsset:String,normalizedAsset:String,normalizedSHA256:String,name:String?=nil) {
    id=UUID();self.sourceAsset=sourceAsset;sourceSHA256=document.provenance.sourceSHA256;self.normalizedAsset=normalizedAsset;self.normalizedSHA256=normalizedSHA256
    sourceFileName=document.provenance.fileName;self.name=name ?? URL(fileURLWithPath:sourceFileName).deletingPathExtension().lastPathComponent;format=document.provenance.format;sourceUnit=document.provenance.unit;unitDeclaration=document.provenance.unitDeclaration;coordinateConvention=document.provenance.coordinateConvention;boundsMM=document.boundsMM
    vertexCount=document.vertexCount;triangleCount=document.triangleCount;instanceTriangleCount=document.instanceTriangleCount;editability="visualMesh";tableAnchor="boundsBottomCenter";materialOverrides=[];artworkBindings=[];artworkSizeMM=nil;warnings=document.provenance.warnings
    parts=document.nodes.filter(\.inSelectedScene).flatMap {node->[MeshAssetPartSummary] in
      guard let mesh=node.meshIndex else{return []}
      return document.meshes[mesh].primitives.enumerated().map{index,p in .init(id:node.id+"/"+p.id,name:node.name,nodeID:node.id,meshIndex:mesh,primitiveIndex:index,materialIndex:p.materialIndex,vertexCount:p.positionsMM.count,triangleCount:p.indices.count/3,uvSets:(!p.uv0.isEmpty ? [0]:[])+(!p.uv1.isEmpty ? [1]:[]))}
    }
    materials=document.materials.enumerated().map {index,m in
      var channels:[String]=[]
      if m.baseColorTexture != nil {channels.append("baseColor")};if m.normalTexture != nil {channels.append("normal")};if m.metallicRoughnessTexture != nil {channels.append("metallicRoughness")};if m.emissiveTexture != nil {channels.append("emissive")};if m.occlusionTexture != nil {channels.append("occlusion")}
      return .init(index:index,name:m.name,baseColor:m.baseColor,metallic:m.metallic,roughness:m.roughness,textureChannels:channels,alphaMode:m.alphaMode)
    }
  }
  public var geometryRevision:String {normalizedSHA256}
  public var appearanceRevision:String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return MeshAssetHash.sha256((try? encoder.encode(Appearance(overrides:materialOverrides,bindings:artworkBindings))) ?? Data())
  }
  private struct Appearance:Codable {var overrides:[MeshAssetMaterialOverride];var bindings:[MeshAssetArtworkBinding]}
  public func validate()throws {
    func file(_ name:String)->Bool {!name.isEmpty && name.utf8.count<=255 && name==URL(fileURLWithPath:name).lastPathComponent && name != "." && name != ".." && !name.contains("\\") && !name.contains("\0")}
    func digest(_ value:String)->Bool {value.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil}
    guard file(sourceAsset),file(normalizedAsset),sourceAsset != normalizedAsset,digest(sourceSHA256),digest(normalizedSHA256),name.utf8.count<=4096,sourceFileName.utf8.count<=4096,["glb","gltf","stl-binary","stl-ascii"].contains(format),editability=="visualMesh",tableAnchor=="boundsBottomCenter",
      vertexCount>0,vertexCount<=8_000_000,triangleCount>0,triangleCount<=8_000_000,instanceTriangleCount>0,instanceTriangleCount<=16_000_000,parts.count<=8192,materials.count<=2048,
      [boundsMM.minimum.x,boundsMM.minimum.y,boundsMM.minimum.z,boundsMM.maximum.x,boundsMM.maximum.y,boundsMM.maximum.z].allSatisfy({$0.isFinite && abs($0)<=1e9}),boundsMM.size.x>=0,boundsMM.size.y>=0,boundsMM.size.z>=0,Set(parts.map(\.id)).count==parts.count,Set(materials.map(\.index)).count==materials.count,
      Set(materialOverrides.map(\.materialIndex)).count==materialOverrides.count,artworkBindings.count<=8192,warnings.count<=8192 else{throw MeshAssetError.invalid("Mesh asset reference metadata is inconsistent or exceeds its supported bounds.")}
    for material in materials {
      guard material.index>=0,material.index<2048,material.name.utf8.count<=4096,material.baseColor.count==4,material.baseColor.allSatisfy({$0.isFinite && (0...1).contains($0)}),[material.metallic,material.roughness].allSatisfy({$0.isFinite && (0...1).contains($0)}),["OPAQUE","MASK","BLEND"].contains(material.alphaMode),material.textureChannels.count<=5 else{throw MeshAssetError.invalid("Imported material summary is invalid.")}
    }
    for part in parts {
      guard part.id.utf8.count<=512,part.name.utf8.count<=4096,part.nodeID.utf8.count<=256,part.meshIndex>=0,part.meshIndex<2048,part.primitiveIndex>=0,part.primitiveIndex<8192,part.vertexCount>0,part.vertexCount<=8_000_000,part.triangleCount>0,part.triangleCount<=8_000_000,Set(part.uvSets).count==part.uvSets.count,part.uvSets.allSatisfy({[0,1].contains($0)}),part.materialIndex==nil || materials.contains(where:{$0.index==part.materialIndex}) else{throw MeshAssetError.invalid("Imported part summary is invalid.")}
    }
    guard warnings.allSatisfy({$0.utf8.count<=4096}),unitDeclaration.utf8.count<=4096,coordinateConvention.utf8.count<=4096 else{throw MeshAssetError.invalid("Imported source notes exceed their limits.")}
    for override in materialOverrides {try override.validate();guard materials.contains(where:{$0.index==override.materialIndex}) else{throw MeshAssetError.invalid("Material override slot is missing from the imported source.")}}
    if let size=artworkSizeMM {guard [size.width,size.height].allSatisfy({$0.isFinite && $0>0 && $0<=1e6}) else{throw MeshAssetError.invalid("Stored artwork frame dimensions are invalid.")}}
    for binding in artworkBindings {
      guard materials.contains(where:{$0.index==binding.materialIndex}),binding.uvSet==0,!binding.physicalScaleVerified,Set(binding.primitiveIDs).count==binding.primitiveIDs.count else{throw MeshAssetError.invalid("UV artwork needs an existing material, supported UV0 and an explicit unverified physical scale.")}
      let targets=parts.filter{$0.materialIndex==binding.materialIndex && (binding.primitiveIDs.isEmpty || binding.primitiveIDs.contains($0.id))}
      guard !targets.isEmpty,targets.allSatisfy({$0.uvSets.contains(binding.uvSet)}),binding.primitiveIDs.allSatisfy({id in targets.contains{$0.id==id}}) else{throw MeshAssetError.invalid("UV artwork target primitive or coordinates are unavailable.")}
    }
  }
}
