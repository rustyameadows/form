import Foundation

/// An ephemeral view of one canonical artwork source in physical millimeters.
/// Its inverse is applied before a source is validated, saved or made undoable.
public struct PhysicalArtworkFrame: Codable, Equatable, Sendable {
  public let size: Point2
  public let boundary: [Point2]
  public let sourceToLocal: Affine2
  public init(size:Point2,boundary:[Point2]=[],sourceToLocal:Affine2 = .init()) {
    self.size=size;self.boundary=boundary;self.sourceToLocal=sourceToLocal
  }
  /// Both faces retain the same registered physical net. Viewing its reverse
  /// face changes handedness once; the stored source and mesh UVs do not change.
  public static func paper(net:PaperNet,panelID:String?=nil,inside:Bool=false) throws -> Self {
    guard let panelID else {
      return .init(size:net.size,sourceToLocal:inside ? .init(a:-1,b:0,c:0,d:1,tx:net.size.x,ty:0):.init())
    }
    guard let panel=net.panels.first(where:{$0.id==panelID}),let first=panel.polygon.first else {
      throw FormError.missing("Physical artwork surface '\(panelID)' was not found.")
    }
    let angle=(panel.artworkRotationDegrees ?? 0)*Double.pi/180
    let rotation=Affine2(a:cos(angle),b:sin(angle),c:-sin(angle),d:cos(angle),tx:0,ty:0)
    let points=panel.polygon.map(rotation.apply)
    let bounds=points.dropFirst().reduce(Rect2(rotation.apply(first).x,rotation.apply(first).y,0,0)) {
      $0.union(.init($1.x,$1.y,0,0))
    }
    var transform=Affine2.translation(-bounds.x,-bounds.y).followed(by:rotation)
    if inside {
      transform=Affine2(a:-1,b:0,c:0,d:1,tx:bounds.width,ty:0).followed(by:transform)
    }
    return .init(size:.init(bounds.width,bounds.height),boundary:panel.polygon.map(transform.apply),sourceToLocal:transform)
  }
  public func display(_ source:Artwork) -> Artwork {
    guard sourceToLocal != Affine2() else{return source}
    var displayed=source
    for i in displayed.elements.indices where displayed.elements[i].parentID==nil {
      displayed.elements[i].affine=sourceToLocal.followed(by:displayed.elements[i].affine ?? .init())
    }
    displayed.guides=nil;displayed.showGrid=false;displayed.boundary=nil
    return displayed
  }
  public func source(from displayed:Artwork,original:Artwork) throws -> Artwork {
    guard sourceToLocal != Affine2() else{return displayed}
    guard let inverse=sourceToLocal.inverse else{throw FormError.invalid("The physical artwork frame is not invertible.")}
    let baseline=display(original)
    let old=Dictionary(uniqueKeysWithValues:original.elements.map{($0.id,$0)})
    let visible=Dictionary(uniqueKeysWithValues:baseline.elements.map{($0.id,$0)})
    var value=displayed
    for i in value.elements.indices where value.elements[i].parentID==nil {
      let element=value.elements[i]
      if element==visible[element.id],let unchanged=old[element.id] {value.elements[i]=unchanged}
      else {value.elements[i].affine=inverse.followed(by:element.affine ?? .init())}
    }
    value.guides=original.guides;value.showGrid=original.showGrid;value.boundary=original.boundary
    value.canvasPosition=original.canvasPosition
    return value
  }
}

/// Optional coordinate context for the existing artwork tools. It identifies an
/// existing physical source; it never creates a second artboard or artwork copy.
public struct PhysicalArtworkFrameContext: Sendable {
  public let physicalObjectID: UUID
  public let sourceObjectID: UUID
  public let frame: PhysicalArtworkFrame
  public static func resolve(in project:Project,objectID:UUID,raw:Any) throws -> Self {
    guard let options=raw as? [String:Any],Set(options.keys).isSubset(of:["surface_id","side"]),
      let physical=project.objects.first(where:{$0.id==objectID}),PaperConstruction.isPaper(physical) else {
      throw FormError.invalid("physical_frame needs an existing construction object and only surface_id/side fields.")
    }
    let side:String
    if let raw=options["side"] {guard let value=raw as? String,["outside","inside"].contains(value) else{throw FormError.invalid("Physical frame side must be outside or inside.")};side=value}
    else{side="outside"}
    let panelID:String?
    if let raw=options["surface_id"] {guard let value=raw as? String,!value.isEmpty else{throw FormError.invalid("surface_id must name an existing panel.")};panelID=value}
    else{panelID=nil}
    let construction=try PaperConstruction.definition(for:physical)
    let sourceID:UUID
    if side=="inside" {
      guard let id=construction.insideArtworkSourceID,project.objects.contains(where:{$0.id==id}) else {
        throw FormError.missing("Create the independent inside source with form_paper ensure_inside before editing its physical frame.")
      }
      sourceID=id
    } else {sourceID=project.artworkOwner(physical).id}
    return .init(physicalObjectID:objectID,sourceObjectID:sourceID,
      frame:try .paper(net:construction.net(),panelID:panelID,inside:side=="inside"))
  }
}
