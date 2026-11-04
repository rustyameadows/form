import Foundation
import FormCADModel

public struct ResolvedConstructionGuide:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var role:ConstructionGuideRole
  public var points:[Point2]
  public var closed:Bool
  public var label:String
  public init(id:String,role:ConstructionGuideRole,points:[Point2],closed:Bool=false,label:String="") {self.id=id;self.role=role;self.points=points;self.closed=closed;self.label=label}
}
/// One connected component tree is one physical cut piece. Its local contour
/// and artwork registration are independent of assembly or sheet placement.
public struct ResolvedConstructionPiece:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var name:String
  public var groupID:String?
  public var purpose:String
  public var rootPanelID:String
  public var panelIDs:[String]
  public var stock:PaperStock
  public var quantity:Int
  public var bounds:PaperBounds
  public var cutContours:[[Point2]]
  public var guides:[ResolvedConstructionGuide]
  public var front:SheetAssemblyFace?
  public var back:SheetAssemblyFace?
  public var finishes:[PaperFinishAssignment]
  public var assembledPanels:[PaperResolvedPanel]
  public var areaMM2:Double {MaterialContourGeometry.materialArea(cutContours)}
}
public enum ConstructionPieces {
  public static func resolve(_ source:PaperConstruction)throws->[ResolvedConstructionPiece] {
    guard let definition=source.authored else{throw FormError.invalid("Independent-part packets need an authored planar construction.")}
    try definition.production?.validate(in:definition)
    let net=try source.net(),byPanel=Dictionary(uniqueKeysWithValues:net.panels.map{($0.id,$0)})
    let context=try PlanarAssemblySourceContext(definition,fallbackStock:source.stock),membership=context.ownership
    let components=(definition.components ?? []).filter{context.enabledIDs.contains($0.id)},poses=try source.resolvedPanels()
    let values=context.values,production=definition.production
    var result=[ResolvedConstructionPiece]()
    for component in components {
      let ids=membership[component.id] ?? [],panels=ids.compactMap{byPanel[$0]}
      guard !panels.isEmpty else{continue}
      guard let bounds=context.bounds[component.id] else{throw FormError.invalid("A cut piece has no prepared physical source bounds.")}
      guard let stock=context.stocks[component.id] else{throw FormError.invalid("A cut piece has no prepared physical stock.")}
      let localPanels=panels.map { p->PaperPanel in
        var p=p;p.polygon=p.polygon.map{.init($0.x-bounds.x,$0.y-bounds.y)}
        p.cutouts=p.cutouts?.map{.init(id:$0.id,polygon:$0.polygon.map{.init($0.x-bounds.x,$0.y-bounds.y)},kind:$0.kind)}
        return p
      }
      let localNet=PaperNet(size:.init(bounds.width,bounds.height),panels:localPanels,folds:[],joins:[],cutEdges:[],rootPanelID:component.rootPanelID)
      let contours=try PaperPrintGeometry.bleedContours(localNet,millimeters:0).sorted{MaterialContourGeometry.area($0)>MaterialContourGeometry.area($1)}
      guard let outer=contours.first,outer.count>=3,MaterialContourGeometry.materialArea(contours)>0 else{throw FormError.invalid("Cut piece ‘\(component.id)’ has no finite material contour.")}
      var guides=net.folds.filter{ids.contains($0.childPanelID)}.map { fold in
        ResolvedConstructionGuide(id:fold.id,role:production?.foldRoles[fold.id] ?? .fold,
          points:[fold.start,fold.end].map{.init($0.x-bounds.x,$0.y-bounds.y)},label:fold.id)
      }
      for guide in production?.guides ?? [] where guide.componentID==component.id {
        let points=try guide.resolvedPoints(values:values,bounds:bounds)
        guides.append(.init(id:guide.id,role:guide.role,points:points,closed:guide.closed,label:guide.label))
      }
      result.append(.init(id:component.id,name:component.name,groupID:component.groupID,purpose:component.purpose ?? "part",
        rootPanelID:component.rootPanelID,panelIDs:ids,stock:stock,quantity:component.quantity ?? 1,bounds:bounds,
        cutContours:contours,guides:guides,front:component.front,back:component.back,finishes:component.finishes ?? [],assembledPanels:poses.filter{ids.contains($0.panelID)}))
    }
    guard !result.isEmpty,result.count<=128 else{throw FormError.invalid("Construction packets need 1–128 active independent cut pieces.")}
    return result
  }
}
