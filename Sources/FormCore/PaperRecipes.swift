import Foundation

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
      let source=try PaperConstruction.definition(for:object),expected=source.kind == .envelope ? "paperEnvelope":"tuckCarton"
      guard object.recipeID==expected else{throw FormError.invalid("Paper construction kind must match its paper recipe.")}
      _ = try source.net()
      if object.artworkSourceID != nil,object.artworkFit != "actual"{throw FormError.invalid("Paper construction artwork must remain registered at actual size.")}
      if let id=source.insideArtworkSourceID{guard id != object.id,let inside=objects.first(where:{$0.id==id}),inside.recipeID=="artboard",!inside.isCanvasWorkspace,inside.artworkSourceID==nil,inside.artwork != nil else{throw FormError.invalid("Paper inside artwork must reference an independent artwork sheet. Detach it before removing its source.")}}
    }
  }
}
extension PaperConstructionEngine {
  public static func synchronized(_ object:ProductObject,previous:ProductObject?)throws->ProductObject {
    var object=object,source=try definition(for:object)
    if let previous,PaperConstruction.isPaper(previous){let old=try definition(for:previous);if try old.net().panels != source.net().panels,object.artwork != nil || object.artworkSourceID != nil || source.insideArtwork != nil || source.insideArtworkSourceID != nil{source.artworkReviewRequired=true;if source.artworkReferenceSize==nil{source.artworkReferenceSize=try old.net().size}}}
    object.paperConstruction=source;return object
  }
}
