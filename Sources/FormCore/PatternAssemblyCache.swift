import Foundation
import CryptoKit

/// Bounded derived data only. Each owning app actor keeps one value; no timer,
/// document/history writes or global worker can advance this cache implicitly.
public struct PatternAssemblyCache:Sendable {
  public static let maximumEntries=3
  public static let maximumRetainedVertices=8192
  private struct Entry:Sendable {var key:String;var product:PatternAssemblyProduct}
  private var entries:[Entry]=[]
  public private(set) var builds=0
  public var retainedVertices:Int {entries.reduce(0){$0+$1.product.study.mesh.restPositionsMm.count}}
  public init() {}
  public mutating func clear() {entries=[]}
  public mutating func resolve(_ definition:PatternAssemblyDefinition,in project:Project)throws -> PatternAssemblyProduct {
    let key=try geometryDigest(definition,in:project)
    if let index=entries.firstIndex(where:{$0.key==key}) {
      var entry=entries.remove(at:index)
      entry.product.sourceDigest=try PatternAssemblyGenerator.sourceDigest(definition,in:project)
      entries.append(entry);return entry.product
    }
    let product=try PatternAssemblyGenerator.generate(definition,in:project);builds+=1
    entries.append(.init(key:key,product:product))
    while entries.count>Self.maximumEntries || retainedVertices>Self.maximumRetainedVertices {entries.removeFirst()}
    return product
  }
  /// Paint/font/guide edits cannot remesh a panel. The physical record includes
  /// the effective ancestor transform and original IDs, not a tessellation ID.
  public func geometryDigest(_ definition:PatternAssemblyDefinition,in project:Project)throws -> String {
    struct Piece:Encodable {
      var id:UUID,kind:String,width:Double,height:Double,path:VectorPath?,transform:Affine2,sewing:SewingPatternPiece
    }
    struct Signature:Encodable {var project:UUID,definition:PatternAssemblyDefinition,pieces:[Piece],seams:[SewingSeam]}
    try definition.validateDeclarations()
    guard let owner=project.objects.first(where:{$0.id==definition.sourceObjectID}),owner.artworkSourceID==nil,let art=owner.artwork else {throw FormError.invalid("The assembly's independent source pattern owner is missing.")}
    try validateArtwork(art)
    var pieces:[Piece]=[]
    for id in Set(definition.panels.map{$0.panel.elementID}).sorted(by:{$0.uuidString<$1.uuidString}) {
      guard let e=art.elements.first(where:{$0.id==id}),let piece=e.sewingPiece else {throw FormError.invalid("An assembly source pattern piece is missing.")}
      _ = try SewingPatterns.geometry(e,in:art) // Also checks masks/effects/ancestors.
      pieces.append(.init(id:id,kind:e.kind,width:e.width,height:e.height,path:e.path,transform:art.worldTransform(e),sewing:piece))
    }
    let wanted=Set(definition.seamIDs),seams=(art.sewingSeams ?? []).filter{wanted.contains($0.id)}.sorted{$0.id.uuidString<$1.id.uuidString}
    let data=try JSONEncoder.form.encode(Signature(project:project.id,definition:definition,pieces:pieces,seams:seams))
    return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
  }
}
