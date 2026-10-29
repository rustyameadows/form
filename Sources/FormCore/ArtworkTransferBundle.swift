import CoreGraphics
import CryptoKit
import Foundation

/// Portable source/resource transport, independent of the project package format.
public struct ArtworkTransferLimits: Sendable {
  public var metadataBytes=2*1024*1024, elements=2048, components=64, styles=256, swatches=256
  public var assets=32, individualAssetBytes=16*1024*1024, totalAssetBytes=32*1024*1024
  public var depth=32, work=200_000
  public init() {}
}

public struct ArtworkTransferAsset: Codable, Equatable, Sendable {
  public var sourceName:String, portableName:String, sha256:String
  public var length:Int
}
public struct ArtworkTransferComponent: Codable, Equatable, Sendable {
  public var id:UUID, name:String, size:Point2, artwork:Artwork
}
public struct ArtworkTransferMetadata: Codable, Equatable, Sendable {
  public var version=1, sourceSchema:Int, projectID:UUID, ownerID:UUID, selection:[UUID]
  public var artwork:Artwork, components:[ArtworkTransferComponent], styles:[ArtworkTextStyle], swatches:[ArtworkSwatch], assets:[ArtworkTransferAsset]
}
public struct ArtworkTransferBundle: Sendable {
  public var metadata:ArtworkTransferMetadata
  public var blobs:[String:Data]
  public init(metadata:ArtworkTransferMetadata,blobs:[String:Data]) {self.metadata=metadata;self.blobs=blobs}
  public static func digest(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
  public static func safeName(_ name:String)->Bool {
    !name.isEmpty && name.utf8.count<=200 && !name.contains("/") && !name.contains("\\") && !name.contains("..") && !name.contains("\0") && name != "."
  }
  public func encoded(limits:ArtworkTransferLimits = .init())throws->Data {
    try validate(limits:limits)
    let data=try JSONEncoder.form.encode(metadata)
    guard data.count<=limits.metadataBytes,data.count<=Int(UInt32.max) else{throw FormError.invalid("Artwork-transfer metadata exceeds its byte budget.")}
    var result=Data("FORMART1".utf8);let n=UInt32(data.count)
    result.append(contentsOf:[UInt8((n>>24)&255),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)]);result.append(data)
    for asset in metadata.assets {result.append(blobs[asset.sourceName]!)}
    return result
  }
  public static func decode(_ input:Data,limits:ArtworkTransferLimits = .init())throws->Self {
    guard input.count>=12,input.count<=12+limits.metadataBytes+limits.totalAssetBytes else{throw FormError.invalid("Artwork-transfer input exceeds its byte budget.")}
    let data=Data(input) // Normalize Data slices before indexing the fixed wire header.
    guard data.count>=12,
      data.prefix(8)==Data("FORMART1".utf8) else{throw FormError.invalid("Not a bounded FORM artwork-transfer bundle.")}
    let count=data[8..<12].reduce(0){($0<<8)|Int($1)}
    guard count>0,count<=limits.metadataBytes,count<=data.count-12 else{throw FormError.invalid("Invalid artwork-transfer metadata length.")}
    let bytes=data.subdata(in:12..<12+count)
    let raw=try JSONSerialization.jsonObject(with:bytes)
    var stack:[(Any,Int)]=[(raw,0)],work=0
    while let (value,depth)=stack.popLast() {
      work+=1;guard work<=limits.work,depth<=limits.depth else{throw FormError.invalid("Artwork-transfer metadata exceeds its traversal budget.")}
      if let values=value as? [Any] {guard values.count<=limits.work-work-stack.count else{throw FormError.invalid("Artwork-transfer array exceeds its work budget.")};stack += values.map{($0,depth+1)}}
      else if let values=value as? [String:Any] {guard values.count<=limits.work-work-stack.count else{throw FormError.invalid("Artwork-transfer object exceeds its work budget.")};stack += values.values.map{($0,depth+1)}}
    }
    guard let object=raw as? [String:Any],let version=object["version"] as? Int,version==1,let schema=object["sourceSchema"] as? Int,(1...Project.maximumSchemaVersion).contains(schema),
      let selection=object["selection"] as? [Any],!selection.isEmpty,selection.count<=limits.elements,
      let refs=object["assets"] as? [[String:Any]],refs.count<=limits.assets,
      let components=object["components"] as? [Any],components.count<=limits.components,
      let styles=object["styles"] as? [Any],styles.count<=limits.styles,
      let swatches=object["swatches"] as? [Any],swatches.count<=limits.swatches else{throw FormError.invalid("Unsupported artwork-transfer version or resource counts.")}
    guard let primary=object["artwork"] as? [String:Any],let elements=primary["elements"] as? [Any] else{throw FormError.invalid("Missing transfer artwork.")}
    var elementCount=elements.count
    for item in components {guard let value=item as? [String:Any],let art=value["artwork"] as? [String:Any],let values=art["elements"] as? [Any],values.count<=limits.elements-elementCount else{throw FormError.invalid("Component element count exceeds its transfer budget.")};elementCount+=values.count}
    guard elementCount<=limits.elements else{throw FormError.invalid("Selected graph exceeds its transfer element budget.")}
    // Counts and byte bounds precede decoding typed Artwork/asset contents.
    var total=0
    for ref in refs {
      guard let length=ref["length"] as? Int,length>0,length<=limits.individualAssetBytes,
        length<=limits.totalAssetBytes-total else{throw FormError.invalid("Artwork-transfer asset length exceeds its budget.")};total+=length
    }
    guard total==data.count-12-count else{throw FormError.invalid("Truncated or trailing artwork-transfer asset data.")}
    let metadata=try JSONDecoder.form.decode(ArtworkTransferMetadata.self,from:bytes)
    var blobs=[String:Data](),offset=12+count
    for asset in metadata.assets {guard blobs[asset.sourceName]==nil else{throw FormError.invalid("Duplicate artwork-transfer asset name.")};blobs[asset.sourceName]=data.subdata(in:offset..<offset+asset.length);offset+=asset.length}
    let result=Self(metadata:metadata,blobs:blobs);try result.validate(limits:limits);return result
  }
  public func validate(limits:ArtworkTransferLimits = .init())throws {
    let m=metadata,arts=[m.artwork]+m.components.map(\.artwork)
    guard m.version==1,(1...Project.maximumSchemaVersion).contains(m.sourceSchema),!m.selection.isEmpty,
      m.components.count<=limits.components,m.styles.count<=limits.styles,m.swatches.count<=limits.swatches,m.assets.count<=limits.assets,
      Set(m.components.map(\.id)).count==m.components.count,Set(m.assets.map(\.sourceName)).count==m.assets.count,
      Set(m.styles.map(\.id)).count==m.styles.count,Set(m.swatches.map(\.id)).count==m.swatches.count,
      arts.reduce(0,{$0+$1.elements.count})<=limits.elements else{throw FormError.invalid("This artwork uses an unsupported transfer schema or resource count.")}
    guard Set(arts.flatMap{Array($0.referencedTextStyles)})==Set(m.styles.map(\.id)),Set(arts.flatMap{Array($0.referencedSwatches)})==Set(m.swatches.map(\.id)),!Set(m.components.map(\.id)).contains(m.ownerID),Set(m.selection).count==m.selection.count else{throw FormError.invalid("Named resource closure is incomplete or contains unused definitions.")}
    let definitions=Dictionary(uniqueKeysWithValues:m.components.map{($0.id,$0)})
    var reached=Set<UUID>(),componentWork=0
    func component(_ id:UUID,stack:Set<UUID>,depth:Int)throws {
      componentWork+=1;guard componentWork<=limits.work,depth<=8,!stack.contains(id),let value=definitions[id] else{throw FormError.invalid("Component resource closure is incomplete, cyclic or too deep.")}
      reached.insert(id)
      for reference in value.artwork.elements.compactMap(\.component) {try component(reference.sourceObjectID,stack:stack.union([id]),depth:depth+1)}
    }
    for reference in m.artwork.elements.compactMap(\.component) {try component(reference.sourceObjectID,stack:[],depth:1)}
    guard reached==Set(definitions.keys) else{throw FormError.invalid("Unreferenced component definitions are not transferred.")}
    for definition in m.components {guard !definition.name.isEmpty,definition.name.utf8.count<=2000,[definition.size.x,definition.size.y].allSatisfy({$0.isFinite && (0.01...10000).contains($0)}) else{throw FormError.invalid("Invalid portable component name or physical size.")}}
    var work=componentWork
    for art in arts {
      guard Set(art.elements.map(\.id)).count==art.elements.count else{throw FormError.invalid("Duplicate transfer layer IDs.")}
      let byID=Dictionary(uniqueKeysWithValues:art.elements.map{($0.id,$0)})
      for e in art.elements {
        work+=1+e.text.utf16.count+(e.path?.contours.reduce(0){$0+$1.nodes.count} ?? 0)
        guard work<=limits.work else{throw FormError.invalid("Artwork-transfer graph exceeds its work budget.")}
        var parent=e.parentID,depth=0,seen=Set<UUID>()
        while let id=parent {work+=1;depth+=1;guard depth<=limits.depth,work<=limits.work,seen.insert(id).inserted,let value=byID[id] else{throw FormError.invalid("Artwork-transfer hierarchy is missing, cyclic or too deep.")};parent=value.parentID}
        guard e.storyFrame==nil else{throw FormError.invalid("Linked story frames require a complete publication transfer, which this prototype does not support.")}
      }
      try validateArtwork(art)
    }
    guard Set(m.selection).isSubset(of:Set(m.artwork.elements.map(\.id))) else{throw FormError.invalid("Artwork-transfer selection is not in its graph.")}
    var total=0
    for asset in m.assets {
      guard Self.safeName(asset.sourceName),Self.safeName(asset.portableName),asset.length>0,asset.length<=limits.individualAssetBytes,
        asset.length<=limits.totalAssetBytes-total,let data=blobs[asset.sourceName],data.count==asset.length,
        Self.digest(data)==asset.sha256 else{throw FormError.invalid("Invalid artwork-transfer asset path, size or digest.")}
      let ext=URL(fileURLWithPath:asset.sourceName).pathExtension.lowercased()
      let expected=(ext=="icc" ? "icc-":"image-")+asset.sha256+"."+ext
      guard ["png","jpg","jpeg","tif","tiff","gif","bmp","webp","heic","heif","pdf","svg","icc"].contains(ext),asset.portableName==expected else{throw FormError.invalid("Artwork-transfer assets must use verified content-addressed portable names.")};total+=asset.length
    }
    guard Set(blobs.keys)==Set(m.assets.map(\.sourceName)) else{throw FormError.invalid("Artwork-transfer has untracked asset data.")}
    let available=Set(m.assets.map(\.sourceName))
    var needed=Set<String>()
    for art in arts {needed.formUnion(art.elements.compactMap(\.asset));needed.formUnion((art.imports ?? []).map(\.asset));if let p=art.outputColorProfile {needed.insert(p.asset)}}
    for swatch in m.swatches {if let profile=swatch.printInk?.profile {needed.insert(profile.asset)}}
    guard needed==available else{throw FormError.invalid("Artwork-transfer asset closure is incomplete or contains unused resources.")}
    let assetsByName=Dictionary(uniqueKeysWithValues:m.assets.map{($0.sourceName,$0)})
    var profileModels=[String:String]()
    for profile in arts.compactMap(\.outputColorProfile)+m.swatches.compactMap({$0.printInk?.profile}) {
      try profile.validate();guard let bytes=blobs[profile.asset],assetsByName[profile.asset]?.sha256==profile.sha256 else{throw FormError.invalid("Artwork-transfer ICC bytes do not match their declared profile identity.")}
      if profileModels[profile.asset]==nil {
        guard let space=CGColorSpace(iccData:bytes as CFData),space.model == .rgb || space.model == .cmyk else{throw FormError.invalid("Artwork-transfer ICC bytes are not a valid RGB/CMYK output profile.")}
        profileModels[profile.asset]=space.model == .rgb ? "RGB":"CMYK"
      }
      guard profileModels[profile.asset]==profile.model else{throw FormError.invalid("Artwork-transfer ICC model differs from its declared profile.")}
    }
  }
}
