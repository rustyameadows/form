import CryptoKit
import Foundation
import FormGeometry
import LabRendering

/// One synchronous preparation scope verifies each pathname once. A bounded
/// decoded-image cache may reuse equal bytes across scopes, but every new scope
/// reads and verifies the current source before consulting that cache.
@MainActor final class PhysicalTextureResources {
  private struct Cached {let source:SceneTextureSource;var used:UInt64}
  private static var cache:[String:Cached]=[:],cacheBytes=0,clock:UInt64=0
  private static let cacheLimit=256*1024*1024
  private static func cached(_ digest:String)->SceneTextureSource? {
    guard var entry=cache[digest] else{return nil}
    clock &+= 1;entry.used=clock;cache[digest]=entry;return entry.source
  }
  private static func remember(_ source:SceneTextureSource) {
    guard source.memoryCost<=cacheLimit else{return}
    while cacheBytes+source.memoryCost>cacheLimit,let oldest=cache.min(by:{$0.value.used<$1.value.used}) {
      cacheBytes-=oldest.value.source.memoryCost;cache.removeValue(forKey:oldest.key)
    }
    clock &+= 1;cache[source.sha256]=Cached(source:source,used:clock);cacheBytes+=source.memoryCost
  }
  private let assets:URL?
  private var sources:[String:SceneTextureSource]=[:]
  private var contents:[String:SceneTextureSource]=[:],decodedBytes=0
  init(assets:URL?){self.assets=assets}
  private func key(_ texture:MeshPhysicalTexture)->String? {
    (texture.url ?? assets?.appendingPathComponent(texture.assetName)).map{$0.standardizedFileURL.path+"\u{0}"+texture.sha256}
  }
  func source(for texture:MeshPhysicalTexture)->SceneTextureSource? {key(texture).flatMap{sources[$0]}}
  func prepare(_ appearance:MeshPhysicalAppearance)throws {
    for texture in appearance.textures.values {
      guard let key=key(texture),let url=texture.url ?? assets?.appendingPathComponent(texture.assetName) else {
        throw CyclesRenderError.invalidScene("A physical texture has no asset directory: "+texture.assetName)
      }
      if sources[key] != nil {continue}
      let properties=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
      guard properties.isRegularFile==true,properties.isSymbolicLink != true,(properties.fileSize ?? 0)<=268_435_456 else {
        throw CyclesRenderError.invalidScene("A physical texture is missing or exceeds the source budget: "+texture.assetName)
      }
      // Own the bytes used by the lazy ImageIO decoder; a later external write
      // must not mutate a memory-mapped provider after its digest was verified.
      let data=try Data(contentsOf:url)
      guard data.count<=268_435_456,SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==texture.sha256 else {
        throw CyclesRenderError.invalidScene("A physical texture is missing or changed: "+texture.assetName)
      }
      let source:SceneTextureSource
      if let cached=contents[texture.sha256] ?? Self.cached(texture.sha256) {source=cached}
      else {
        source=try SceneTextureSource(data:data,expectedSHA256:texture.sha256)
        Self.remember(source)
      }
      if contents[source.sha256] == nil {
        decodedBytes+=source.memoryCost
        guard decodedBytes<=1_073_741_824 else {throw CyclesRenderError.invalidScene("Unique physical textures exceed the 1 GiB render asset budget.")}
        contents[source.sha256]=source
      }
      sources[key]=source
    }
  }
}
