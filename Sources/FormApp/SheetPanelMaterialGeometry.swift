import AppKit
import FormCore
import FormGeometry
import FormGraphics
import FormCADModel
import simd

/// The same layered-panel operation is available to ordinary planar assemblies
/// and publication enclosures. Its inputs are physical geometry and artwork.
@MainActor enum SheetPanelMaterialGeometry {
  static func make(object:ProductObject,panel:PaperPanel,definition:PaperConstruction,
    project:Project,assets:URL,outside:Artwork?,inside:Artwork?,limit:Int,
    sampling:SourceTextureSamplingPlan)throws->MeshNode {
    guard let features=panel.features else{throw FormError.invalid("Layered panel rendering needs physical panel features.")}
    let rect=panel.bounds,size=Point2(rect.width,rect.height)
    let values=try definition.authored?.poseValues(fold:definition.foldPercent,opening:definition.openingPercent,explosion:definition.explosionPercent ?? 0) ?? [:]
    func face(_ source:SheetAssemblyFace?,_ extent:Point2)throws->ResolvedSheetAssemblyFace? {
      guard let source else{return nil}
      let origin=try source.sourceOriginMM.map{Point2(try CADExpression.evaluate($0.x.expression,variables:values),try CADExpression.evaluate($0.y.expression,variables:values))} ?? .init()
      guard let owner=project.objects.first(where:{$0.id==source.sourceObjectID}),owner.sheetAssembly==nil,
        owner.recipeID=="artboard" || PaperConstruction.isPaper(owner) else{throw FormError.invalid("An inset panel needs canonical artboard or paper artwork.")}
      let bleed=project.surfaceArtwork(owner)?.bleed ?? 0
      guard origin.x >= -bleed,origin.y >= -bleed,origin.x+extent.x<=owner.artworkSize.x+bleed,origin.y+extent.y<=owner.artworkSize.y+bleed else{throw FormError.invalid("An inset crop must fit its actual source without scaling.")}
      return .init(sourceObjectID:source.sourceObjectID,sourceSide:source.sourceSide,originMM:origin)
    }
    let resolved=try features.resolved(size:size,stock:panel.resolvedStock(fallback:definition.stock),variables:values,face:face)
    let source=try PaperGeometry.panelArtwork(panel,definition:definition,project:project,outside:outside,inside:inside)
    var physical=resolved.1
    // Net topology remains the canonical authority, including authored windows.
    physical.outline=panel.polygon.map{.init($0.x-rect.x,$0.y-rect.y)}
    physical.cutouts=(panel.cutouts ?? []).map{.init(id:$0.id,polygon:$0.polygon.map{.init($0.x-rect.x,$0.y-rect.y)},kind:$0.kind)}
    let ownerFace=ResolvedSheetAssemblyFace(sourceObjectID:object.id)
    let plane=ResolvedSheetAssemblyPlane(id:panel.id,name:panel.name,size:size,positionMM:.init(),rotationDegrees:.init(),stock:resolved.0,
      front:source.outside==nil ? nil:ownerFace,back:source.inside==nil ? nil:ownerFace,finishes:source.outsideFinishes+source.insideFinishes,features:physical)
    let layers=try SheetPanelLayerGeometry.layers(plane),cap=Affine2.translation(-rect.x,-rect.y)
    let capOutside=source.outside.map{SheetAssemblyGeometry.transformed($0,by:cap)},capInside=source.inside.map{SheetAssemblyGeometry.transformed($0,by:cap)}
    let budget=sampling.raster.maximumPixels,minimum=layers.count*2*64
    let maximum=budget<minimum ? 1:sampling.raster.maximumEdge
    let targets=layers.flatMap{layer in [false,true].map {inside in
      SourceTextureSamplingTarget(id:layer.id+(inside ? ":back":":front"),sourceWidth:layer.size.x,sourceHeight:layer.size.y,
        projectedEdgePixels:Double(maximum),visibleWeight:layer.size.x*layer.size.y*((inside ? layer.back:layer.front)==nil ? 0.01:1))
    }}
    let plans=try SourceTextureSampling.allocate(targets,maximumEdge:maximum,pixelBudget:budget)
    let root=MeshNode();root.name=PaperGeometry.panelPrefix+panel.id
    for layer in layers {
      let frontPlan=plans[layer.id+":front"]!,backPlan=plans[layer.id+":back"]!
      let plan=SourceTextureSamplingPlan(raster:.init(maximumEdge:max(frontPlan.maximumEdge,backPlan.maximumEdge),maximumPixels:frontPlan.maximumPixels+backPlan.maximumPixels),
        surfaces:[SourceTextureSamplingPlan.paperFace("face",inside:false):frontPlan,SourceTextureSamplingPlan.paperFace("face",inside:true):backPlan],isFinalCapture:sampling.isFinalCapture)
      var front:Artwork?
      if layer.id.hasPrefix("insert:"),let source=layer.front {front=SheetAssemblyGeometry.prepared(source,size:layer.size,inside:false,project:project)}
      else if layer.front != nil,let art=capOutside {front=layer.frontMapping.map{SheetAssemblyGeometry.transformed(art,by:$0)} ?? art}else{front=nil}
      var back=layer.back==nil ? nil:capInside
      if layer.reverseArtwork {swap(&front,&back)}
      var virtual=object;virtual.sheetAssembly=nil;virtual.artwork=front
      let panelDefinition=PlanarPanelDefinition(id:"face",name:layer.id,polygon:layer.polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},
        cutouts:layer.cutouts.map{.init(id:$0.id,polygon:$0.polygon.map{.init(CADScalar($0.x),CADScalar($0.y))},kind:$0.kind)})
      var paper=PaperConstruction(kind:.authored,dimensions:.init(width:layer.size.x,height:layer.size.y,depth:layer.stock.resolvedThicknessMM),stock:layer.stock,foldPercent:0,insideArtwork:back)
      paper.authored = .init(name:"Physical panel layer",size:.init(CADScalar(layer.size.x),CADScalar(layer.size.y)),stockThickness:CADScalar(layer.stock.resolvedThicknessMM),panels:[panelDefinition],rootPanelID:"face")
      var finishes=layer.finishes
      if layer.id.hasPrefix("insert:"),let face=layer.front,let owner=project.objects.first(where:{$0.id==face.sourceObjectID}),
        let inherited=try? PaperConstruction.definition(for:owner) {
        finishes += (inherited.finishes ?? []).filter{$0.side==face.sourceSide}.map{original in var finish=original;finish.side = .outside;return finish}
      }
      paper.finishes=finishes.map{original in var finish=original;if layer.reverseArtwork {finish.side=finish.side == .outside ? .inside:.outside};return finish};virtual.paperConstruction=paper
      let wrapper=try PaperGeometry.make(virtual,project:project,assets:assets,limit:limit,sampling:plan,artworkSources:.init(outside:front,inside:back))
      wrapper.name="paper.layer:"+layer.id;wrapper.position = .init(layer.position/100);wrapper.eulerAngles = .init(layer.rotation)
      if let node=wrapper.childNode(withName:PaperGeometry.panelPrefix+"face",recursively:true),let mesh=node.geometry {
        node.transform = .init()
        if let flex=physical.flex {
          let positioned=SheetPanelMeshTransform.apply(mesh,matrix:wrapper.transform.raw)
          node.geometry=try SheetPanelFlexGeometry.make(positioned,size:size,edge:flex.edge.rawValue,widthMM:flex.widthMM,angleDegrees:flex.angleDegrees,final:sampling.isFinalCapture,curve:flex.curve)
          wrapper.transform = .init()
        }
      }
      // Paper hinge matrices map canonical flat-sheet coordinates. Layer math
      // is local to its panel, so translate only the derived rendering wrapper.
      wrapper.position = .init(wrapper.position.simd+SIMD3(rect.x/100,-rect.y/100,0));root.addChildNode(wrapper)
    };return root
  }
}
