import Foundation

extension ProductObject {
  public var isCanvasWorkspace: Bool { canvasWorkspace == true }
}

extension Project {
  public var canvasWorkspace: ProductObject? { objects.first { $0.isCanvasWorkspace } }

  /// One saved, unframed editing surface. It has no physical Table or print face.
  @discardableResult public mutating func ensureCanvasWorkspace() throws -> ProductObject {
    try validateCanvasWorkspace()
    if let existing = canvasWorkspace { return existing }
    var workspace = try makeObject(recipeID:"artboard",name:"Canvas",
      parameters:["width":2000,"depth":2000])
    workspace.canvasWorkspace = true
    var artwork = Artwork(background:"#FFFFFF",bleed:0)
    artwork.backgroundOpacity = 0
    artwork.canvasPosition = .init()
    artwork.unit = .mm
    workspace.artwork = artwork
    var candidate = self
    candidate.objects.append(workspace)
    try candidate.validateCanvasWorkspace()
    self = candidate
    return workspace
  }

  public func validateCanvasWorkspace() throws {
    let workspaces = objects.filter { $0.isCanvasWorkspace }
    guard workspaces.count <= 1 else { throw FormError.invalid("A project has one shared Canvas workspace.") }
    guard let workspace = workspaces.first else { return }
    guard workspace.recipeID == "artboard",workspace.artwork != nil,workspace.artworkSourceID == nil,
      workspace.componentDefinition != true,workspace.asset == nil,workspace.textile == nil,
      workspace.artwork?.canvasPosition == nil || workspace.artwork?.canvasPosition == Point2(),
      objects.allSatisfy({ $0.id == workspace.id || $0.designID != workspace.designID }) else {
      throw FormError.invalid("The Canvas workspace must be an independent unframed artwork container at the canvas origin.")
    }
    guard objects.allSatisfy({ object in
      object.artworkSourceID != workspace.id
        && object.artwork?.elements.contains(where: { $0.component?.sourceObjectID == workspace.id }) != true
    }) else { throw FormError.invalid("Place Canvas artwork on a frame before linking it to a physical face or component.") }
  }

  /// Move selected roots and descendants to another frame, retaining physical
  /// canvas placement. `offset` overrides source.canvasPosition-target.canvasPosition.
  /// Artwork assets/styles already belong to this project and keep their identities.
  @discardableResult public mutating func transferArtwork(
    from sourceID: UUID,to targetID: UUID,ids: Set<UUID>,offset: Point2? = nil
  ) throws -> Set<UUID> {
    guard let source = objects.first(where: { $0.id == sourceID }),
      let target = objects.first(where: { $0.id == targetID }) else {
      throw FormError.missing("Choose existing source and destination artwork objects.")
    }
    let sourceOwner = artworkOwner(source),targetOwner = artworkOwner(target)
    guard sourceOwner.id != targetOwner.id,sourceOwner.designID != targetOwner.designID,
      sourceOwner.recipeID == "artboard",targetOwner.recipeID == "artboard" else {
      throw FormError.invalid("Transfer artwork between different independent frames or the Canvas workspace.")
    }
    guard !source.locked,!target.locked,!sourceOwner.locked,!targetOwner.locked else {
      throw FormError.invalid("Unlock the source and destination artwork objects before moving artwork.")
    }
    guard let sourceArtwork = sourceOwner.artwork,!ids.isEmpty,
      ids.isSubset(of:Set(sourceArtwork.elements.map(\.id))) else {
      throw FormError.invalid("Select existing source artwork layers to transfer.")
    }
    try validateArtwork(sourceArtwork)
    let roots = sourceArtwork.selectionRoots(ids)
    guard !roots.contains(where: { sourceArtwork.isLocked($0) }) else {
      throw FormError.invalid("Unlock the selected layers before moving them to another frame.")
    }
    // Inherited group appearance cannot be silently dropped by reparenting an
    // individual child. Moving its enclosing visual group preserves that intent.
    for root in roots {
      var parent = root.parentID
      while let id = parent,let ancestor = sourceArtwork.elements.first(where: { $0.id == id }) {
        guard ancestor.clipID == nil,(ancestor.opacity ?? 1) == 1,!ancestor.hasActiveEffects,
          ancestor.blendMode == nil || ancestor.blendMode == "normal",
          ancestor.isolatedBlending != true,ancestor.booleanOperation == nil,ancestor.component == nil else {
          throw FormError.invalid("Select the enclosing clipping, appearance, or component group to preserve its appearance while transferring artwork.")
        }
        parent = ancestor.parentID
      }
    }
    let sourcePosition = sourceOwner.isCanvasWorkspace ? Point2() : sourceArtwork.canvasPosition ?? .init()
    let targetPosition = targetOwner.isCanvasWorkspace ? Point2() : targetOwner.artwork?.canvasPosition ?? .init()
    let translation = offset ?? .init(sourcePosition.x-targetPosition.x,sourcePosition.y-targetPosition.y)
    guard translation.x.isFinite,translation.y.isFinite,abs(translation.x)<=100000,abs(translation.y)<=100000 else {
      throw FormError.invalid("Transfer offsets must be finite millimeter values within ±100000.")
    }
    let delta = Affine2.translation(translation.x,translation.y)
    let rootIDs = Set(roots.map(\.id)),all = sourceArtwork.descendants(of:rootIDs)
    let byID = Dictionary(uniqueKeysWithValues:sourceArtwork.elements.map { ($0.id,$0) })
    var destination = targetOwner.artwork ?? Artwork(background:"#FFFFFF")
    try validateArtwork(destination)
    let destinationIDs = Set(destination.elements.map(\.id))
    let mapping = Dictionary(uniqueKeysWithValues:all.map { ($0,destinationIDs.contains($0) ? UUID() : $0) })
    func detached(_ original:ArtworkElement,id:UUID) -> ArtworkElement {
      var result = original
      result.id = id
      let parent = original.parentID.flatMap { byID[$0] }.map { sourceArtwork.worldTransform($0) } ?? .init()
      result.affine = delta.followed(by:parent).followed(by:original.affine ?? .init())
      result.parentID = nil
      return result
    }
    // A clipping mask can be shared by roots that stay behind. Copy only the
    // required mask; preserve the original source relationship for every other use.
    let externalMasks = Set(sourceArtwork.elements.filter { all.contains($0.id) }.compactMap(\.clipID)).subtracting(all)
    var maskMapping:[UUID:UUID] = [:],maskCopies:[ArtworkElement] = []
    for id in externalMasks.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let mask = byID[id] else { throw FormError.invalid("The source clipping mask is missing.") }
      let copyID = UUID(); maskMapping[id] = copyID
      var copy = detached(mask,id:copyID)
      PathCommands.refreshNodeIDs(in:&copy)
      maskCopies.append(copy)
    }
    var moved:[ArtworkElement] = []
    let destinationNodeIDs = Set(destination.elements.flatMap { $0.path?.contours.flatMap(\.nodes).map(\.id) ?? [] })
    for original in sourceArtwork.elements where all.contains(original.id) {
      var result = rootIDs.contains(original.id) ? detached(original,id:mapping[original.id]!) : original
      result.id = mapping[original.id]!
      if !rootIDs.contains(original.id),let parent = original.parentID { result.parentID = mapping[parent] ?? parent }
      if let clip = original.clipID { result.clipID = maskMapping[clip] ?? mapping[clip] ?? clip }
      if result.path?.contours.flatMap(\.nodes).contains(where: { destinationNodeIDs.contains($0.id) }) == true {
        PathCommands.refreshNodeIDs(in:&result)
      }
      moved.append(result)
    }
    var remaining = sourceArtwork
    try remaining.transferSewingLayout(to: &destination, moved: all, mapping: mapping)
    remaining.elements.removeAll { all.contains($0.id) }
    let retainedMaskIDs = Set(remaining.elements.compactMap(\.clipID)).intersection(all)
    for id in retainedMaskIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard var copy = byID[id] else { throw FormError.invalid("The source clipping mask is missing.") }
      copy.id = UUID(); PathCommands.refreshNodeIDs(in:&copy)
      for i in remaining.elements.indices where remaining.elements[i].clipID == id { remaining.elements[i].clipID = copy.id }
      remaining.elements.append(copy)
    }
    destination.elements.append(contentsOf:maskCopies+moved)
    for var seam in sourceArtwork.sewingSeams ?? [] {
      let first = all.contains(seam.first.elementID), second = all.contains(seam.second.elementID)
      guard first == second else { throw FormError.invalid("Transfer both joined sewing pieces together, or remove their seam pairing first.") }
      if first {
        remaining.sewingSeams?.removeAll { $0.id == seam.id }
        if destination.sewingSeams?.contains(where: { $0.id == seam.id }) == true { seam.id = UUID() }
        seam.first=destination.remappingSewingEnd(seam.first,to:mapping[seam.first.elementID]!,from:sourceArtwork)
        seam.second=destination.remappingSewingEnd(seam.second,to:mapping[seam.second.elementID]!,from:sourceArtwork)
        destination.sewingSeams = (destination.sewingSeams ?? []) + [seam]
      }
    }
    if remaining.sewingSeams?.isEmpty == true { remaining.sewingSeams = nil }
    try validateArtwork(remaining); try validateArtwork(destination)
    var candidate = self
    try PublicationCommands.transferFrames(in:&candidate,from:sourceOwner.id,to:targetOwner.id,mapping:mapping)
    try candidate.transferGarmentBlockBindings(from:sourceOwner.id,to:targetOwner.id,moved:all,mapping:mapping,destination:destination)
    try candidate.setArtwork(remaining,for:sourceOwner.id,recordingStyleOverrides:false)
    try candidate.setArtwork(destination,for:targetOwner.id,recordingStyleOverrides:false)
    try candidate.validateArtworkLinks()
    self = candidate
    return Set(rootIDs.map { mapping[$0]! })
  }
}
