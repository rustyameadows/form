import Foundation

extension ProductObject {
  public var supportsArtworkFace: Bool {
    recipeID == "clock" || self["width"] > 0 && self["depth"] > 0
  }
  public var artworkSize: Point2 {
    recipeID == "clock"
      ? .init(self["diameter"], self["diameter"])
      : .init(max(10, self["width"]), max(10, self["depth"]))
  }
}

extension Project {
  public func artworkOwner(_ object: ProductObject) -> ProductObject {
    var current = object
    var visited = Set<UUID>()
    while let id = current.artworkSourceID, visited.insert(current.id).inserted,
      let next = objects.first(where: { $0.id == id })
    { current = next }
    return current
  }
  public func editableArtwork(_ object: ProductObject) -> Artwork? { artworkOwner(object).artwork }
  public func artworkSize(_ object: ProductObject) -> Point2 { artworkOwner(object).artworkSize }
  /// Resolve the shared document at physical surface scale, keeping editor-only
  /// data out of render signatures. Source files and source typography stay intact.
  public func surfaceArtwork(_ object: ProductObject) -> Artwork? {
    let owner = artworkOwner(object)
    guard var art = owner.artwork else { return nil }
    if owner.id != object.id {
      let source = owner.artworkSize
      let target = object.artworkSize
      let factor = object.artworkFit == "fit" ? min(target.x / source.x, target.y / source.y) : 1
      let scale = Affine2.translation(
        (target.x - source.x * factor) / 2, (target.y - source.y * factor) / 2
      )
      .followed(by: .scale(factor, factor))
      for i in art.elements.indices where art.elements[i].parentID == nil {
        art.elements[i].affine = scale.followed(by: art.elements[i].affine ?? .init())
      }
      if var boundary = art.boundary {
        for c in boundary.contours.indices {
          boundary.contours[c].nodes = boundary.contours[c].nodes.map {
            PathCommands.transformed($0, by: scale)
          }
        }
        art.boundary = boundary
      }
    }
    if object.recipeID == "clock" {
      art.boundary = ClockDesign.boundary(diameter: object["diameter"], bore: object["bore"])
    }
    return art
  }
  public mutating func setArtwork(_ artwork: Artwork, for objectID: UUID) throws {
    try validateArtwork(artwork)
    guard let object = objects.first(where: { $0.id == objectID }) else {
      throw FormError.missing("Object not found.")
    }
    let owner = artworkOwner(object)
    for i in objects.indices where objects[i].designID == owner.designID {
      objects[i].artwork = artwork
    }
  }
  public mutating func linkArtwork(_ objectID: UUID, sourceID: UUID?, fit: String = "actual") throws
  {
    guard let i = objects.firstIndex(where: { $0.id == objectID }) else {
      throw FormError.missing("Object not found.")
    }
    guard objects[i].supportsArtworkFace else {
      throw FormError.invalid("This object has no supported flat artwork surface.")
    }
    guard ["actual", "fit"].contains(fit) else {
      throw FormError.invalid("Artwork fit must be actual or fit.")
    }
    if let sourceID {
      guard sourceID != objectID, let source = objects.first(where: { $0.id == sourceID }),
        source.recipeID == "artboard", source.artworkSourceID == nil, source.artwork != nil
      else {
        throw FormError.invalid("Choose an artwork sheet in this project as the source.")
      }
    }
    let design = objects[i].designID
    // Detachment bakes the current placement so the physical result is preserved.
    var detached = sourceID == nil ? surfaceArtwork(objects[i]) : nil
    if objects[i].recipeID == "clock" { detached?.boundary = nil }
    var candidate = self
    for n in candidate.objects.indices where candidate.objects[n].designID == design {
      candidate.objects[n].artworkSourceID = sourceID
      candidate.objects[n].artworkFit = sourceID == nil ? nil : fit
      candidate.objects[n].artwork = sourceID == nil ? detached : nil
    }
    try candidate.validateArtworkLinks()
    self = candidate
  }
  public func validateArtworkLinks() throws {
    for object in objects {
      guard object.artworkFit == nil || ["actual", "fit"].contains(object.artworkFit!) else {
        throw FormError.invalid("Unknown artwork fitting mode.")
      }
      if object.artworkSourceID != nil {
        guard object.supportsArtworkFace, object.artwork == nil else {
          throw FormError.invalid(
            "A linked surface must be a supported flat product without inline artwork.")
        }
        var current = object
        var visited = Set<UUID>()
        while let id = current.artworkSourceID {
          guard visited.insert(current.id).inserted,
            let source = objects.first(where: { $0.id == id }), source.recipeID == "artboard",
            source.artworkSourceID == nil
          else {
            throw FormError.invalid("Artwork links must reference existing sheets without cycles.")
          }
          current = source
        }
        guard current.artwork != nil else {
          throw FormError.invalid("The linked artwork document is empty.")
        }
      }
    }
  }
  public mutating func detachArtworkConsumers(of ids: Set<UUID>) {
    let snapshots = objects.filter { !ids.contains($0.id) && ids.contains(artworkOwner($0).id) }
      .map { object -> (UUID, Artwork?) in
        var art = surfaceArtwork(object)
        if object.recipeID == "clock" { art?.boundary = nil }
        return (object.id, art)
      }
    for (id, art) in snapshots {
      if let i = objects.firstIndex(where: { $0.id == id }) {
        objects[i].artwork = art
        objects[i].artworkSourceID = nil
        objects[i].artworkFit = nil
      }
    }
  }
}
