import CryptoKit
import Foundation

private final class ResolvedComponentArtwork: NSObject {
  let artwork: Artwork
  init(_ artwork: Artwork) { self.artwork = artwork }
}
private enum ComponentResolutionCache {
  static let values: NSCache<NSString, ResolvedComponentArtwork> = {
    let cache = NSCache<NSString, ResolvedComponentArtwork>()
    cache.countLimit = 64
    cache.totalCostLimit = 64_000_000
    return cache
  }()
  static let lock = NSLock()
  static var builds = 0
  static var hits = 0
  static var lastMilliseconds = 0.0
  static func hit() { lock.lock(); hits += 1; lock.unlock() }
  static func built(_ milliseconds: Double) {
    lock.lock(); builds += 1; lastMilliseconds = milliseconds; lock.unlock()
  }
  static var diagnostics: [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["builds": builds, "cache_hits": hits, "last_build_ms": lastMilliseconds,
      "cache_limit_bytes": 64_000_000]
  }
}

public struct ArtworkComponentOverride: Codable, Equatable, Sendable {
  public var elementID: UUID
  public var color: String?
  public var colorSwatchID: UUID?
  public var text: String?
  public var opacity: Double?
  public init(elementID: UUID, color: String? = nil, text: String? = nil, opacity: Double? = nil) {
    self.elementID = elementID
    self.color = color
    self.text = text
    self.opacity = opacity
  }
}

public struct ArtworkComponentReference: Codable, Equatable, Sendable {
  public var sourceObjectID: UUID
  public var color: String?
  public var colorSwatchID: UUID?
  public var overrides: [ArtworkComponentOverride]?
  public init(sourceObjectID: UUID) { self.sourceObjectID = sourceObjectID }
}

public enum ComponentCommands {
  public static var resolutionDiagnostics: [String: Any] { ComponentResolutionCache.diagnostics }
  /// Stable derived identities keep render signatures and caches reusable.
  public static func derivedID(_ instance: UUID, _ source: UUID) -> UUID {
    var bytes = Array(SHA256.hash(data: Data((instance.uuidString + source.uuidString).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  public static func create(
    in project: inout Project, objectID: UUID, elements ids: Set<UUID>, name: String
  ) throws -> (source: UUID, instance: UUID) {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
      let object = project.objects.first(where: { $0.id == objectID }),
      var art = project.editableArtwork(object)
    else { throw FormError.invalid("Choose artwork and a component name of 1–160 characters.") }
    let roots = art.selectionRoots(ids)
    guard !roots.isEmpty, ids.isSubset(of: Set(art.elements.map(\.id))),
      Set(roots.map(\.parentID)).count == 1, Set(roots.map(\.clipID)).count == 1,
      roots.allSatisfy({ !art.isLocked($0) })
    else { throw FormError.invalid("Choose unlocked artwork in one group and clipping mask.") }
    let rootIDs = Set(roots.map(\.id))
    guard !art.elements.contains(where:{art.descendants(of:ids).contains($0.id) && $0.storyFrame != nil}) else{
      throw FormError.invalid("Unlink text-story frames before making them into a reusable component.")
    }
    guard !art.elements.contains(where: { $0.clipID.map(rootIDs.contains) == true }) else {
      throw FormError.invalid("Release the selected objects' use as clipping masks first.")
    }
    let all = art.descendants(of: rootIDs)
    var sourceArt = Artwork(background: "#FFFFFF", elements: art.elements.filter { all.contains($0.id) }, bleed: 0)
    sourceArt.language = art.language
    sourceArt.backgroundOpacity = 0
    for i in sourceArt.elements.indices where rootIDs.contains(sourceArt.elements[i].id) {
      sourceArt.elements[i].parentID = nil
      sourceArt.elements[i].clipID = nil
    }
    let copiedRoots = sourceArt.selectionRoots(rootIDs)
    let visual = sourceArt.elements.contains { $0.hasVisualOverflow }
    func box(_ e: ArtworkElement) -> Rect2 { visual ? sourceArt.visualBounds(of: e) : sourceArt.bounds(of: e) }
    let bounds = copiedRoots.dropFirst().reduce(box(copiedRoots[0])) {
      $0.union(box($1))
    }
    for i in sourceArt.elements.indices where rootIDs.contains(sourceArt.elements[i].id) {
      ArtworkCommands.translate(&sourceArt.elements[i], dx: -bounds.x, dy: -bounds.y)
    }
    try validateArtwork(sourceArt)
    var candidate = project
    var source = try candidate.makeObject(recipeID: "artboard", name: name,
      parameters: ["width": max(0.01, bounds.width), "depth": max(0.01, bounds.height)])
    source.componentDefinition = true
    source.artwork = sourceArt
    source.position = .init(object.position.x + object.footprintWidth + 100, 0, object.position.z)
    candidate.objects.append(source)
    var instance = ArtworkElement(kind: "group", x: bounds.x, y: bounds.y,
      width: max(0.01, bounds.width), height: max(0.01, bounds.height))
    instance.name = name
    instance.component = .init(sourceObjectID: source.id)
    instance.contentSize = source.artworkSize
    instance.parentID = roots[0].parentID
    instance.clipID = roots[0].clipID
    let front = art.elements.firstIndex { $0.id == roots.last!.id }!
    let insertion = art.elements[..<front].filter { !all.contains($0.id) }.count
    art.elements.removeAll { all.contains($0.id) }
    art.elements.insert(instance, at: insertion)
    try candidate.setArtwork(art, for: objectID)
    try candidate.validateArtworkLinks()
    project = candidate
    return (source.id, instance.id)
  }

  public static func insert(
    in project: inout Project, objectID: UUID, sourceID: UUID,
    x: Double = 10, y: Double = 10, width: Double? = nil, height: Double? = nil
  ) throws -> UUID {
    guard let object = project.objects.first(where: { $0.id == objectID }),
      let source = project.objects.first(where: { $0.id == sourceID }), source.componentDefinition == true
    else { throw FormError.invalid("Choose an artwork target and a component source in this project.") }
    var art = project.editableArtwork(object) ?? .init(background: "#FFFFFF")
    var instance = ArtworkElement(kind: "group", x: x, y: y,
      width: width ?? source.artworkSize.x, height: height ?? source.artworkSize.y)
    instance.component = .init(sourceObjectID: sourceID)
    instance.name = source.name
    instance.contentSize = source.artworkSize
    art.elements.append(instance)
    var candidate = project
    try candidate.setArtwork(art, for: objectID)
    try candidate.validateArtworkLinks()
    project = candidate
    return instance.id
  }

  public static func detach(in project: inout Project, objectID: UUID, ids: Set<UUID>, allowLocked: Bool = false) throws {
    guard let object = project.objects.first(where: { $0.id == objectID }),
      var art = project.editableArtwork(object), !ids.isEmpty,
      ids.isSubset(of: Set(art.elements.filter { $0.component != nil && (allowLocked || !art.isLocked($0)) }.map(\.id)))
    else { throw FormError.invalid("Select unlocked component instances to detach.") }
    let resolved = try project.resolvingComponents(in: art, keepingSwatchReferences: true)
    let groups = Dictionary(uniqueKeysWithValues: ids.map { id in
      let descendants = resolved.descendants(of: [id])
      return (id, resolved.elements.filter { descendants.contains($0.id) })
    })
    var next: [ArtworkElement] = []
    for e in art.elements {
      if ids.contains(e.id) {
        next += groups[e.id]!
      } else { next.append(e) }
    }
    art.elements = next
    try project.setArtwork(art, for: objectID)
  }
}

extension Project {
  public var artworkComponents: [ProductObject] {
    objects.filter { $0.componentDefinition == true }
  }

  public func validateComponentLinks() throws {
    guard objects.contains(where: { $0.componentDefinition == true ||
      $0.artwork?.elements.contains(where: { $0.component != nil }) == true }) else { return }
    guard Set(objects.map(\.id)).count == objects.count else {
      throw FormError.invalid("Project object identities must be unique.")
    }
    let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
    typealias Cost = (elements: Int, nodes: Int, levels: Int)
    var costs: [UUID: Cost] = [:]
    func cost(_ object: ProductObject, visiting: Set<UUID>, depth: Int) throws -> Cost {
      guard depth <= 8, !visiting.contains(object.id) else {
        throw FormError.invalid("Component references must be acyclic and at most eight levels deep.")
      }
      if let cached = costs[object.id] {
        guard depth + cached.levels <= 8 else { throw FormError.invalid("Component nesting exceeds eight levels.") }
        return cached
      }
      var count = 0
      var nodes = 0
      var levels = 0
      for e in object.artwork?.elements ?? [] {
        count += 1
        nodes += (e.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? 0) + e.text.utf16.count
        if let ref = e.component {
          guard let source = byID[ref.sourceObjectID], source.componentDefinition == true,
            source.recipeID == "artboard", source.artwork != nil, source.artworkSourceID == nil
          else { throw FormError.invalid("A component must reference an existing independent source frame.") }
          let nested = try cost(source, visiting: visiting.union([object.id]), depth: depth + 1)
          count += nested.0 + 2
          nodes += nested.1
          for change in ref.overrides ?? [] {
            if let text = change.text,
              let original = source.artwork?.elements.first(where: { $0.id == change.elementID && $0.kind == "text" }) {
              nodes += text.utf16.count - original.text.utf16.count
            }
          }
          levels = max(levels, nested.levels + 1)
        }
        guard count <= 10000, nodes <= 300000 else {
          throw FormError.invalid("Expanded component artwork exceeds 10,000 elements or 300,000 nodes.")
        }
      }
      costs[object.id] = (count, nodes, levels)
      return (count, nodes, levels)
    }
    for object in objects {
      if object.componentDefinition == true {
        guard object.recipeID == "artboard", object.artwork != nil, object.artworkSourceID == nil else {
          throw FormError.invalid("Component sources must be independent artwork frames.")
        }
      }
      if object.componentDefinition == true || object.artwork?.elements.contains(where: { $0.component != nil }) == true {
        if let art = object.artwork { try validateArtwork(art) }
        _ = try cost(object, visiting: [], depth: 0)
      }
    }
  }

  /// Derived ordinary groups, paths and text. Never persist this over a linked instance.
  public func resolvingComponents(in stored: Artwork, keepingSwatchReferences: Bool = false) throws -> Artwork {
    let art = resolvingSwatches(in: stored, keepingReferences: keepingSwatchReferences)
    guard art.elements.contains(where: { $0.component != nil }) else { return art }
    let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
    struct SourceSnapshot: Codable {
      let id: UUID
      let name: String
      let size: Point2
      let artwork: Artwork
    }
    struct Snapshot: Codable {
      let artwork: Artwork
      let sources: [SourceSnapshot]
    }
    var sources: [UUID: SourceSnapshot] = [:]
    func collect(_ id: UUID, stack: Set<UUID>, depth: Int) throws {
      guard depth <= 8, !stack.contains(id), let source = byID[id],
        source.componentDefinition == true, source.artworkSourceID == nil, let artwork = source.artwork
      else { throw FormError.invalid("Missing, cyclic, or excessively nested component source.") }
      if sources[id] != nil { return }
      sources[id] = .init(id: id, name: source.name, size: source.artworkSize,
        artwork: resolvingSwatches(in: artwork, keepingReferences: keepingSwatchReferences))
      for reference in artwork.elements.compactMap(\.component) {
        try collect(reference.sourceObjectID, stack: stack.union([id]), depth: depth + 1)
      }
    }
    for reference in art.elements.compactMap(\.component) {
      try collect(reference.sourceObjectID, stack: [], depth: 1)
    }
    let snapshot = Snapshot(artwork: art, sources: sources.values.sorted { $0.id.uuidString < $1.id.uuidString })
    let key = SHA256.hash(data: try JSONEncoder.form.encode(snapshot)).map { String(format: "%02x", $0) }.joined() as NSString
    if let cached = ComponentResolutionCache.values.object(forKey: key) {
      ComponentResolutionCache.hit()
      return cached.artwork
    }
    let started = Date.timeIntervalSinceReferenceDate
    func paint(_ color: String, swatchID: UUID? = nil, on e: inout ArtworkElement) {
      guard e.kind != "group" || e.booleanOperation != nil, e.kind != "image" else { return }
      e.color = color
      e.fillSwatchID = swatchID
      e.gradient = nil
      for i in e.textRuns?.indices ?? 0..<0 {
        e.textRuns?[i].color = color
        e.textRuns?[i].swatchID = swatchID
      }
    }
    func expand(_ input: Artwork, stack: Set<UUID>, depth: Int) throws -> Artwork {
      guard depth <= 8 else { throw FormError.invalid("Component nesting exceeds eight levels.") }
      var output = input
      output.elements = []
      for element in input.elements {
        guard let ref = element.component else { output.elements.append(element); continue }
        guard !stack.contains(ref.sourceObjectID), let source = byID[ref.sourceObjectID],
          source.componentDefinition == true, var sourceArt = source.artwork else {
          throw FormError.invalid("Missing or cyclic component source.")
        }
        sourceArt = resolvingSwatches(in: sourceArt, keepingReferences: keepingSwatchReferences)
        for i in sourceArt.elements.indices {
          if let change = ref.overrides?.first(where: { $0.elementID == sourceArt.elements[i].id }) {
            if let color = change.color { paint(color, swatchID: change.colorSwatchID, on: &sourceArt.elements[i]) }
            if let text = change.text, sourceArt.elements[i].kind == "text" {
              sourceArt.elements[i].text = text
              sourceArt.elements[i].textRuns = nil
              sourceArt.elements[i].glyphOverrides = nil
              sourceArt.elements[i].listItems = nil
            }
            if let opacity = change.opacity { sourceArt.elements[i].opacity = opacity }
          }
        }
        sourceArt = try expand(sourceArt, stack: stack.union([ref.sourceObjectID]), depth: depth + 1).resolvingLists
        let contentID = ComponentCommands.derivedID(element.id, source.id)
        let maskID = ComponentCommands.derivedID(contentID, source.id)
        var root = element
        root.component = nil
        root.contentSize = source.artworkSize
        output.elements.append(root)
        var content = ArtworkElement(kind: "group", x: 0, y: 0,
          width: source.artworkSize.x, height: source.artworkSize.y)
        content.id = contentID
        content.parentID = root.id
        content.name = source.name + " · content"
        content.contentSize = source.artworkSize
        if let boundary = sourceArt.boundary {
          var mask = ArtworkElement(kind: "path", x: 0, y: 0, width: boundary.width, height: boundary.height)
          mask.id = maskID
          mask.parentID = root.id
          mask.path = boundary
          mask.hidden = true
          content.clipID = maskID
          output.elements.append(mask)
        }
        output.elements.append(content)
        for var child in sourceArt.elements {
          // A component carries its source document's language into the host.
          // Resolve on this derived copy so host defaults cannot change its text.
          if child.kind == "text", let language = sourceArt.language {
            var type = child.typography ?? .init()
            type.language = type.language ?? language
            child.typography = type
            for i in child.textRuns?.indices ?? 0..<0 {
              var run = child.textRuns![i]
              run.typography.language = run.typography.language ?? type.language
              child.textRuns![i] = run
            }
          }
          let sourceElementID = child.id
          if let color = ref.color { paint(color, swatchID: ref.colorSwatchID, on: &child) }
          if let change = ref.overrides?.first(where: { $0.elementID == sourceElementID }), let color = change.color {
            paint(color, swatchID: change.colorSwatchID, on: &child)
          }
          child.id = ComponentCommands.derivedID(element.id, child.id)
          for i in child.listItems?.indices ?? 0..<0 {
            let old=child.listItems![i]
            child.listItems![i].id=ComponentCommands.derivedID(element.id,old.id)
            child.listItems![i].listID=ComponentCommands.derivedID(element.id,old.listID)
            if let number=old.resolvedNumber {child.listItems![i].restart=number}
          }
          child.parentID = child.parentID.map { ComponentCommands.derivedID(element.id, $0) } ?? contentID
          child.clipID = child.clipID.map { ComponentCommands.derivedID(element.id, $0) }
          if var path = child.path {
            for c in path.contours.indices {
              for n in path.contours[c].nodes.indices {
                path.contours[c].nodes[n].id = ComponentCommands.derivedID(element.id, path.contours[c].nodes[n].id)
              }
            }
            child.path = path
          }
          output.elements.append(child)
        }
        guard output.elements.count <= 10000 else {
          throw FormError.invalid("Expanded component artwork exceeds 10,000 elements.")
        }
      }
      return output
    }
    let output = try expand(art, stack: [], depth: 0)
    let cost = output.elements.reduce(0) { sum, e in
      sum + 512 + e.text.utf16.count * 4 + (e.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? 0) * 128
    }
    ComponentResolutionCache.values.setObject(ResolvedComponentArtwork(output), forKey: key, cost: cost)
    ComponentResolutionCache.built((Date.timeIntervalSinceReferenceDate - started) * 1000)
    return output
  }
}

extension Artwork {
  /// Boolean operands and clipping masks define geometry; their own paint is
  /// not visible. Offer overrides on the evaluated boolean and visible leaves.
  public var componentOverrideParts: [ArtworkElement] {
    let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
    let masks = Set(elements.compactMap(\.clipID))
    return elements.filter { e in
      guard e.hidden != true, !masks.contains(e.id), e.component == nil, e.kind != "image",
        e.kind != "group" || e.booleanOperation != nil else { return false }
      var parent = e.parentID
      var visited = Set<UUID>()
      while let id = parent, let ancestor = byID[id], visited.insert(id).inserted {
        if ancestor.hidden == true || ancestor.booleanOperation != nil { return false }
        parent = ancestor.parentID
      }
      return true
    }
  }
}
