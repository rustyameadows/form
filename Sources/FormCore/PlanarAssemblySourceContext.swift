import Foundation
import FormCADModel

/// One evaluation request's immutable source preparation. It is deliberately
/// local to a call: edits cannot reuse stale enabled states, stock or geometry.
public struct PlanarAssemblySourceContext:Sendable {
  struct PoseSample:Sendable {var fold:Double;var opening:Double;var explosion:Double;var values:[String:Double]}
  public let values:[String:Double]
  public let ownership:[String:[String]]
  public let pieceByPanel:[String:PlanarComponentDefinition]
  public let rawPolygons:[String:[Point2]]
  public let bounds:[String:PaperBounds]
  public let stocks:[String:PaperStock]
  public let enabledIDs:Set<String>
  let endpointValues:[PoseSample]

  public init(_ definition:PlanarConstructionDefinition,values:[String:Double]?=nil,fallbackStock:PaperStock?=nil,includePoseEndpoints:Bool=false)throws {
    guard Set(definition.panels.map(\.id)).count==definition.panels.count else{throw FormError.invalid("Construction panel identities must be distinct.")}
    let values=try values ?? definition.resolvedValues();self.values=values
    let ownership=try definition.componentPanels();self.ownership=ownership
    let pieces=definition.components ?? []
    pieceByPanel=Dictionary(uniqueKeysWithValues:pieces.flatMap {piece in (ownership[piece.id] ?? []).map{($0,piece)}})
    func number(_ scalar:CADScalar)throws->Double {try CADExpression.evaluate(scalar.expression,variables:values)}
    let polygons=try Dictionary(uniqueKeysWithValues:definition.panels.map {panel in
      (panel.id,try panel.polygon.map{try Point2(number($0.x),number($0.y))})
    });rawPolygons=polygons
    var bounds=[String:PaperBounds](),stocks=[String:PaperStock](),enabledIDs=Set<String>()
    let fallback=try fallbackStock ?? PaperStock(thicknessMM:number(definition.stockThickness))
    for piece in pieces {
      let points=(ownership[piece.id] ?? []).flatMap{polygons[$0] ?? []}
      guard let x=points.map(\.x).min(),let y=points.map(\.y).min(),let right=points.map(\.x).max(),let bottom=points.map(\.y).max() else {throw FormError.invalid("A cut piece needs finite source material.")}
      bounds[piece.id] = .init(x:x,y:y,width:right-x,height:bottom-y)
      stocks[piece.id]=try PlanarConstructionDefinition.resizedStock(piece.stock ?? fallback,thickness:piece.stockThickness.map(number))
      if try definition.componentEnabled(piece,values:values){enabledIDs.insert(piece.id)}
    }
    self.bounds=bounds;self.stocks=stocks;self.enabledIDs=enabledIDs
    // The same derived graph was formerly resolved for every component at each
    // endpoint. Resolve each endpoint once for all pieces and parent groups.
    var samples=[PoseSample]()
    if includePoseEndpoints && (!pieces.isEmpty || definition.groups?.isEmpty == false) {
      for fold in [0.0,100] {for opening in [0.0,100] {for explosion in (definition.version>=4 ? [0.0,100]:[0.0]) {
        let pose=(definition.version>=4 && fold==100 && opening==0 && explosion==0) ? values:try definition.poseValues(fold:fold,opening:opening,explosion:explosion)
        samples.append(.init(fold:fold,opening:opening,explosion:explosion,values:pose))
      }}}
    }
    endpointValues=samples
  }
  func face(_ face:SheetAssemblyFace?,panel:PaperPanel,piece:PlanarComponentDefinition)throws->ResolvedSheetAssemblyFace? {
    guard let face else{return nil}
    guard let bounds=bounds[piece.id] else{throw FormError.missing("Cut piece '\(piece.id)' has no source bounds.")}
    let origin=try face.sourceOriginMM.map{try Point2(CADExpression.evaluate($0.x.expression,variables:values),CADExpression.evaluate($0.y.expression,variables:values))} ?? .init()
    return .init(sourceObjectID:face.sourceObjectID,sourceSide:face.sourceSide,
      originMM:.init(origin.x+panel.bounds.x-bounds.x,origin.y+panel.bounds.y-bounds.y))
  }
}
