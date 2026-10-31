import CoreGraphics
import CryptoKit
import FormCore
import Foundation

/// Ephemeral geometry; the document retains the editable operands, never a stale
/// boolean mesh. Paint, names, locks, and a group's placement do not enter keys.
@MainActor public enum BooleanGeometry {
  private struct Node: Codable {
    var kind: String
    var transform: Affine2
    var width: Double
    var height: Double
    var path: VectorPath?
    var corner: Double?
    var sides: Int?
    var inset: Double?
    var operation: String?
    var children: [Node]
    var mask: [Node]
  }
  private final class Cached: NSObject {
    let path: CGPath
    let definition: VectorPath
    init(_ path: CGPath, definition: VectorPath) {
      self.path = path
      self.definition = definition
    }
  }
  private static let cache: NSCache<NSString, Cached> = {
    let cache = NSCache<NSString, Cached>()
    cache.countLimit = 256
    cache.totalCostLimit = 64_000_000
    return cache
  }()
  private static var builds = 0
  private static var hits = 0
  private static var hierarchyIndexes = 0
  private static var lastMilliseconds = 0.0
  private static var lastError: String?
  public static var diagnostics: [String: Any] {
    var result: [String: Any] = [
      "geometry_builds": builds, "cache_hits": hits, "hierarchy_indexes": hierarchyIndexes,
      "last_build_ms": lastMilliseconds,
      "cache_limit_bytes": 64_000_000,
    ]
    if let lastError { result["error"] = lastError }
    return result
  }
  public static func resetDiagnostics() {
    builds = 0
    hits = 0
    hierarchyIndexes = 0
    lastMilliseconds = 0
    lastError = nil
    cache.removeAllObjects()
  }

  private struct Index {
    let children: [UUID?: [ArtworkElement]]
    let byID: [UUID: ArtworkElement]
    let masks: Set<UUID>
  }
  private static func index(_ art: Artwork) -> Index {
    hierarchyIndexes += 1
    return .init(children: Dictionary(grouping: art.elements, by: \.parentID),
      byID: Dictionary(uniqueKeysWithValues: art.elements.map { ($0.id, $0) }),
      masks: Set(art.elements.compactMap(\.clipID)))
  }
  private static func snapshot(_ element: ArtworkElement, index: Index, root: Bool = false)
    throws -> Node
  {
    func build(_ e: ArtworkElement, depth: Int, root: Bool) throws -> Node {
      guard depth <= 16, e.kind == "group" || BooleanCommands.shapeKinds.contains(e.kind) else {
        throw FormError.invalid("Boolean operands need compatible vectors within 16 group levels.")
      }
      let group = e.kind == "group"
      var node = Node(
        kind: e.kind, transform: root ? .init() : e.localTransform,
        width: group ? 0 : e.width, height: group ? 0 : e.height, path: group ? nil : e.path,
        corner: e.cornerRadius, sides: e.sides, inset: e.starInset, operation: e.booleanOperation,
        children: [], mask: [])
      if group {
        node.children = try (index.children[e.id] ?? []).filter {
          $0.hidden != true && !index.masks.contains($0.id)
        }.map { try build($0, depth: depth + 1, root: false) }
      }
      if !root, let id = e.clipID, let mask = index.byID[id] {
        guard !ArtworkMasks.isCoverage(e.clipMode) else {
          throw FormError.invalid("Boolean operands cannot flatten alpha or luminance masks. Keep the mask on the enclosing result.")
        }
        node.mask = [try build(mask, depth: depth + 1, root: false)]
      }
      return node
    }
    return try build(element, depth: 0, root: root)
  }
  private static func evaluate(_ node: Node) throws -> CGPath {
    let local: CGPath
    if node.kind == "group" {
      let paths = try node.children.map(evaluate)
      var result = paths.first ?? CGMutablePath()
      for path in paths.dropFirst() {
        switch node.operation ?? "union" {
        case "union": result = result.union(path)
        case "subtract": result = result.subtracting(path)
        case "intersect": result = result.intersection(path)
        case "exclude": result = result.symmetricDifference(path)
        default: throw FormError.invalid("Unknown live boolean operation.")
        }
      }
      local = result
    } else {
      var shape = ArtworkElement(
        kind: node.kind, x: 0, y: 0, width: node.width, height: node.height)
      shape.path = node.path
      shape.cornerRadius = node.corner
      shape.sides = node.sides
      shape.starInset = node.inset
      local = VectorGeometry.path(shape).normalized(
        using: node.path?.evenOdd == true ? .evenOdd : .winding)
    }
    var transform = node.transform.cg
    var result = local.copy(using: &transform) ?? local
    if let mask = node.mask.first { result = result.intersection(try evaluate(mask)) }
    return result
  }
  private static func definition(_ path: CGPath, size: Point2) throws -> VectorPath {
    if path.isEmpty { return .init(width: size.x, height: size.y, contours: []) }
    let geometry = try VectorGeometry.element(from: path, color: "#000000")
    var result = geometry.path!
    for c in result.contours.indices {
      result.contours[c].nodes = result.contours[c].nodes.map {
        PathCommands.transformed($0, by: .translation(geometry.x, geometry.y))
      }
    }
    result.width = size.x
    result.height = size.y
    result.evenOdd = false
    return result
  }
  private static func resolved(_ group: ArtworkElement, index: Index) throws -> Cached {
    let node = try snapshot(group, index: index, root: true)
    let data = try JSONEncoder.form.encode(node)
    let key =
      (SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      + "-\(group.paintSize.x)-\(group.paintSize.y)") as NSString
    if let value = cache.object(forKey: key) {
      hits += 1
      return value
    }
    let start = Date.timeIntervalSinceReferenceDate
    let path = try evaluate(node)
    let vector = try definition(path, size: group.paintSize)
    let value = Cached(path, definition: vector)
    cache.setObject(
      value, forKey: key, cost: max(1, vector.contours.reduce(0) { $0 + $1.nodes.count }) * 128)
    builds += 1
    lastMilliseconds = (Date.timeIntervalSinceReferenceDate - start) * 1000
    lastError = nil
    return value
  }
  public static func path(_ group: ArtworkElement, in art: Artwork) throws -> CGPath {
    try resolved(group, index: index(art)).path
  }

  public static func proxy(_ group: ArtworkElement, in art: Artwork, normalize: Bool = false) throws
    -> ArtworkElement
  {
    try proxy(group, index: index(art), normalize: normalize)
  }
  private static func proxy(_ group: ArtworkElement, index: Index, normalize: Bool = false) throws
    -> ArtworkElement
  {
    let value = try resolved(group, index: index)
    var result = group
    let size = group.paintSize
    result.kind = "path"
    result.booleanOperation = nil
    result.contentSize = nil
    result.x = 0
    result.y = 0
    result.width = size.x
    result.height = size.y
    result.affine = group.localTransform
    result.rotation = nil
    result.flipX = nil
    result.flipY = nil
    result.path = value.definition
    if normalize { PathCommands.normalize(&result, preservingPaint: true) }
    return result
  }
  public static func materialized(_ art: Artwork) throws -> Artwork {
    let groups = art.elements.filter { $0.booleanOperation != nil }
    guard !groups.isEmpty else { return art }
    let index = index(art)
    var removed = Set<UUID>()
    var replacements: [UUID: ArtworkElement] = [:]
    do {
      for group in groups where group.hidden != true || index.masks.contains(group.id) {
        var parent = group.parentID
        var skip = false
        while let id = parent, let ancestor = index.byID[id] {
          if ancestor.booleanOperation != nil || (ancestor.hidden == true && !index.masks.contains(ancestor.id)) {
            skip = true
            break
          }
          parent = ancestor.parentID
        }
        if skip { continue }
        replacements[group.id] = try proxy(group, index: index)
        var stack = [group.id]
        while let id = stack.popLast() {
          for child in index.children[id] ?? [] where removed.insert(child.id).inserted {
            stack.append(child.id)
          }
        }
      }
    } catch {
      lastError = error.localizedDescription
      throw error
    }
    var result = art
    result.elements = art.elements.compactMap {
      removed.contains($0.id) ? nil : replacements[$0.id] ?? $0
    }
    return result
  }

  public struct Region {
    public let path: CGPath
    public let owner: ArtworkElement
  }
  public static func divide(_ operands: [ArtworkElement], in art: Artwork) throws -> [Region] {
    guard (2...16).contains(operands.count) else {
      throw FormError.invalid("Divide supports 2–16 vector operands.")
    }
    var cells: [Region] = []
    let index = index(art)
    var occupied: CGPath = CGMutablePath()
    for operand in operands {
      let path = try evaluate(snapshot(operand, index: index))
      var next: [Region] = []
      func append(_ path: CGPath, owner: ArtworkElement) throws {
        for piece in path.componentsSeparated() where !piece.isEmpty {
          next.append(.init(path: piece, owner: owner))
          guard next.count <= 512 else {
            throw FormError.invalid("Divide exceeds 512 editable regions. Use fewer operands.")
          }
        }
      }
      for cell in cells {
        try append(cell.path.intersection(path), owner: operand)
        try append(cell.path.subtracting(path), owner: cell.owner)
      }
      try append(path.subtracting(occupied), owner: operand)
      cells = next
      occupied = occupied.union(path)
    }
    return cells
  }
  public static func regionElement(_ region: Region, in art: Artwork, name: String) throws
    -> ArtworkElement
  {
    let owner = region.owner
    let (paint, map, opacity) = BooleanCommands.appearance(of: owner, in: art)
    guard let inverse = map.inverse else {
      throw FormError.invalid("The region transform is singular.")
    }
    var t = inverse.cg
    let path = region.path.copy(using: &t) ?? region.path
    var result = paint
    result.id = UUID()
    result.kind = "path"
    result.booleanOperation = nil
    result.name = name
    let size = paint.paintSize
    result.x = 0
    result.y = 0
    result.width = size.x
    result.height = size.y
    result.affine = map
    result.rotation = nil
    result.flipX = nil
    result.flipY = nil
    result.opacity = opacity == 1 ? nil : opacity
    result.parentID = owner.parentID
    result.clipID = owner.clipID
    result.clipMode = owner.clipMode
    result.productionRole = owner.productionRole
    result.contentSize = nil
    result.path = try definition(path, size: .init(result.width, result.height))
    PathCommands.normalize(&result, preservingPaint: true)
    return result
  }
}
