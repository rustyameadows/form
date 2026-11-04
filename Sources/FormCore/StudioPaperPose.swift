import Foundation

/// Presentation-only overrides for a physical planar assembly. Cut sizes,
/// component stocks, source artwork and the design's accepted pose stay intact.
public struct StudioPaperPose:Codable,Equatable,Sendable {
  public var foldPercent:Double?
  public var openingPercent:Double?
  public var explosionPercent:Double?
  public init(foldPercent:Double?=nil,openingPercent:Double?=nil,explosionPercent:Double?=nil) {
    self.foldPercent=foldPercent;self.openingPercent=openingPercent;self.explosionPercent=explosionPercent
  }
  public var isEmpty:Bool {foldPercent==nil && openingPercent==nil && explosionPercent==nil}
  public func validate()throws {
    guard [foldPercent,openingPercent,explosionPercent].compactMap({$0}).allSatisfy({$0.isFinite && (0...100).contains($0)}) else {
      throw FormError.invalid("A planar presentation pose needs fold, opening and explosion percentages from zero to 100.")
    }
  }
  public func applying(to source:ProductObject)throws->ProductObject {
    try validate()
    guard PaperConstruction.isPaper(source) else{throw FormError.invalid("Planar presentation controls need a paper or part-assembly source.")}
    var result=source,paper=try PaperConstruction.definition(for:source)
    if let foldPercent {paper.foldPercent=foldPercent;result.parameters["fold"]=foldPercent}
    if let openingPercent {paper.openingPercent=openingPercent;result.parameters["opening"]=openingPercent}
    if let explosionPercent {
      guard (paper.authored?.version ?? 0)>=4 else{throw FormError.invalid("Exploded presentation needs an authored part assembly.")}
      paper.explosionPercent=explosionPercent
      if result.parameters["explosion"] != nil{result.parameters["explosion"]=explosionPercent}
    }
    result.paperConstruction=paper
    _ = try paper.resolvedPanels()
    return result
  }
}
