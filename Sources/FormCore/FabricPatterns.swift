import Foundation

/// A project-scoped design on an actual fabric. Dimensions are millimeters, independent of pixels.
public struct FabricPattern: Codable, Equatable, Sendable {
  public enum Repeat: String, Codable, CaseIterable, Sendable {
    case straight, halfDrop, brick, mirror
    public var name: String {
      switch self { case .straight: return "Straight"; case .halfDrop: return "Half drop"; case .brick: return "Brick"; case .mirror: return "Mirror" }
    }
  }
  public var sourceObjectID: UUID
  public var repeatMode: Repeat = .straight
  public var scale = 1.0
  public var spacing = Point2()
  public var offset = Point2()
  public var rotation = 0.0
  public var outputWidth = 1400.0
  public var outputLength = 1000.0
  public var includeTileBackground = false
  public var colorways: [FabricColorway] = []
  public var activeColorwayID: UUID?
  public init(sourceObjectID: UUID) { self.sourceObjectID = sourceObjectID }
  private enum CodingKeys: String, CodingKey {
    case sourceObjectID, repeatMode, scale, spacing, offset, rotation, outputWidth, outputLength, includeTileBackground, colorways, activeColorwayID
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sourceObjectID = try c.decode(UUID.self, forKey: .sourceObjectID)
    repeatMode = try c.decodeIfPresent(Repeat.self, forKey: .repeatMode) ?? .straight
    scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    spacing = try c.decodeIfPresent(Point2.self, forKey: .spacing) ?? .init()
    offset = try c.decodeIfPresent(Point2.self, forKey: .offset) ?? .init()
    rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    outputWidth = try c.decodeIfPresent(Double.self, forKey: .outputWidth) ?? 1400
    outputLength = try c.decodeIfPresent(Double.self, forKey: .outputLength) ?? 1000
    includeTileBackground = try c.decodeIfPresent(Bool.self, forKey: .includeTileBackground) ?? false
    colorways = try c.decodeIfPresent([FabricColorway].self, forKey: .colorways) ?? []
    activeColorwayID = try c.decodeIfPresent(UUID.self, forKey: .activeColorwayID)
  }
  public func validate() throws {
    guard scale.isFinite, (0.01...100).contains(scale), rotation.isFinite, abs(rotation) <= 36000,
      [spacing.x, spacing.y].allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
      [offset.x, offset.y].allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
      [outputWidth, outputLength].allSatisfy({ $0.isFinite && (1...10000).contains($0) }),
      colorways.count <= 32, Set(colorways.map(\.id)).count == colorways.count,
      activeColorwayID == nil || colorways.contains(where: { $0.id == activeColorwayID })
    else { throw FormError.invalid("Fabric patterns require finite physical dimensions, 1–10000 mm output, and a valid colorway.") }
    for colorway in colorways { try colorway.validate() }
  }
  public func cellSize(sourceSize: Point2) -> Point2 {
    .init(sourceSize.x * scale + spacing.x, sourceSize.y * scale + spacing.y)
  }
  public func supertileSize(sourceSize: Point2) -> Point2 {
    let cell = cellSize(sourceSize: sourceSize)
    return .init(cell.x * ([.halfDrop, .mirror].contains(repeatMode) ? 2 : 1),
      cell.y * ([.brick, .mirror].contains(repeatMode) ? 2 : 1))
  }
  /// From physical lattice coordinates to the finished yardage. Positive rotation follows Canvas.
  public var latticeTransform: Affine2 {
    .translation(offset.x, offset.y).followed(by: .rotation(rotation))
  }
  /// Maps the bomber's existing UVs (0.03 per millimeter) to one physically scaled supertile.
  public func bomberTextureTransform(sourceSize: Point2) -> Affine2 {
    let size = supertileSize(sourceSize: sourceSize)
    return Affine2.scale(1 / size.x, 1 / size.y)
      .followed(by: latticeTransform.inverse!)
      .followed(by: .scale(100 / 3, 100 / 3))
  }
  /// A small, finite motif set for one seamless rectangular supertile. Edge copies are intentional.
  public func motifTransforms(sourceSize: Point2) -> [Affine2] {
    let cell = cellSize(sourceSize: sourceSize), supertile = supertileSize(sourceSize: sourceSize)
    let w = sourceSize.x * scale, h = sourceSize.y * scale
    var transforms: [Affine2] = []
    for row in -1...2 { for col in -1...2 {
      let oddColumn = abs(col % 2) == 1, oddRow = abs(row % 2) == 1
      let x = Double(col) * cell.x + (repeatMode == .brick && oddRow ? cell.x / 2 : 0)
      let y = Double(row) * cell.y + (repeatMode == .halfDrop && oddColumn ? cell.y / 2 : 0)
      guard x < supertile.x - 1e-9, y < supertile.y - 1e-9, x + w > 1e-9, y + h > 1e-9 else { continue }
      let flipX = repeatMode == .mirror && oddColumn, flipY = repeatMode == .mirror && oddRow
      transforms.append(Affine2.translation(x + (flipX ? w : 0), y + (flipY ? h : 0))
        .followed(by: .scale(flipX ? -scale : scale, flipY ? -scale : scale)))
    } }
    return transforms
  }
  /// One instance of every motif, without wrapped edge copies. Export paints these across periods.
  public func canonicalMotifTransforms(sourceSize: Point2) -> [Affine2] {
    let frame = Rect2(0, 0, sourceSize.x, sourceSize.y)
    return motifTransforms(sourceSize: sourceSize).filter {
      let box = $0.bounds(frame); return box.x >= -1e-9 && box.y >= -1e-9
    }
  }
  /// The complete supertile origins needed after rotation/offset, with a hard rendering budget.
  public func tileOrigins(sourceSize: Point2, width: Double, height: Double, limit: Int = 20000) throws -> [Point2] {
    let size = supertileSize(sourceSize: sourceSize)
    guard [size.x, size.y, width, height].allSatisfy({ $0.isFinite && $0 > 0 }),
      [offset.x, offset.y, rotation].allSatisfy(\.isFinite), limit > 0,
      max(width / size.x, height / size.y) < 1e8 else {
      throw FormError.invalid("Use valid physical repeat and output dimensions.")
    }
    let box = latticeTransform.inverse!.bounds(.init(0, 0, width, height))
    let left = Int(floor(box.x / size.x)) - (repeatMode == .brick ? 1 : 0)
    let top = Int(floor(box.y / size.y)) - (repeatMode == .halfDrop ? 1 : 0)
    let right = Int(ceil(box.maxX / size.x)), bottom = Int(ceil(box.maxY / size.y))
    guard right >= left, bottom >= top, Double(right - left) * Double(bottom - top) <= Double(limit) else {
      throw FormError.invalid("This yardage needs too many repeats. Increase the repeat size, reduce the output, or export SVG.")
    }
    return (top..<bottom).flatMap { row in (left..<right).map { col in .init(Double(col) * size.x, Double(row) * size.y) } }
  }
}

public struct FabricColorway: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var name: String
  public var baseColor: String?
  /// Exact, case-insensitive paint substitutions. The editable source artwork is never changed.
  public var replacements: [String: String] = [:]
  public init(name: String, baseColor: String? = nil) { self.name = name; self.baseColor = baseColor }
  private enum CodingKeys: String, CodingKey { case id, name, baseColor, replacements }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decode(String.self, forKey: .name)
    baseColor = try c.decodeIfPresent(String.self, forKey: .baseColor)
    replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
  }
  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
      replacements.count <= 64, Set(replacements.keys.map { $0.uppercased() }).count == replacements.count
    else { throw FormError.invalid("Name each colorway and use at most 64 unique source colors.") }
    if let baseColor { try validateColor(baseColor) }
    for (source, target) in replacements { try validateColor(source); try validateColor(target) }
  }
}

public struct ResolvedFabricPattern: Codable, Equatable, Sendable {
  public var pattern: FabricPattern
  public var artwork: Artwork
  public var sourceSize: Point2
  public var baseColor: String
  public var supertileSize: Point2 { pattern.supertileSize(sourceSize: sourceSize) }
  public var renderDefinition: Self {
    var r = self; r.artwork = artwork.renderDefinition
    r.pattern.outputWidth = 1; r.pattern.outputLength = 1
    // Applied colorways are already materialized into artwork/baseColor. Names and unused paints
    // are project editing data and must never invalidate a displayed garment's geometry.
    r.pattern.colorways = []; r.pattern.activeColorwayID = nil
    return r
  }
}

extension Material {
  /// The separate resolved pattern carries all visual dependencies, including its live tile source.
  public var withoutFabricPattern: Self { var value = self; value.fabric?.pattern = nil; return value }
}

extension Project {
  public func resolvedFabricPattern(materialID: String) throws -> ResolvedFabricPattern? {
    let material = material(materialID)
    guard let pattern = material.fabric?.pattern else { return nil }
    try pattern.validate()
    guard let source = objects.first(where: { $0.id == pattern.sourceObjectID }),
      source.recipeID == "artboard", !source.isCanvasWorkspace,
      source.artworkSourceID == nil, let stored = source.artwork else {
      throw FormError.invalid("Choose an independent artwork frame as the fabric tile. Remove or relink the fabric pattern before deleting its source.")
    }
    let size = source.artworkSize, cell = pattern.cellSize(sourceSize: size)
    guard [cell.x, cell.y].allSatisfy({ $0.isFinite && (0.1...20000).contains($0) }) else {
      throw FormError.invalid("Fabric repeat cells must be at least 0.1 mm and at most 20000 mm.")
    }
    var artwork = try resolvingComponents(in: stored)
    artwork = resolvingSwatches(in: artwork)
    let colorway = pattern.colorways.first { $0.id == pattern.activeColorwayID }
    let colors = Dictionary(uniqueKeysWithValues: (colorway?.replacements ?? [:]).map { ($0.key.uppercased(), $0.value) })
    func paint(_ color: String) -> String { colors[color.uppercased()] ?? color }
    artwork.background = paint(artwork.background)
    if !pattern.includeTileBackground { artwork.backgroundOpacity = 0 }
    for i in artwork.elements.indices {
      artwork.elements[i].color = paint(artwork.elements[i].color)
      if let stroke = artwork.elements[i].stroke { artwork.elements[i].stroke?.color = paint(stroke.color) }
      if let shadow = artwork.elements[i].shadow { artwork.elements[i].shadow?.color = paint(shadow.color) }
      if let stops = artwork.elements[i].gradient?.stops { for j in stops.indices { artwork.elements[i].gradient?.stops[j].color = paint(stops[j].color) } }
      if let runs = artwork.elements[i].textRuns { for j in runs.indices { artwork.elements[i].textRuns?[j].color = paint(runs[j].color) } }
    }
    return .init(pattern: pattern, artwork: artwork, sourceSize: size, baseColor: colorway?.baseColor ?? material.color)
  }
  public func validateFabricPatterns() throws {
    for material in materials where material.fabric?.pattern != nil { _ = try resolvedFabricPattern(materialID: material.id) }
  }
  public mutating func setFabricPattern(_ pattern: FabricPattern?, materialID: String) throws {
    var candidate = self, material = material(materialID)
    guard material.fabric != nil else { throw FormError.invalid("Choose a fabric material before adding a repeat pattern.") }
    material.fabric?.pattern = pattern
    if let i = candidate.materials.firstIndex(where: { $0.id == materialID }) { candidate.materials[i] = material }
    else { candidate.materials.append(material) }
    try candidate.validateFabricPatterns()
    self = candidate
  }
  /// Global inventory updates must retain each open project's linked artwork design.
  public func mergingStudioMaterials(_ incoming: [Material]) -> [Material] {
    var result = incoming
    for local in materials where local.fabric?.pattern != nil {
      if let i = result.firstIndex(where: { $0.id == local.id }) {
        if result[i].fabric == nil { result[i].fabric = local.fabric }
        else { result[i].fabric?.pattern = local.fabric?.pattern }
      } else { result.append(local) }
    }
    return result
  }
}
