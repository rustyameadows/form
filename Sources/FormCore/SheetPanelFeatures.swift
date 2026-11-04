import Foundation
import FormCADModel

/// These are physical panel operations, usable by any authored flat assembly.
public struct SheetPanelWrap:Codable,Equatable,Sendable {
  public var stock:PaperStock
  public var turnInMM:CADScalar
  public var cornerRadiusMM:CADScalar
  public var stockThickness:CADScalar?
  public init(stock:PaperStock,turnInMM:CADScalar=12,cornerRadiusMM:CADScalar=0,stockThickness:CADScalar?=nil) {self.stock=stock;self.turnInMM=turnInMM;self.cornerRadiusMM=cornerRadiusMM;self.stockThickness=stockThickness}
}
public struct SheetPanelFlex:Codable,Equatable,Sendable {
  public var edge:SheetPanelEdge
  public var widthMM:CADScalar
  public var angleDegrees:CADScalar
  public var curve:SheetPanelNeutralCurve?
  public init(edge:SheetPanelEdge = .left,widthMM:CADScalar=8,angleDegrees:CADScalar=0,curve:SheetPanelNeutralCurve?=nil) {self.edge=edge;self.widthMM=widthMM;self.angleDegrees=angleDegrees;self.curve=curve}
}
public struct SheetPanelInsert:Codable,Equatable,Sendable {
  public var stock:PaperStock
  public var face:SheetAssemblyFace?
  public init(stock:PaperStock,face:SheetAssemblyFace?=nil) {self.stock=stock;self.face=face}
}
public struct SheetPanelRecess:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var origin:CADExpressionPoint2
  public var size:CADExpressionPoint2
  public var depthMM:CADScalar
  public var cornerRadiusMM:CADScalar
  public var insert:SheetPanelInsert?
  public init(id:String,origin:CADExpressionPoint2,size:CADExpressionPoint2,depthMM:CADScalar,
    cornerRadiusMM:CADScalar=0,insert:SheetPanelInsert?=nil) {
    self.id=id;self.origin=origin;self.size=size;self.depthMM=depthMM;self.cornerRadiusMM=cornerRadiusMM;self.insert=insert
  }
}
public struct SheetPanelFeatures:Codable,Equatable,Sendable {
  public var outline:[CADExpressionPoint2]?
  public var cutouts:[PlanarCutoutDefinition]?
  public var stockThickness:CADScalar?
  public var wrap:SheetPanelWrap?
  public var flex:SheetPanelFlex?
  public var recesses:[SheetPanelRecess]?
  public init(outline:[CADExpressionPoint2]?=nil,cutouts:[PlanarCutoutDefinition]?=nil,stockThickness:CADScalar?=nil,
    wrap:SheetPanelWrap?=nil,flex:SheetPanelFlex?=nil,recesses:[SheetPanelRecess]?=nil) {
    self.outline=outline;self.cutouts=cutouts;self.stockThickness=stockThickness;self.wrap=wrap;self.flex=flex;self.recesses=recesses
  }
}
public struct ResolvedSheetPanelWrap:Codable,Equatable,Sendable {
  public var stock:PaperStock
  public var turnInMM:Double,cornerRadiusMM:Double
}
public struct ResolvedSheetPanelFlex:Codable,Equatable,Sendable {
  public var edge:SheetPanelEdge
  public var widthMM:Double,angleDegrees:Double
  public var curve:SheetPanelNeutralCurveProfile? = nil
}
public struct ResolvedSheetPanelInsert:Codable,Equatable,Sendable {
  public var stock:PaperStock
  public var face:ResolvedSheetAssemblyFace?
}
public struct ResolvedSheetPanelRecess:Codable,Equatable,Identifiable,Sendable {
  public var id:String
  public var origin:Point2,size:Point2
  public var depthMM:Double,cornerRadiusMM:Double
  public var insert:ResolvedSheetPanelInsert?
}
public struct ResolvedSheetPanelFeatures:Codable,Equatable,Sendable {
  public var outline:[Point2]
  public var cutouts:[PaperPanelCutout]
  public var stockThickness:Double
  public var wrap:ResolvedSheetPanelWrap?
  public var flex:ResolvedSheetPanelFlex?
  public var recesses:[ResolvedSheetPanelRecess]
}

extension SheetPanelFeatures {
  public func resolved(size:Point2,stock:PaperStock,variables:[String:Double],
    face:(SheetAssemblyFace?,Point2)throws->ResolvedSheetAssemblyFace?)throws->(PaperStock,ResolvedSheetPanelFeatures) {
    func number(_ scalar:CADScalar)throws->Double {try CADExpression.evaluate(scalar.expression,variables:variables)}
    func point(_ value:CADExpressionPoint2)throws->Point2 {.init(try number(value.x),try number(value.y))}
    func material(_ source:PaperStock,thickness:CADScalar?)throws->PaperStock {
      try source.validate();var result=source
      if let thickness {
        let value=try number(thickness),prior=source.resolvedThicknessMM
        result.thicknessMM=value
        if result.plies != nil {for i in result.plies!.indices {result.plies![i].thicknessMM *= value/prior}}
      };try result.validate();return result
    }
    let effective=try material(stock,thickness:stockThickness)
    let polygon=try outline?.map(point) ?? [.init(0,0),.init(size.x,0),size,.init(0,size.y)]
    let holes=try (cutouts ?? []).map{PaperPanelCutout(id:$0.id,polygon:try $0.polygon.map(point),kind:$0.kind)}
    guard (3...128).contains(polygon.count),holes.count<=32,
      polygon.allSatisfy({$0.x>=0 && $0.y>=0 && $0.x<=size.x && $0.y<=size.y}),
      Set(holes.map(\.id)).count==holes.count else {throw FormError.invalid("Physical panel outlines need 3–128 points within the panel and at most 32 distinct cutouts.")}
    // Use the same polygon/hole kernel checks as ordinary planar construction.
    let panel=PlanarPanelDefinition(id:"panel",name:"Physical panel",polygon:polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},
      cutouts:holes.map{.init(id:$0.id,polygon:$0.polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},kind:$0.kind)})
    _ = try PlanarConstructionDefinition(name:"Physical panel",size:.init(CADScalar(size.x),CADScalar(size.y)),stockThickness:CADScalar(effective.resolvedThicknessMM),panels:[panel],rootPanelID:"panel").net()
    let resolvedWrap:ResolvedSheetPanelWrap?
    if let wrap {
      let skin=try material(wrap.stock,thickness:wrap.stockThickness)
      let turn=try number(wrap.turnInMM),radius=try number(wrap.cornerRadiusMM)
      guard turn>=0,turn<=min(size.x,size.y)/2,radius>=0,radius<=min(size.x,size.y)/2 else {throw FormError.invalid("Panel wrapping needs bounded turn-ins and corner radius within the physical panel.")}
      resolvedWrap = .init(stock:skin,turnInMM:turn,cornerRadiusMM:radius)
    }else{resolvedWrap=nil}
    let resolvedFlex:ResolvedSheetPanelFlex?
    if let flex {
      let width=try number(flex.widthMM),angle=try number(flex.angleDegrees)
      let extent=(flex.edge == .left || flex.edge == .right) ? size.x:size.y
      let half=effective.resolvedThicknessMM/2+(resolvedWrap?.stock.resolvedThicknessMM ?? 0)
      guard width>=0.01,width<=extent,abs(angle)<=180,
        flex.curve != nil || angle==0 || width/(abs(angle) * .pi/180)>half else {throw FormError.invalid("Panel flex must fit the physical edge and its neutral radius must exceed the actual stock and wrapping half-caliper.")}
      let curve:SheetPanelNeutralCurveProfile?
      if let source=flex.curve {
        guard angle==0 else{throw FormError.invalid("Choose a neutral curve or a circular angle for one panel flex, rather than competing bend definitions.")}
        curve=try .init(points:source.points.map(point),widthMM:width,fitLength:source.fitLength,maximumNormalOffsetMM:half)
      }else{curve=nil}
      resolvedFlex = .init(edge:flex.edge,widthMM:width,angleDegrees:angle,curve:curve)
    }else{resolvedFlex=nil}
    guard (recesses?.count ?? 0)<=16,Set((recesses ?? []).map(\.id)).count==(recesses?.count ?? 0) else {throw FormError.invalid("Use at most sixteen distinctly identified stepped recesses per panel.")}
    var resolvedRecesses=[ResolvedSheetPanelRecess]()
    for recess in recesses ?? [] {
      let origin=try point(recess.origin),extent=try point(recess.size),depth=try number(recess.depthMM),radius=try number(recess.cornerRadiusMM)
      guard !recess.id.isEmpty,recess.id.utf8.count<=128,origin.x>=0,origin.y>=0,extent.x>0,extent.y>0,
        origin.x+extent.x<=size.x,origin.y+extent.y<=size.y,depth>=0.01-1e-10,effective.resolvedThicknessMM-depth>=0.01-1e-10,
        radius>=0,radius<=min(extent.x,extent.y)/2 else {throw FormError.invalid("A stepped recess must fit the physical panel, retain a floor and depth of at least 0.01 mm, and use a bounded corner radius.")}
      guard !resolvedRecesses.contains(where:{other in
        origin.x<other.origin.x+other.size.x && origin.x+extent.x>other.origin.x &&
          origin.y<other.origin.y+other.size.y && origin.y+extent.y>other.origin.y
      }) else{throw FormError.invalid("Stepped panel recesses must not overlap.")}
      let rectangle=[Point2(origin.x,origin.y),Point2(origin.x+extent.x,origin.y),Point2(origin.x+extent.x,origin.y+extent.y),Point2(origin.x,origin.y+extent.y)]
      var validation=panel,validationID="__recess_validation"
      while (validation.cutouts ?? []).contains(where:{$0.id==validationID}) {validationID+="_"}
      validation.cutouts=(validation.cutouts ?? [])+[.init(id:validationID,polygon:rectangle.map{.init(CADScalar($0.x),CADScalar($0.y))})]
      _ = try PlanarConstructionDefinition(name:"Recess containment",size:.init(CADScalar(size.x),CADScalar(size.y)),stockThickness:CADScalar(effective.resolvedThicknessMM),panels:[validation],rootPanelID:"panel").net()
      let insert:ResolvedSheetPanelInsert?
      if let declaration=recess.insert {
        try declaration.stock.validate()
        guard declaration.stock.resolvedThicknessMM<=depth else{throw FormError.invalid("A recess insert cannot exceed the actual recess depth.")}
        insert = .init(stock:declaration.stock,face:try face(declaration.face,extent))
      }else{insert=nil}
      resolvedRecesses.append(.init(id:recess.id,origin:origin,size:extent,depthMM:depth,cornerRadiusMM:radius,insert:insert))
    }
    var plyCuts=[Double](),depth=0.0
    for ply in (effective.plies ?? []).reversed().dropLast() {depth+=ply.thicknessMM;plyCuts.append(depth)}
    let layers=Set([0,effective.resolvedThicknessMM]+resolvedRecesses.map(\.depthMM)+plyCuts).sorted()
    guard zip(layers,layers.dropFirst()).allSatisfy({let gap=$0.1-$0.0;return gap<=1e-10 || gap>=0.01-1e-10}) else {
      throw FormError.invalid("Stepped recesses and original ply interfaces must leave at least 0.01 mm between distinct physical layer boundaries.")
    }
    return(effective,.init(outline:polygon,cutouts:holes,stockThickness:effective.resolvedThicknessMM,wrap:resolvedWrap,flex:resolvedFlex,recesses:resolvedRecesses))
  }
}


extension PlanarConstructionDefinition {
  public var requiresAdvancedPanelFeaturesSchema:Bool {panels.contains{$0.features != nil}}
  public var featureArtworkSourceObjectIDs:Set<UUID> {
    Set(panels.flatMap{($0.features?.recesses ?? []).compactMap{$0.insert?.face?.sourceObjectID}})
  }
}


extension Project {
  func validatePaperPanelFeatures(_ object:ProductObject,source:PaperConstruction)throws {
    guard let authored=source.authored,authored.panels.contains(where:{$0.features != nil}) else{return}
    let net=try source.net(),values=try authored.resolvedValues().merging(["fold":source.foldPercent,"opening":source.openingPercent]){_,new in new}
    for panel in net.panels {
      guard var feature=panel.features else{continue}
      let bounds=panel.bounds,size=Point2(bounds.width,bounds.height)
      feature.outline=panel.polygon.map{.init(CADScalar($0.x-bounds.x),CADScalar($0.y-bounds.y))}
      feature.cutouts=(panel.cutouts ?? []).map{.init(id:$0.id,polygon:$0.polygon.map{.init(CADScalar($0.x-bounds.x),CADScalar($0.y-bounds.y))},kind:$0.kind)}
      let physical=try feature.resolved(size:size,stock:source.stock,variables:values) {declaration,extent in
        try resolvedSheetFace(declaration,size:extent,variables:values,assemblyID:object.id,validateSourceCrops:true)
      }
      if let wrap=physical.1.wrap,let art=paperArtwork(for:object) {
        let targets=try PaperAppearance.visiblePrintTargetIDs(artwork:art,project:self)
        if (art.backgroundOpacity ?? 1)>0 || !targets.isEmpty {
          let margin=physical.0.resolvedThicknessMM+wrap.turnInMM,owner=artworkOwner(object),extent=owner.artworkSize,bleed=art.bleed
          guard bounds.x-margin>=(-bleed)-1e-6,bounds.y-margin>=(-bleed)-1e-6,
            bounds.x+bounds.width+margin<=extent.x+bleed+1e-6,bounds.y+bounds.height+margin<=extent.y+bleed+1e-6 else {
            throw FormError.invalid("Wrapped panel artwork must include physical sidewall and turn-in margins around its actual-size cap.")
          }
        }
      }
    }
    guard !artworkDependencyCycle(from:object.id) else{throw FormError.invalid("A layered paper panel cannot print a live view that feeds its own inset/source artwork back into the same physical object.")}
  }
}
