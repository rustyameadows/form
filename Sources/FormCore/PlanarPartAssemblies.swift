import Foundation
import FormCADModel

/// A source-owned rigid parent frame. It groups ordinary cut pieces, not a product kind.
public struct PlanarComponentGroupDefinition:Codable,Equatable,Identifiable,Sendable {
  public var id:String,name:String,parentID:String?
  public var position:CADExpressionPoint,rotationDegrees:CADExpressionPoint
  public init(id:String,name:String,parentID:String?=nil,position:CADExpressionPoint = .init(),rotationDegrees:CADExpressionPoint = .init()) {
    self.id=id;self.name=name;self.parentID=parentID;self.position=position;self.rotationDegrees=rotationDegrees
  }
}

extension PaperPanel {
  /// Retains the inherited face/ply profiles when a piece overrides only caliper.
  public func resolvedStock(fallback:PaperStock)throws->PaperStock {
    try PlanarConstructionDefinition.resizedStock(stock ?? fallback,thickness:stockThicknessMM)
  }
}

extension PlanarConstructionDefinition {
  public static func resizedStock(_ stock:PaperStock,thickness:Double?)throws->PaperStock {
    try stock.validate();guard let thickness else{return stock}
    guard thickness.isFinite,(0.01...20).contains(thickness) else{throw FormError.invalid("A cut-piece caliper must be 0.01–20 mm.")}
    var result=stock;let prior=stock.resolvedThicknessMM
    result.thicknessMM=thickness
    if result.plies != nil {for i in result.plies!.indices {result.plies![i].thicknessMM *= thickness/prior}}
    try result.validate();return result
  }
  public func componentStock(_ component:PlanarComponentDefinition,fallback:PaperStock,values:[String:Double]?=nil)throws->PaperStock {
    let variables=try values ?? resolvedValues()
    let caliper=try component.stockThickness.map{try CADExpression.evaluate($0.expression,variables:variables)}
    return try Self.resizedStock(component.stock ?? fallback,thickness:caliper)
  }
  public func activeComponents(values:[String:Double]?=nil)throws->[PlanarComponentDefinition] {
    let values=try values ?? resolvedValues()
    return try (components ?? []).filter {try componentEnabled($0,values:values)}
  }
  public func componentEnabled(_ component:PlanarComponentDefinition,values:[String:Double]?=nil)throws->Bool {
    guard let expression=component.enabled else{return true}
    let variables=try values ?? resolvedValues(),value=try CADExpression.evaluate(expression.expression,variables:variables)
    guard abs(value)<1e-9 || abs(value-1)<1e-9 else{throw FormError.invalid("Cut piece '\(component.id)' enabled must resolve to zero or one.")}
    return value>0.5
  }
  /// Complete saved ownership, including disabled pieces. Retaining these IDs is
  /// what lets a saved option restore the same artwork and material declarations.
  public func componentPanels()throws->[String:[String]] {
    let pieces=components ?? []
    guard !pieces.isEmpty else{return [:]}
    let ids=Set(panels.map(\.id)),roots=Set(pieces.map(\.rootPanelID))
    guard ids.count==panels.count,roots.count==pieces.count,Set(pieces.map(\.id)).count==pieces.count,
      roots.isSubset(of:ids),Set(hinges.map(\.childPanelID)).count==hinges.count else {
      throw FormError.invalid("Cut pieces need distinct identities and roots; each non-root face has one hinge owner.")
    }
    var owners=Dictionary(uniqueKeysWithValues:pieces.map{($0.rootPanelID,$0.id)})
    for _ in panels.indices {
      var changed=false
      for hinge in hinges {
        guard ids.contains(hinge.parentPanelID),ids.contains(hinge.childPanelID),!roots.contains(hinge.childPanelID) else {
          throw FormError.invalid("A cut-piece hinge must connect existing non-root child material.")
        }
        if let owner=owners[hinge.parentPanelID] {
          if let prior=owners[hinge.childPanelID],prior != owner {throw FormError.invalid("A face cannot belong to two cut pieces.")}
          if owners[hinge.childPanelID]==nil {owners[hinge.childPanelID]=owner;changed=true}
        }
      }
      if !changed {break}
    }
    guard owners.count==panels.count,hinges.count==panels.count-pieces.count else {
      throw FormError.invalid("Every saved face must belong to one acyclic cut-piece hinge tree.")
    }
    return Dictionary(uniqueKeysWithValues:pieces.map {piece in (piece.id,panels.filter{owners[$0.id]==piece.id}.map(\.id))})
  }
  public func componentBounds(componentID:String)throws->PaperBounds {
    guard let owned=try componentPanels()[componentID],!owned.isEmpty else{throw FormError.missing("Cut piece '\(componentID)' is missing.")}
    let wanted=Set(owned),variables=try resolvedValues()
    let points=try panels.filter{wanted.contains($0.id)}.flatMap{panel in try panel.polygon.map {p in
      try Point2(CADExpression.evaluate(p.x.expression,variables:variables),CADExpression.evaluate(p.y.expression,variables:variables))
    }}
    guard let x=points.map(\.x).min(),let y=points.map(\.y).min(),let right=points.map(\.x).max(),let bottom=points.map(\.y).max() else {
      throw FormError.invalid("A cut piece needs finite source material.")
    }
    return .init(x:x,y:y,width:right-x,height:bottom-y)
  }
  public var usesPartAssemblyFields:Bool {
    groups?.isEmpty == false || jointAttachments?.isEmpty == false || controls != nil || production != nil || (components ?? []).contains {
      $0.groupID != nil || $0.stock != nil || $0.stockThickness != nil || $0.quantity != nil || $0.purpose != nil || $0.front != nil || $0.back != nil || $0.enabled != nil || $0.finishes != nil
    } || joins.contains{$0.enabled != nil}
  }
  func validatePartAssemblyMetadata(resolvedPanels:[PaperPanel],context:PlanarAssemblySourceContext)throws {
    let values=context.values
    func number(_ scalar:CADScalar)throws->Double {try CADExpression.evaluate(scalar.expression,variables:values)}
    guard version>=4 || !usesPartAssemblyFields else {throw FormError.invalid("Independent cut-piece/group/joint fields require construction version 4.")}
    guard version>=4 else{return}
    let pieces=components ?? [],groups=groups ?? []
    guard !pieces.isEmpty,pieces.count<=128,groups.count<=64,Set(groups.map(\.id)).count==groups.count else {
      throw FormError.invalid("Version 4 needs 1–128 cut pieces and at most 64 distinct parent groups.")
    }
    let groupIDs=Set(groups.map(\.id))
    for group in groups {
      guard !group.id.isEmpty,group.id.utf8.count<=128,!group.name.isEmpty,group.name.utf8.count<=160,
        group.parentID.map({$0 != group.id && groupIDs.contains($0)}) ?? true else {
        throw FormError.invalid("Assembly groups need bounded identities and existing distinct parent frames.")
      }
    }
    for group in groups {
      var seen=Set<String>(),cursor:String?=group.id
      while let id=cursor {guard seen.insert(id).inserted else{throw FormError.invalid("Assembly parent groups contain a cycle at '\(id)'.")};cursor=groups.first{$0.id==id}?.parentID}
    }
    for piece in pieces {
      guard piece.groupID.map(groupIDs.contains) ?? true,(1...10000).contains(piece.quantity ?? 1),
        piece.purpose.map({$0.utf8.count<=160}) ?? true else{throw FormError.invalid("Cut piece '\(piece.id)' has an unknown group or invalid quantity/purpose.")}
      guard (piece.finishes?.count ?? 0)<=128,Set((piece.finishes ?? []).map(\.id)).count==(piece.finishes?.count ?? 0) else{throw FormError.invalid("A cut piece needs at most128 distinct finish assignments.")}
      for finish in piece.finishes ?? [] {try finish.validate()}
      guard let bounds=context.bounds[piece.id],context.stocks[piece.id] != nil else{throw FormError.invalid("Cut piece preparation is incomplete.")}
      guard bounds.width>0,bounds.height>0 else{throw FormError.invalid("A cut piece must retain positive source extents.")}
      for face in [piece.front,piece.back].compactMap({$0}) {
        let origin=try face.sourceOriginMM.map{try Point2(number($0.x),number($0.y))} ?? .init()
        guard [origin.x,origin.y].allSatisfy({$0.isFinite && abs($0)<=100000}) else{throw FormError.invalid("Cut-piece artwork needs a bounded physical source origin.")}
      }
    }
    for sample in context.endpointValues where sample.fold==100 {
      _ = try resolvedGroupMatrices(fold:sample.fold,opening:sample.opening,explosion:sample.explosion,values:sample.values)
    }
    try controls?.validate(parameters:parameters,derived:derived)
    try production?.validate(in:self,context:context)
    try validateAttachmentMetadata(values:values)
  }
  public func poseValues(fold:Double,opening:Double,explosion:Double)throws->[String:Double] {
    guard [fold,opening,explosion].allSatisfy({$0.isFinite && (0...100).contains($0)}) else{throw FormError.invalid("Construction fold/opening/explosion poses must be 0–100%.")}
    if version>=4 {return try CADDerivedExpressions.resolve(derived ?? [:],variables:values.merging(["fold":fold,"opening":opening,"explosion":explosion]){_,new in new})}
    return try resolvedValues().merging(["fold":fold,"opening":opening]){_,new in new}
  }
  func resolvedGroupMatrices(fold:Double,opening:Double,explosion:Double,values:[String:Double]?=nil)throws->[String:[Double]] {
    let declarations=groups ?? [],variables=try values ?? poseValues(fold:fold,opening:opening,explosion:explosion),amount=fold/100
    var result=[String:[Double]](),pending=declarations
    for _ in 0...declarations.count {
      if pending.isEmpty {break};var next=[PlanarComponentGroupDefinition]()
      for group in pending {
        if let parent=group.parentID,result[parent]==nil {next.append(group);continue}
        let p=try PaperRigidMatrix.vector(group.position,values:variables),r=try PaperRigidMatrix.vector(group.rotationDegrees,values:variables)
        guard [r.x,r.y,r.z].allSatisfy({abs($0)<=3600}) else{throw FormError.invalid("Group rotations must remain within ±3600 degrees.")}
        let local=PaperRigidMatrix.multiply(PaperRigidMatrix.translation(p.x*amount,p.y*amount,p.z*amount),PaperRigidMatrix.rotation(r.x*amount,r.y*amount,r.z*amount))
        result[group.id]=PaperRigidMatrix.multiply(group.parentID.flatMap{result[$0]} ?? PaperRigidMatrix.identity,local)
      }
      guard next.count<pending.count else{throw FormError.invalid("Assembly parent groups are disconnected or cyclic.")};pending=next
    }
    return result
  }
}
