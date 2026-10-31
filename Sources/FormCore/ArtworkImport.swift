import Foundation

public struct ArtworkImport: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var asset: String
  public var name: String
  public var width: Double
  public var height: Double
  // Project JSON stores ISO-8601 timestamps at second precision. Keep the live
  // record canonical too so save/reopen does not change provenance equality.
  public var importedAt: Date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
  public var issues: [String]
  /// All native layers produced from this source, including masks/support layers.
  /// Nil denotes legacy frame-wide provenance. A partial Copy omits shared opaque bytes.
  public var elementIDs: [UUID]?
  public var format: String?
  public init(asset: String, name: String, width: Double, height: Double, issues: [String] = [], elementIDs: [UUID]? = nil, format: String? = nil) {
    self.asset = asset
    self.name = name
    self.width = width
    self.height = height
    self.issues = issues
    self.elementIDs = elementIDs
    self.format = format
  }
}

extension Project {
  /// Insert a complete import in one document edit. Existing linked surfaces
  /// resolve to their canonical artwork source, preserving all consumer links.
  @discardableResult public mutating func importArtwork(
    _ imported: Artwork, source: ArtworkImport, targetID: UUID? = nil
  ) throws -> UUID {
    try validateArtwork(imported)
    var source = source
    source.elementIDs = imported.elements.map(\.id)
    guard (1...1000).contains(source.width), (1...1000).contains(source.height) else {
      throw FormError.invalid("Imported artwork dimensions must be 1–1000 mm.")
    }
    if let targetID {
      guard let target = objects.first(where: { $0.id == targetID }),
        target.supportsArtworkFace || target.isCanvasWorkspace
      else {
        throw FormError.invalid("Choose the Canvas workspace, an artwork frame or a supported physical face.")
      }
      let owner = artworkOwner(target)
      guard !owner.locked else {
        throw FormError.invalid("Unlock the artwork source before importing.")
      }
      var art: Artwork
      if let existing = editableArtwork(target) {
        art = existing
      } else {
        art = .init(background: "#FFFFFF")
        art.backgroundOpacity = 0
        art.bleed = 0
      }
      let offset = Affine2.translation(
        (owner.artworkSize.x - source.width) / 2, (owner.artworkSize.y - source.height) / 2)
      var layers = imported.elements
      for i in layers.indices where layers[i].parentID == nil {
        layers[i].affine = offset.followed(by: layers[i].affine ?? .init())
      }
      art.elements += layers
      art.imports = (art.imports ?? []) + [source]
      try setArtwork(art, for: owner.id)
      return owner.id
    }
    let right =
      objects.map { $0.position.x + $0.footprintWidth / 2 }.max() ?? -source.width / 2 - 60
    var object = try makeObject(
      recipeID: "artboard", name: String(source.name.prefix(500)),
      parameters: ["width": source.width, "depth": source.height],
      position: .init(right + 60 + source.width / 2, 0, 0))
    var art = imported
    art.imports = (art.imports ?? []) + [source]
    object.artwork = art
    try validateArtwork(art)
    objects.append(object)
    return object.id
  }
}
