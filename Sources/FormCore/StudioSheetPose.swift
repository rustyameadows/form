import Foundation

/// Optional presentation overrides. The publication, artwork, stock and binding
/// dimensions remain on the canonical physical source.
public struct StudioSheetPose:Codable,Equatable,Sendable {
  public var openingDegrees:Double?
  public var activeSpread:Int?
  public var bendMM:Double?
  public var bindingStyle:SheetBindingStyle?
  public init(openingDegrees:Double?=nil,activeSpread:Int?=nil,bendMM:Double?=nil,bindingStyle:SheetBindingStyle?=nil) {
    self.openingDegrees=openingDegrees;self.activeSpread=activeSpread;self.bendMM=bendMM;self.bindingStyle=bindingStyle
  }
  public var isEmpty:Bool {openingDegrees==nil && activeSpread==nil && bendMM==nil && bindingStyle==nil}
  public func validate()throws {
    guard openingDegrees.map({$0.isFinite && (0...180).contains($0)}) ?? true,
      activeSpread.map({(0...200).contains($0)}) ?? true,
      bendMM.map({$0.isFinite && (0...20).contains($0)}) ?? true else {
      throw FormError.invalid("A publication instance needs an opening of 0–180°, a valid spread and a bend of 0–20 mm.")
    }
  }
  public func applying(to source:ProductObject,in project:Project,clampingSpread:Bool=false)throws->ProductObject {
    try validate()
    guard var definition=source.sheetAssembly else {throw FormError.invalid("Publication pose controls require an ordered-sheet source.")}
    if let openingDegrees {definition.openingDegrees=openingDegrees}
    if let activeSpread {
      // A source page edit may shorten an already accepted scene. Rendering can
      // bound its effective view without rewriting that scene's saved metadata.
      // Authoring calls retain strict validation unless they opt into this view.
      var spread=activeSpread
      if clampingSpread {spread=min(spread,try project.resolvedSheetAssembly(source).leaves.count)}
      definition.activeSpread=spread
    }
    if let bendMM {definition.bendMM=bendMM}
    if let bindingStyle {
      var binding=definition.binding ?? .init();binding.style=bindingStyle;definition.binding=binding
    }
    var result=source;result.sheetAssembly=definition
    _ = try project.resolvedSheetAssembly(result)
    return result
  }
}


extension StudioInstance {
  /// A newly duplicated copy starts at the visible, valid position. The original
  /// accepted instance and the canonical source remain unchanged.
  public func effectiveSheetPose(in project:Project)throws->StudioSheetPose? {
    guard var pose=sheetPose else{return nil};try pose.validate()
    guard let source=project.objects.first(where:{$0.id==sourceObjectID}) else{return pose}
    let effective=try pose.applying(to:source,in:project,clampingSpread:true)
    if pose.activeSpread != nil {pose.activeSpread=effective.sheetAssembly?.activeSpread}
    return pose
  }
}
