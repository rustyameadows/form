import Foundation

public struct PatternAssemblyAttachment:Codable,Equatable,Sendable {
  public var surfaceObjectID:UUID
  public var anchor:PatternAssemblyAnchor
  public var rotationDegrees:Double
  public init(surfaceObjectID:UUID,anchor:PatternAssemblyAnchor,rotationDegrees:Double = 0) {self.surfaceObjectID=surfaceObjectID;self.anchor=anchor;self.rotationDegrees=rotationDegrees}
}
extension ProductObject {
  public var isFlexibleSurface:Bool {cloth != nil || patternAssembly != nil}
  public var isClothAttached:Bool {clothAttachment != nil || patternAssemblyAttachment != nil}
}
extension Project {
  /// Cheap persisted-declaration validation. A source edit can make a seam
  /// temporarily invalid; the derived preview reports that issue and drops its
  /// old runtime instead of blocking editable source or showing stale cloth.
  public func validatePatternAssemblies()throws {
    guard objects.filter({$0.patternAssembly != nil}).count<=16 else {throw FormError.invalid("A project supports at most 16 bounded pattern assembly studies.")}
    for object in objects {
      if object.recipeID=="patternAssembly",object.patternAssembly==nil {throw FormError.invalid("Create a sewn assembly from an existing pattern with form_cloth assemble; it requires explicit source panels and poses.")}
      if let assembly=object.patternAssembly {
        try assembly.validateDeclarations()
        guard !object.isCanvasWorkspace,object.cloth==nil,object.textile==nil,!object.isClothAttached,
          assembly.sourceObjectID != object.id,let source=objects.first(where:{$0.id==assembly.sourceObjectID}),source.artwork != nil,source.artworkSourceID==nil else {throw FormError.invalid("An assembly requires an independent pattern owner and a separate open surface. Remove its assembly before deleting the source owner.")}
      }
      if let attachment=object.patternAssemblyAttachment {
        guard !object.isFlexibleSurface,object.clothAttachment==nil,object.textile?.attachment==nil,
          attachment.surfaceObjectID != object.id,let parent=objects.first(where:{$0.id==attachment.surfaceObjectID}),let assembly=parent.patternAssembly,
          assembly.panels.contains(where:{$0.panel==attachment.anchor.panel}),attachment.rotationDegrees.isFinite,abs(attachment.rotationDegrees)<=36000,
          attachment.anchor.materialPointMm.x.isFinite,attachment.anchor.materialPointMm.y.isFinite,
          attachment.anchor.normalOffsetMm.isFinite,abs(attachment.anchor.normalOffsetMm)<=1000 else {throw FormError.invalid("Attach a separate object to an existing assembly panel at finite physical material coordinates.")}
      }
    }
  }
  @discardableResult public mutating func addPatternAssembly(_ definition:PatternAssemblyDefinition,name:String = "Sewn assembly")throws -> UUID {
    var candidate=self
    _ = try PatternAssemblySource.prepare(in:&candidate,objectID:definition.sourceObjectID,elements:Set(definition.panels.map{$0.panel.elementID}))
    _ = try PatternAssemblyGenerator.generate(definition,in:candidate)
    var object=try candidate.makeObject(recipeID:"patternAssembly",name:name,materialID:definition.panels[0].material.id)
    object.patternAssembly=definition;candidate.objects.append(object)
    try candidate.validatePatternAssemblies();self=candidate;return object.id
  }
  public mutating func setPatternAssembly(_ definition:PatternAssemblyDefinition,for id:UUID)throws {
    var candidate=self
    guard let i=candidate.objects.firstIndex(where:{$0.id==id}),!candidate.objects[i].locked,candidate.objects[i].patternAssembly != nil else {throw FormError.invalid("Choose an unlocked pattern assembly.")}
    let product=try PatternAssemblyGenerator.generate(definition,in:candidate)
    candidate.objects[i].patternAssembly=definition
    for object in candidate.objects where object.patternAssemblyAttachment?.surfaceObjectID==id {
      _ = try object.patternAssemblyAttachment!.anchor.resolve(in:product)
    }
    try candidate.validatePatternAssemblies();self=candidate
  }
}
