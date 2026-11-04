import Foundation
import FormCADModel

public enum PaperRecipes {
  private static func parameters(_ source:PaperConstruction)->[Parameter]{[
    .init("width","Internal width",source.dimensions.width,30...1200,step:0.1),.init("height","Internal height",source.dimensions.height,40...1600,step:0.1),.init("depth","Internal depth",source.dimensions.depth,1...600,step:0.1),
    .init("stock","Stock caliper",source.stock.thicknessMM,0.08...2,step:0.01),.init("clearance","Contents clearance",source.clearanceMM,0...20,step:0.1),.init("glueTab","Side glue tab",source.glueTabMM,6...60,step:0.5),
    .init("topFlap","Top closing flap",source.topFlapMM,8...150,step:0.5),.init("bottomFlap","Bottom closing flap",source.bottomFlapMM,8...150,step:0.5),.init("cornerRadius","Flap corner radius",source.cornerRadiusMM,0...20,step:0.25),.init("fold","Fold preview",source.foldPercent,0...100,unit:"%",step:1),.init("opening","Top opening",source.openingPercent,0...100,unit:"%",step:1)]}
  public static let envelope=Recipe("paperEnvelope","Constructed envelope","envelope","A finite-depth paper envelope with one side glue seam, bonded bottom and top opening. Original registered net artwork.",parameters(PaperConstructionEngine.defaults(recipeID:"paperEnvelope")))
  public static let carton=Recipe("tuckCarton","Straight tuck carton","shippingbox","A scored carton with one side glue seam, four dust flaps and straight tuck closures. Original registered net artwork.",parameters(PaperConstructionEngine.defaults(recipeID:"tuckCarton")))
}
extension Project {
  public func paperNet(for object:ProductObject)throws->PaperNet{try PaperConstruction.definition(for:object).net()}
  /// Both sides use the same physical registered net. This never fits, mirrors or rewrites source artwork.
  public func paperArtwork(for object:ProductObject,inside:Bool=false)->Artwork? {
    guard PaperConstruction.isPaper(object) else{return nil};if !inside{return surfaceArtwork(object)}
    guard let source=try? PaperConstruction.definition(for:object) else{return nil}
    if let id=source.insideArtworkSourceID,let owner=objects.first(where:{$0.id==id}){return surfaceArtwork(owner)}
    return source.insideArtwork
  }
  public func validatePaperConstructions()throws {
    for object in objects where PaperConstruction.isPaper(object){
      guard object.meshAsset==nil,object.cadModel==nil,object.cadRepresentation==nil,object.cloth==nil,object.patternAssembly==nil,object.textile==nil else{throw FormError.invalid("Paper construction cannot share an object with a visual mesh, CAD, cloth, pattern assembly or textile source.")}
      let source=try PaperConstruction.definition(for:object)
      if source.kind != .authored {
        let expected=source.kind == .envelope ? "paperEnvelope":"tuckCarton"
        guard object.recipeID==expected else{throw FormError.invalid("Paper construction kind must match its paper recipe.")}
      } else {
        guard let recipe=recipe(object.recipeID),Set(recipe.parameters.map(\.id))==Set(PaperConstructionEngine.parameters(source).keys) else {throw FormError.invalid("Authored construction controls must match its saved parameter source.")}
        try recipe.validate(object.parameters)
      }
      _ = try source.net()
      try validatePaperPanelFeatures(object,source:source)
      if object.artworkSourceID != nil,object.artworkFit != "actual"{throw FormError.invalid("Paper construction artwork must remain registered at actual size.")}
      if let id=source.insideArtworkSourceID{guard id != object.id,let inside=objects.first(where:{$0.id==id}),isIndependentFlatArtworkSource(inside),!inside.isCanvasWorkspace,inside.artworkSourceID==nil,inside.artwork != nil else{throw FormError.invalid("Paper inside artwork must reference an independent artwork sheet. Detach it before removing its source.")}}
    }
  }
}
extension PaperConstructionEngine {
  /// Compare actual cut geometry and physical print registration, excluding
  /// stock appearance/metadata. Material color or texture does not move ink;
  /// caliper, turn-ins, insets and source crops can change its required extent.
  private static func artworkRegistrationPanels(_ source:PaperConstruction,net:PaperNet)throws->[PaperPanel] {
    let variables=try (source.authored?.resolvedValues() ?? [:]).merging(["fold":100,"opening":0]){_,new in new}
    func number(_ value:CADScalar)throws->CADScalar {.init(try CADExpression.evaluate(value.expression,variables:variables))}
    func point(_ value:CADExpressionPoint2)throws->CADExpressionPoint2 {.init(try number(value.x),try number(value.y))}
    func material(_ stock:PaperStock,thickness:CADScalar?=nil)throws->PaperStock {
      .init(thicknessMM:try thickness.map{try CADExpression.evaluate($0.expression,variables:variables)} ?? stock.resolvedThicknessMM)
    }
    return try net.panels.map{panel in
      var panel=panel;panel.name=""
      var features=panel.features ?? .init()
      features.outline=nil;features.cutouts=nil // Already resolved in the net.
      features.stockThickness=try features.stockThickness.map(number) ?? .init(source.stock.resolvedThicknessMM)
      if var wrap=features.wrap {
        wrap.stock=try material(wrap.stock,thickness:wrap.stockThickness);wrap.stockThickness=nil
        wrap.turnInMM=try number(wrap.turnInMM);wrap.cornerRadiusMM=try number(wrap.cornerRadiusMM);features.wrap=wrap
      }
      if var flex=features.flex {
        flex.widthMM=try number(flex.widthMM);flex.angleDegrees=try number(flex.angleDegrees)
        if var curve=flex.curve {curve.points=try curve.points.map(point);flex.curve=curve}
        features.flex=flex
      }
      if features.recesses != nil {
        for index in features.recesses!.indices {
          var recess=features.recesses![index]
          recess.origin=try point(recess.origin);recess.size=try point(recess.size)
          recess.depthMM=try number(recess.depthMM);recess.cornerRadiusMM=try number(recess.cornerRadiusMM)
          if var insert=recess.insert {
            insert.stock=try material(insert.stock)
            if let origin=insert.face?.sourceOriginMM {insert.face!.sourceOriginMM=try point(origin)}
            recess.insert=insert
          }
          features.recesses![index]=recess
        }
      }
      panel.features=features;return panel
    }
  }
  public static func synchronized(_ object:ProductObject,previous:ProductObject?)throws->ProductObject {
    var object=object,source=try definition(for:object)
    if let previous,PaperConstruction.isPaper(previous),object.artwork != nil || object.artworkSourceID != nil || source.insideArtwork != nil || source.insideArtworkSourceID != nil {
      let old=try definition(for:previous),oldNet=try old.net(),net=try source.net()
      if try oldNet.size != net.size || artworkRegistrationPanels(old,net:oldNet) != artworkRegistrationPanels(source,net:net) {
        source.artworkReviewRequired=true
        if source.artworkReferenceSize==nil{source.artworkReferenceSize=oldNet.size}
      }
    }
    object.paperConstruction=source;return object
  }
}
