import Foundation

/// Clip semantics are independent of the mask's editable layer type.
public enum ArtworkMasks {
  public static let modes: Set<String> = ["outline", "alpha", "luminance", "luminance-alpha"]
  public static func isCoverage(_ mode: String?) -> Bool { mode != nil && mode != "outline" }

  public static func validate(_ artwork: Artwork) throws {
    let byID = Dictionary(uniqueKeysWithValues: artwork.elements.map { ($0.id, $0) })
    let children = Dictionary(grouping: artwork.elements, by: \.parentID)
    for element in artwork.elements {
      guard element.clipMode.map(modes.contains) ?? true else { throw FormError.invalid("Unknown artwork mask mode.") }
      guard let id = element.clipID else { continue }
      guard let mask = byID[id], id != element.id, mask.parentID == element.parentID else {
        throw FormError.invalid("A clipping mask must be another layer in the same group.")
      }
      if !isCoverage(element.clipMode) {
        guard !["group", "text", "image"].contains(mask.kind), mask.clipID == nil else {
          throw FormError.invalid("An outline clip needs an independent vector shape; use an alpha or luminance mask for editable subtrees.")
        }
      }
    }
    guard artwork.elements.contains(where: { $0.clipID != nil }) else { return }
    // Rendering depends on both descendants and clip sources. Checking only
    // parent chains or only clip chains misses A -> child -> B -> A cycles.
    var state: [UUID: UInt8] = [:], work = 0
    func visit(_ id: UUID, depth: Int) throws {
      work += 1
      guard work <= 50_000, depth <= 128 else { throw FormError.invalid("Mask dependencies exceed their traversal budget.") }
      if state[id] == 2 { return }
      guard state[id] != 1, let node = byID[id] else { throw FormError.invalid("Artwork mask dependencies are cyclic or missing.") }
      state[id] = 1
      if let mask = node.clipID { try visit(mask, depth: depth + 1) }
      for child in children[id] ?? [] { try visit(child.id, depth: depth + 1) }
      state[id] = 2
    }
    for node in artwork.elements { try visit(node.id, depth: 0) }
  }
}

extension Artwork {
  public func isCoverageMask(_ id:UUID)->Bool {
    elements.contains{$0.clipID==id && ArtworkMasks.isCoverage($0.clipMode)}
  }
  /// Explicit mask editing bypasses only the mask root's implicit visibility.
  /// Hidden/locked children and other referenced masks remain outside this scope.
  public func editableMaskElementIDs(rootID:UUID)->Set<UUID> {
    guard elements.count<=10_000,let root=elements.first(where:{$0.id==rootID}),!isLocked(root) else{return []}
    guard isCoverageMask(rootID) else{return [rootID]}
    let children=Dictionary(grouping:elements,by:\.parentID),masks=Set(elements.compactMap(\.clipID))
    var result:Set<UUID>=[rootID],pending:[(UUID,Int)]=[(rootID,0)]
    while let (id,depth)=pending.popLast() {
      guard depth<64 else{continue}
      for child in children[id] ?? [] where child.hidden != true && child.locked != true && !masks.contains(child.id) {
        if result.insert(child.id).inserted {pending.append((child.id,depth+1))}
      }
    }
    return result
  }
  /// A conservative parent-coordinate carrier rectangle, independent of fonts
  /// and image decoding. It contains editable descendants, strokes and effects.
  public func maskCoverageBounds(of root: ArtworkElement) -> Rect2 {
    let children = Dictionary(grouping: elements, by: \.parentID)
    var visited = Set<UUID>()
    func local(_ element: ArtworkElement, depth: Int) -> Rect2 {
      guard depth <= 128, visited.insert(element.id).inserted else { return .init(0,0,0,0) }
      var box = Rect2(0, 0, element.kind == "group" ? element.contentSize?.x ?? element.width : element.width,
        element.kind == "group" ? element.contentSize?.y ?? element.height : element.height)
      for child in children[element.id] ?? [] where child.hidden != true {
        box = box.union(child.localTransform.bounds(local(child, depth: depth + 1)))
      }
      let strokes = [element.stroke].compactMap { $0 } + element.paintLayers.compactMap(\.stroke)
      let margin = strokes.filter { $0.enabled != false }.map { $0.width * max(1, $0.miter ?? 10) }.max() ?? 0
      if margin > 0 { box = .init(box.x-margin,box.y-margin,box.width+2*margin,box.height+2*margin) }
      if let stack = element.effectStack { box = stack.expandedBounds(box) }
      else if let blur = element.blur, blur.enabled { let r = blur.radius * 4; box = .init(box.x-r,box.y-r,box.width+2*r,box.height+2*r) }
      if element.effectStack == nil, let shadow = element.shadow, shadow.enabled, shadow.opacity > 0 {
        let r = shadow.blur * 4
        box = box.union(.init(box.x+shadow.offset.x-r,box.y+shadow.offset.y-r,box.width+2*r,box.height+2*r))
      }
      return box
    }
    return root.localTransform.bounds(local(root, depth: 0))
  }
}
