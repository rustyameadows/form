import Foundation

extension ProductObject {
  public var supportsArtworkFace: Bool {
    if PaperConstruction.isPaper(self){return true}
    if recipeID == "importedMesh" {return meshAsset?.parts.contains(where:{$0.uvSets.contains(0)}) == true}
    return !isCanvasWorkspace && recipeID != "bomberJacket" && !MerchandiseBlanks.garmentIDs.contains(recipeID) && (recipeID == "clock" || self["width"] > 0 && self["depth"] > 0)
  }
  public var artworkSize: Point2 {
    if PaperConstruction.isPaper(self),let source=try? PaperConstruction.definition(for:self),let net=try? source.net(){return net.size}
    if recipeID == "importedMesh", let size=meshAsset?.artworkSizeMM {return .init(size.width,size.height)}
    if recipeID=="deskClock" {return .init(self["width"],self["height"])}
    return recipeID == "clock"
      ? .init(self["diameter"], self["diameter"])
      : .init(self["width"] > 0 ? self["width"] : 10, self["depth"] > 0 ? self["depth"] : 10)
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
  public func surfaceArtwork(_ object: ProductObject, keepingSwatchReferences: Bool = false) -> Artwork? {
    guard !object.isCanvasWorkspace else { return nil }
    let owner = artworkOwner(object)
    guard let stored = owner.artwork else { return nil }
    let source=resolvingTextStories(in:stored,objectID:owner.id)
    var art = (try? resolvingComponents(in: source, keepingSwatchReferences: true)) ?? source
    art.requiresInkOutput=hasUsedProductionInks(in:art)
    if !keepingSwatchReferences {art=resolvingSwatches(in:art)}
    if owner.id != object.id && object.recipeID != "importedMesh" && !PaperConstruction.isPaper(object) {
      art.safeInset=nil // Frame safety is not a declaration for a scaled product projection.
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
    if object.recipeID == "deskClock" {art.boundary=DeskClockDesign.boundary(object)}
    if object.recipeID == "clock" {
      art.boundary = ClockDesign.boundary(diameter: object["diameter"], bore: object["bore"])
    }
    return art
  }
  public mutating func setArtwork(_ artwork: Artwork, for objectID: UUID,
    recordingStyleOverrides: Bool = true) throws {
    try validateArtwork(artwork)
    guard let object = objects.first(where: { $0.id == objectID }) else {
      throw FormError.missing("Object not found.")
    }
    guard object.patternAssembly==nil else {throw FormError.invalid("Edit the assembly's original pattern owner; its generated cloth is not a separate artwork source.")}
    let owner = artworkOwner(object)
    var artwork = recordingStyleOverrides
      ? artwork.recordingTextStyleOverrides(from: owner.artwork) : artwork
    artwork.requiresInkOutput=false
    if let bindings=owner.artworkParameterBindings,!bindings.isEmpty {
      try ArtworkParameterBindings.validateCanonical(bindings,source:artwork,parameters:artworkBindingParameters(for:owner))
    }
    // A shared design retains its artwork IDs. Each member resolves the shared
    // controls through its own saved bindings before artwork is propagated.
    let updates=try objects.filter{$0.designID==owner.designID}.map{variant->(UUID,Artwork) in
      if let bindings=variant.artworkParameterBindings,!bindings.isEmpty {
        return (variant.id,try ArtworkParameterBindings.applying(bindings,to:artwork,parameters:artworkBindingParameters(for:variant)))
      }
      return (variant.id,artwork)
    }
    try PublicationCommands.reconcileFrames(in:&self,objectID:owner.id,artwork:artwork)
    for (id,value) in updates {
      if let i=objects.firstIndex(where:{$0.id==id}) {objects[i].artwork=value}
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
    if PaperConstruction.isPaper(objects[i]),fit != "actual"{throw FormError.invalid("Paper artwork uses registered full-net millimeters. Use actual-size placement; automatic fit would stretch the construction artwork.")}
    guard ["actual", "fit"].contains(fit) else {
      throw FormError.invalid("Artwork fit must be actual or fit.")
    }
    if let sourceID {
      guard sourceID != objectID, let source = objects.first(where: { $0.id == sourceID }),
        isIndependentFlatArtworkSource(source), !source.isCanvasWorkspace, source.artworkSourceID == nil, source.artwork != nil
      else {
        throw FormError.invalid("Choose an artwork sheet in this project as the source.")
      }
    }
    let design = objects[i].designID
    // Detachment bakes the current placement so the physical result is preserved.
    var detached = sourceID == nil ? surfaceArtwork(objects[i], keepingSwatchReferences: true) : nil
    let sourceSize=artworkSize(objects[i])
    detached?.requiresInkOutput=false
    if ["clock","deskClock"].contains(objects[i].recipeID) { detached?.boundary = nil }
    var candidate = self
    for n in candidate.objects.indices where candidate.objects[n].designID == design {
      candidate.objects[n].artworkSourceID = sourceID
      candidate.objects[n].artworkFit = sourceID == nil ? nil : fit
      candidate.objects[n].artwork = sourceID == nil ? detached : nil
      if candidate.objects[n].recipeID == "importedMesh" {
        let size=sourceID.flatMap{id in objects.first{$0.id==id}}.map{artworkSize($0)} ?? sourceSize
        candidate.objects[n].meshAsset?.artworkSizeMM = .init(width:size.x,height:size.y)
      }
    }
    try candidate.validateArtworkLinks()
    self = candidate
  }
  public func validateArtworkLinks() throws {
    try fontLibrary?.validate()
    try validatePaperMaterialSnapshots()
    try validateArtworkParameterBindings()
    try validatePhysicalSurfaceBindings()
    try validatePhysicalArtworkIntents()
    for object in objects {
      if let positions=object.canvasProjectionPositions {
        guard positions.count<=256,positions.allSatisfy({!$0.key.isEmpty && $0.key.utf8.count<=512 && $0.value.x.isFinite && $0.value.y.isFinite && abs($0.value.x)<=100000 && abs($0.value.y)<=100000}) else {
          throw FormError.invalid("Canvas projection positions must have bounded identities and finite physical coordinates.")
        }
      }
    }
    try validatePaperConstructions()
    try validateModelRepresentations()
    try validateLibrarySelections()
    try validatePageSetups()
    try validateCollectionProduction()
    try validateGarmentBlocks()
    try validateStudioPresentation()
    try validatePublications()
    try validateCanvasWorkspace()
    try validateTextiles()
    try validateTextStyles()
    try validateSwatches()
    try validateDecorationPreparations()
    try validateComponentLinks()
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
            let source = objects.first(where: { $0.id == id }), isIndependentFlatArtworkSource(source),
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
    detachPhysicalSurfaceConsumers(of:ids)
    // Resolve instances before removing a source frame, preserving each override.
    let old = self
    for i in objects.indices where !ids.contains(objects[i].id) {
      guard let art = objects[i].artwork else { continue }
      let instances = Set(art.elements.filter { $0.component.map { ids.contains($0.sourceObjectID) } == true }.map(\.id))
      if !instances.isEmpty {
        var candidate = old
        if (try? ComponentCommands.detach(in: &candidate, objectID: objects[i].id, ids: instances, allowLocked: true)) != nil {
          objects[i].artwork = candidate.objects.first { $0.id == objects[i].id }?.artwork
        }
      }
    }
    let snapshots = objects.filter { !ids.contains($0.id) && ids.contains(artworkOwner($0).id) }
      .map { object -> (UUID, Artwork?, Point2) in
        var art = surfaceArtwork(object, keepingSwatchReferences: true)
        art?.requiresInkOutput=false
        if ["clock","deskClock"].contains(object.recipeID) { art?.boundary = nil }
        return (object.id, art, artworkSize(object))
      }
    for (id, art, size) in snapshots {
      if let i = objects.firstIndex(where: { $0.id == id }) {
        objects[i].artwork = art
        objects[i].artworkSourceID = nil
        objects[i].artworkFit = nil
        if objects[i].recipeID == "importedMesh" {objects[i].meshAsset?.artworkSizeMM = .init(width:size.x,height:size.y)}
      }
    }
  }
}
