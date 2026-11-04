import Foundation
import FormCADModel

/// A navigation label requires source identity, not every panel view or artwork
/// expansion. It shares the same canonical face resolver as a full descriptor.
public struct ConstructionArtworkSource:Sendable {
  public let componentID:String,inside:Bool,sourceObjectID:UUID,requiresInsideSource:Bool,title:String
}
/// One physical cut-pattern or upright face view of canonical construction ink.
/// Canvas and artwork tools consume this exact crop/orientation authority.
public struct ConstructionArtworkProjection:Sendable {
  public let componentID:String
  public let panelID:String?
  public let inside:Bool
  public let sourceObjectID:UUID
  /// True only while the canonical paper reverse is still embedded (or absent).
  public let requiresInsideSource:Bool
  public let frame:PhysicalArtworkFrame
  /// The same whole-piece crop/reflection authority used by ink and technical review.
  public let canonicalToSource:Affine2
  public let sourceNet:PaperNet
  public let stock:PaperStock
  public let title:String

  public func artwork(in project:Project)->Artwork? {
    guard let source=project.objects.first(where:{$0.id==sourceObjectID}) else{return nil}
    return requiresInsideSource ? project.paperArtwork(for:source,inside:true):project.editableArtwork(source)
  }
  public static func sources(in project:Project,object:ProductObject,paper:PaperConstruction,context:PlanarAssemblySourceContext?=nil)throws->[ConstructionArtworkSource] {
    guard let definition=paper.authored,definition.version>=4 else{return []}
    let context=try context ?? PlanarAssemblySourceContext(definition,fallbackStock:paper.stock)
    return try (definition.components ?? []).filter{context.enabledIDs.contains($0.id)}.flatMap {component in
      try [false,true].map {inside -> ConstructionArtworkSource in
        let mapping=try source(in:project,object:object,paper:paper,component:component,inside:inside,context:context)
        return .init(componentID:component.id,inside:inside,sourceObjectID:mapping.sourceID,requiresInsideSource:mapping.requiresInside,
          title:component.name+" · "+(inside ? "Reverse":"Front")+" pattern")
      }
    }
  }
  public static func resolveAll(in project:Project,object:ProductObject,paper:PaperConstruction,net:PaperNet,
    context:PlanarAssemblySourceContext?=nil)throws->[Self] {
    guard let definition=paper.authored,definition.version>=4 else{return []}
    let context=try context ?? PlanarAssemblySourceContext(definition,fallbackStock:paper.stock)
    var projections=[Self]()
    for component in definition.components ?? [] where context.enabledIDs.contains(component.id) {
      for inside in [false,true] {
        let source=try mapping(in:project,object:object,paper:paper,net:net,component:component,inside:inside,context:context)
        projections.append(source)
        for panel in source.sourceNet.panels {
          projections.append(try source.upright(panelID:panel.id,objectName:object.name,component:component,project:project))
        }
      }
    }
    return projections
  }
  public static func resolve(in project:Project,object:ProductObject,paper:PaperConstruction,net:PaperNet,
    componentID:String?=nil,panelID:String?=nil,inside:Bool=false,context:PlanarAssemblySourceContext?=nil)throws->Self {
    guard let definition=paper.authored,definition.version>=4 else{throw FormError.invalid("Independent cut-piece projections need a version-four source.")}
    let context=try context ?? PlanarAssemblySourceContext(definition,fallbackStock:paper.stock)
    let inferred=panelID.flatMap{context.pieceByPanel[$0]?.id}
    guard componentID==nil || inferred==nil || componentID==inferred,
      let id=componentID ?? inferred,context.enabledIDs.contains(id),
      let component=definition.components?.first(where:{$0.id==id}) else{throw FormError.missing("Choose an enabled component_id for its cut pattern, or surface_id for one of its upright faces.")}
    let source=try mapping(in:project,object:object,paper:paper,net:net,component:component,inside:inside,context:context)
    return try panelID.map{try source.upright(panelID:$0,objectName:object.name,component:component,project:project)} ?? source
  }
  /// Technical paths stay outside Artwork. Side and physical ownership are
  /// filtered before the exact same crop/upright transform maps them locally.
  public func technicalPaths(_ canonical:[ConstructionArtworkTechnicalPath])->[ConstructionArtworkTechnicalPath] {
    canonical.compactMap {path in
      guard path.componentID==componentID,path.side.map({($0 == .inside)==inside}) ?? true,
        panelID==nil || path.panelID==nil || path.panelID==panelID else{return nil}
      var local=path
      func point(_ p:Point2)->Point2 {frame.sourceToLocal.apply(canonicalToSource.apply(p))}
      local.points=path.points.map(point);local.holes=path.holes.map{$0.map(point)}
      if panelID != nil {
        let points=local.points+local.holes.flatMap{$0},padding=2.0
        guard let minX=points.map(\.x).min(),let maxX=points.map(\.x).max(),
          let minY=points.map(\.y).min(),let maxY=points.map(\.y).max(),
          maxX>=(-padding),maxY>=(-padding),minX<=frame.size.x+padding,minY<=frame.size.y+padding else{return nil}
      }
      return local
    }
  }
  private static func mapping(in project:Project,object:ProductObject,paper:PaperConstruction,net:PaperNet,
    component:PlanarComponentDefinition,inside:Bool,context:PlanarAssemblySourceContext)throws->Self {
    guard let bounds=context.bounds[component.id],let stock=context.stocks[component.id] else{throw FormError.missing("The selected cut piece has no physical source bounds.")}
    let resolved=try source(in:project,object:object,paper:paper,component:component,inside:inside,context:context)
    let sourceID=resolved.sourceID,origin=resolved.origin,requiresInside=resolved.requiresInside,independentBack=resolved.independentBack
    let ids=Set(context.ownership[component.id] ?? []),dx=origin.x-bounds.x,dy=origin.y-bounds.y
    let canonicalToSource=independentBack
      ? Affine2(a:-1,b:0,c:0,d:1,tx:origin.x+bounds.width+bounds.x,ty:dy)
      : Affine2.translation(dx,dy)
    func point(_ p:Point2)->Point2 {canonicalToSource.apply(p)}
    var sourceNet=net
    sourceNet.panels=net.panels.filter{ids.contains($0.id)}.map {panel in
      var panel=panel;panel.polygon=panel.polygon.map(point)
      if independentBack {panel.artworkRotationDegrees = -(panel.artworkRotationDegrees ?? 0)}
      panel.cutouts=panel.cutouts?.map{.init(id:$0.id,polygon:$0.polygon.map(point),kind:$0.kind)};return panel
    }
    sourceNet.folds=net.folds.filter{ids.contains($0.childPanelID)}.map{fold in var fold=fold;fold.start=point(fold.start);fold.end=point(fold.end);return fold}
    sourceNet.cutEdges=net.cutEdges.filter{ids.contains($0.panelID)}.map{edge in var edge=edge;edge.start=point(edge.start);edge.end=point(edge.end);return edge}
    sourceNet.joins=[];sourceNet.rootPanelID=component.rootPanelID
    var transform=Affine2.translation(-origin.x,-origin.y)
    if inside && !independentBack {transform=Affine2(a:-1,b:0,c:0,d:1,tx:bounds.width,ty:0).followed(by:transform)}
    return .init(componentID:component.id,panelID:nil,inside:inside,sourceObjectID:sourceID,requiresInsideSource:requiresInside,
      frame:.init(size:.init(bounds.width,bounds.height),sourceToLocal:transform),canonicalToSource:canonicalToSource,sourceNet:sourceNet,stock:stock,
      title:object.name+" · "+component.name+" · "+(inside ? "Reverse":"Front")+" pattern")
  }
  private static func source(in project:Project,object:ProductObject,paper:PaperConstruction,component:PlanarComponentDefinition,
    inside:Bool,context:PlanarAssemblySourceContext)throws->(sourceID:UUID,origin:Point2,requiresInside:Bool,independentBack:Bool) {
    guard let bounds=context.bounds[component.id] else{throw FormError.missing("The selected cut piece has no source bounds.")}
    let declaration=inside ? component.back:component.front
    let sourceID:UUID,origin:Point2,requiresInside:Bool,independentBack:Bool
    if let declaration {
      guard let source=project.objects.first(where:{$0.id==declaration.sourceObjectID}) else{throw FormError.missing("The cut-piece artwork source is missing.")}
      let referencedPaper=PaperConstruction.isPaper(source) ? try PaperConstruction.definition(for:source):nil
      sourceID=declaration.sourceSide == .inside && referencedPaper != nil
        ? referencedPaper?.insideArtworkSourceID ?? source.id:project.artworkOwner(source).id
      origin=try declaration.sourceOriginMM.map{p in try Point2(CADExpression.evaluate(p.x.expression,variables:context.values),CADExpression.evaluate(p.y.expression,variables:context.values))} ?? .init()
      requiresInside=declaration.sourceSide == .inside && referencedPaper != nil && referencedPaper?.insideArtworkSourceID==nil
      independentBack=inside && !(declaration.sourceSide == .inside && referencedPaper != nil)
    }else{
      sourceID=inside ? paper.insideArtworkSourceID ?? object.id:project.artworkOwner(object).id
      origin = .init(bounds.x,bounds.y);requiresInside=inside && paper.insideArtworkSourceID==nil;independentBack=false
    }
    guard project.objects.contains(where:{$0.id==sourceID}) else{throw FormError.missing("The canonical construction artwork source is missing.")}
    return(sourceID,origin,requiresInside,independentBack)
  }
  private func upright(panelID:String,objectName:String,component:PlanarComponentDefinition,project:Project)throws->Self {
    guard let panel=sourceNet.panels.first(where:{$0.id==panelID}) else{throw FormError.missing("The physical artwork face is not part of this cut piece.")}
    let declaration=inside ? component.back:component.front
    let registeredReverse=inside && (declaration==nil || (declaration?.sourceSide == .inside && project.objects.first(where:{$0.id==declaration?.sourceObjectID}).map(PaperConstruction.isPaper)==true))
    return .init(componentID:componentID,panelID:panelID,inside:inside,sourceObjectID:sourceObjectID,requiresInsideSource:requiresInsideSource,
      frame:try .paper(net:sourceNet,panelID:panelID,inside:registeredReverse),canonicalToSource:canonicalToSource,sourceNet:sourceNet,stock:stock,
      title:objectName+" · "+panel.name+" · "+(inside ? "Reverse":"Front"))
  }
}
