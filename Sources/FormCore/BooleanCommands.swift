import Foundation

public enum BooleanCommands {
  public static let operations = ["union", "subtract", "intersect", "exclude"]
  public static let shapeKinds: Set<String> = ["rectangle", "ellipse", "polygon", "star", "path"]
  public static func appearance(of front: ArtworkElement, in artwork: Artwork) -> (
    element: ArtworkElement, transform: Affine2, opacity: Double
  ) {
    let masks = Set(artwork.elements.compactMap(\.clipID))
    var paint = front
    var map = front.localTransform
    var opacity = front.opacity ?? 1
    while paint.kind == "group", paint.booleanOperation == nil,
      let child = artwork.elements.last(where: {
        $0.parentID == paint.id && $0.hidden != true && !masks.contains($0.id)
      })
    {
      paint = child
      map = map.followed(by: child.localTransform)
      opacity *= child.opacity ?? 1
    }
    return (paint, map, opacity)
  }

  public static func compatible(_ element: ArtworkElement, in art: Artwork) -> Bool {
    let children = Dictionary(grouping: art.elements, by: \.parentID)
    func check(_ e: ArtworkElement, depth: Int) -> Bool {
      guard depth <= 16, e.component == nil else { return false }
      if e.kind == "group" {
        return (children[e.id] ?? []).filter { $0.hidden != true }.allSatisfy {
          check($0, depth: depth + 1)
        }
      }
      return shapeKinds.contains(e.kind)
    }
    return check(element, depth: 0)
  }

  /// Preserve operands in the frontmost shape's coordinate system. Its paint
  /// stays in place, including nonuniform stroke and affine gradient mapping.
  @discardableResult public static func create(
    _ operation: String, artwork: inout Artwork, elements ids: Set<UUID>
  ) throws -> UUID {
    let selected = artwork.selectionRoots(ids)
    guard ids.isSubset(of: Set(artwork.elements.map(\.id))), selected.count >= 2,
      selected.count <= 64, Set(selected.map(\.parentID)).count == 1,
      Set(selected.map(\.clipID)).count == 1,
      selected.allSatisfy({ compatible($0, in: artwork) }), operations.contains(operation)
    else {
      throw FormError.invalid(
        "Choose 2–64 compatible vector operands in the same group and clipping mask.")
    }
    guard selected.allSatisfy({ !artwork.isLocked($0) }) else {
      throw FormError.invalid("Unlock the selected operands first.")
    }
    let roots = Set(selected.map(\.id))
    guard !artwork.elements.contains(where: { $0.clipID.map(roots.contains) == true }) else {
      throw FormError.invalid("Release these shapes' use as clipping masks before combining them.")
    }
    let front = selected.last!
    let (paint, paintMap, opacity) = appearance(of: front, in: artwork)
    guard let inverse = paintMap.inverse else {
      throw FormError.invalid("The operand transform is singular.")
    }
    let size = paint.paintSize
    var group = ArtworkElement(
      kind: "group", x: 0, y: 0, width: size.x, height: size.y, color: paint.color)
    group.name = operation.capitalized
    group.parentID = front.parentID
    group.affine = paintMap
    group.contentSize = size
    group.booleanOperation = operation
    group.fillEnabled = paint.fillEnabled
    group.fillSwatchID = paint.fillSwatchID
    group.fillOpacity = paint.fillOpacity
    group.opacity = opacity == 1 ? nil : opacity
    group.gradient = paint.gradient
    group.stroke = paint.stroke
    group.clipID = front.clipID
    group.productionRole = front.productionRole
    var result = artwork
    for i in result.elements.indices where roots.contains(result.elements[i].id) {
      result.elements[i].affine = inverse.followed(by: result.elements[i].affine ?? .init())
      result.elements[i].parentID = group.id
      result.elements[i].clipID = nil
    }
    let frontIndex = result.elements.firstIndex { $0.id == front.id }!
    result.elements.insert(group, at: frontIndex + 1)
    try validateArtwork(result)
    artwork = result
    return group.id
  }
}
