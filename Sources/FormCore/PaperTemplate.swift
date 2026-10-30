import Foundation
import CryptoKit

public struct PaperTemplateChannel: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable { case cut, crease, perforation, glue, safety, bleed, instructions }
  public var elementID: String
  public var kind: Kind
  public init(elementID: String, kind: Kind) { self.elementID = elementID; self.kind = kind }
}

/// The supplier source is immutable asset data; the interpreted construction remains a separate editable model.
public struct PaperTemplateReference: Codable, Equatable, Sendable {
  public var originalAsset: String
  public var originalSHA256: String
  public var sourceName: String
  public var vendor: String?
  public var revision: String?
  public var instructions: String
  public var sizeMM: Point2
  public var viewBox: PaperBounds
  public var canonicalToTemplate: Affine2
  public var channels: [PaperTemplateChannel]
  public var interpretedGeometrySHA256: String
  public var importIssues: [String]
  public init(originalAsset: String, originalSHA256: String, sourceName: String, vendor: String? = nil,
    revision: String? = nil, instructions: String, sizeMM: Point2, viewBox: PaperBounds,
    canonicalToTemplate: Affine2 = .init(), channels: [PaperTemplateChannel],
    interpretedGeometrySHA256: String, importIssues: [String] = []) {
    self.originalAsset=originalAsset; self.originalSHA256=originalSHA256; self.sourceName=sourceName
    self.vendor=vendor; self.revision=revision; self.instructions=instructions; self.sizeMM=sizeMM
    self.viewBox=viewBox; self.canonicalToTemplate=canonicalToTemplate; self.channels=channels
    self.interpretedGeometrySHA256=interpretedGeometrySHA256; self.importIssues=importIssues
  }
  public func validate() throws {
    let m=canonicalToTemplate
    guard originalAsset == "paper-template-\(originalSHA256).svg", originalSHA256.count == 64,
      originalSHA256.allSatisfy({$0.isHexDigit}), !sourceName.isEmpty, sourceName.utf8.count<=512,
      (vendor?.utf8.count ?? 0)<=512, (revision?.utf8.count ?? 0)<=512,
      !instructions.isEmpty, instructions.utf8.count<=16000,
      sizeMM.x.isFinite, sizeMM.y.isFinite, sizeMM.x>0, sizeMM.y>0,
      [viewBox.x,viewBox.y,viewBox.width,viewBox.height,m.a,m.b,m.c,m.d,m.tx,m.ty].allSatisfy(\.isFinite),
      viewBox.width>0, viewBox.height>0, m.inverse != nil,
      !channels.isEmpty, channels.count<=4096,
      Set(channels.map(\.elementID)).count==channels.count,
      channels.allSatisfy({!$0.elementID.isEmpty && $0.elementID.utf8.count<=512}) else {
      throw FormError.invalid("Template references need a retained hashed SVG, units, instructions, invertible registration and unique technical IDs.")
    }
  }
  /// Registration keeps the supplier viewport fixed; reject bleed it would clip.
  public func containsPrintBounds(netSize:Point2,bleedMM:Double)->Bool {
    guard [netSize.x,netSize.y,bleedMM].allSatisfy(\.isFinite),netSize.x>0,netSize.y>0,(0...25).contains(bleedMM) else{return false}
    let m=canonicalToTemplate,epsilon=1e-7
    for x in [-bleedMM,netSize.x+bleedMM] {for y in [-bleedMM,netSize.y+bleedMM] {
      let u=m.a*x+m.c*y+m.tx,v=m.b*x+m.d*y+m.ty
      if u<viewBox.x-epsilon || u>viewBox.x+viewBox.width+epsilon || v<viewBox.y-epsilon || v>viewBox.y+viewBox.height+epsilon {return false}
    }}
    return true
  }
  public static func geometryRevision(_ definition: PaperConstruction) throws -> String {
    struct RegisteredGeometry:Encodable {let net:PaperNet;let caliperMM:Double}
    let geometry=RegisteredGeometry(net:try definition.net(),caliperMM:definition.stock.resolvedThicknessMM)
    return SHA256.hash(data:try JSONEncoder.form.encode(geometry)).map{String(format:"%02x",$0)}.joined()
  }
  public func requiresGeometryReview(_ definition: PaperConstruction) throws -> Bool {
    try Self.geometryRevision(definition) != interpretedGeometrySHA256
  }
}
