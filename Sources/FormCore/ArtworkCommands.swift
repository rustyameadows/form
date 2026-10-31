import Foundation

/// The native editor and MCP use these same deterministic document commands.
public enum ArtworkCommands {
  public static let names = [
    "production", "font", "optical", "character_position", "page_setup", "pattern_tiles", "garment_block",
    "add", "replace", "delete", "duplicate", "group", "ungroup", "align", "distribute", "reorder",
    "flip", "clip", "release_clip", "paragraph", "glyph", "origin", "transform", "language", "list",
    "pattern_piece", "seam_pair", "pattern_template", "cut_layout",
  ]
  @discardableResult public static func apply(
    _ command: String, to art: inout Artwork, ids: Set<UUID> = [], arguments: [String: Any] = [:],maxTextCharacters:Int=10000,
    duplicateOffset:Point2 = .init(10,10)
  ) throws -> Set<UUID> {
    var result = art
    var selection = ids
    let roots = art.selectionRoots(ids)
    guard ids.isSubset(of: Set(art.elements.map(\.id))) else {
      throw FormError.invalid("Unknown artwork selection.")
    }
    if !["add", "replace"].contains(command), roots.contains(where: { art.isLocked($0) }) {
      throw FormError.invalid("Unlock the selected layers before editing them.")
    }
    switch command {
    case "pattern_tiles": try SewingTileCommands.edit(&result, arguments: arguments)
    case "character_position":try CharacterPositionCommands.assign(&result,ids:ids,arguments:arguments,maxTextCharacters:maxTextCharacters)
    case "optical":try OpticalCommands.assign(&result,ids:ids,arguments:arguments,maxTextCharacters:maxTextCharacters)
    case "font":try FontCommands.assign(&result,ids:ids,arguments:arguments,maxTextCharacters:maxTextCharacters)
    case "cut_layout": try SewingLayoutCommands.edit(&result, arguments: arguments)
    case "pattern_piece", "seam_pair", "pattern_template":
      selection = try SewingPatternCommands.edit(command, artwork: &result, ids: ids, arguments: arguments)
    case "production": try ArtworkProduction.assign(&result,ids:ids,arguments:arguments)
    case "language": try ParagraphLanguage.setDefault(&result,arguments:arguments)
    case "list": try ListCommands.edit(&result,ids:ids,arguments:arguments)
    case "origin": try ArtworkTransforms.editOrigin(&result,ids:ids,arguments:arguments)
    case "transform": try ArtworkTransforms.transform(&result,ids:ids,arguments:arguments)
    case "glyph": try GlyphCommands.edit(&result,ids:ids,arguments:arguments,maxTextCharacters:maxTextCharacters)
    case "paragraph": try ParagraphCommands.edit(&result, ids: ids, arguments: arguments,maxTextCharacters:maxTextCharacters)
    case "clip":
      let candidates = roots.filter { ["rectangle","ellipse","polygon","star","path"].contains($0.kind) }
      let mask: ArtworkElement
      if let raw = arguments["mask_id"] {
        guard let raw = raw as? String, let id = UUID(uuidString:raw),
          let value = art.elements.first(where:{$0.id == id}) else { throw FormError.invalid("Choose an existing mask_id.") }
        mask = value
      } else {
        guard let value = candidates.first else { throw FormError.invalid("Choose an area shape for the clipping mask.") }
        mask = value
      }
      let targets = roots.filter { $0.id != mask.id }
      guard ["rectangle","ellipse","polygon","star","path"].contains(mask.kind), mask.clipID == nil,
        !targets.isEmpty, targets.allSatisfy({$0.parentID == mask.parentID}),
        Set(art.elements.compactMap(\.clipID)).isDisjoint(with: Set(targets.map(\.id))) else {
        throw FormError.invalid("Choose sibling artwork and an unclipped area shape. Use nested groups for nested masks.")
      }
      let targetIDs = Set(targets.map(\.id))
      guard !art.elements.contains(where:{targetIDs.contains($0.id) && art.isLocked($0)}) else { throw FormError.invalid("Unlock clipped artwork first.") }
      for i in result.elements.indices where targetIDs.contains(result.elements[i].id) { result.elements[i].clipID = mask.id; result.elements[i].clipMode = nil }
      selection = targetIDs
    case "release_clip":
      let targetIDs = Set(roots.filter{$0.clipID != nil}.map(\.id))
      guard !targetIDs.isEmpty else { throw FormError.invalid("Choose clipped artwork to release its mask.") }
      for i in result.elements.indices where targetIDs.contains(result.elements[i].id) { result.elements[i].clipID = nil; result.elements[i].clipMode = nil }
      selection = targetIDs
    case "add", "replace":
      guard let raw = arguments["elements"] as? [[String: Any]], !raw.isEmpty else {
        throw FormError.invalid("Provide an elements array.")
      }
      let values = try JSONDecoder().decode(
        [ArtworkElement].self, from: JSONSerialization.data(withJSONObject: raw))
      if command == "replace" {
        for e in values {
          guard let i = result.elements.firstIndex(where: { $0.id == e.id }) else {
            throw FormError.missing("Artwork element not found.")
          }
          result.elements[i] = e
        }
      } else {
        result.elements += values
      }
      selection = Set(values.map(\.id))
    case "delete":
      let all = art.descendants(of: ids)
      result.removeSewingSeams(involving: all)
      result.removeSewingLayoutReferences(to: all)
      result.elements.removeAll { all.contains($0.id) }
      selection = []
      for i in result.elements.indices where result.elements[i].clipID.map(all.contains) == true {
        result.elements[i].clipID = nil; result.elements[i].clipMode = nil
      }
    case "duplicate":
      guard [duplicateOffset.x,duplicateOffset.y].allSatisfy({$0.isFinite && abs($0)<=100000}) else {
        throw FormError.invalid("Duplicate offsets must be finite root-coordinate values within ±100000 mm.")
      }
      let all = art.descendants(of: ids)
      let mapping = Dictionary(uniqueKeysWithValues: all.map { ($0, UUID()) })
      let listIDs=Set(art.elements.filter{all.contains($0.id)}.flatMap{($0.listItems ?? []).map(\.listID)})
      let listMapping=Dictionary(uniqueKeysWithValues:listIDs.map{($0,UUID())})
      for var element in art.elements where all.contains(element.id) {
        let original = element.id
        element.id = mapping[original]!
        PathCommands.refreshNodeIDs(in: &element)
        for i in element.listItems?.indices ?? 0..<0 {
          element.listItems![i].id=UUID();element.listItems![i].listID=listMapping[element.listItems![i].listID]!
          element.listItems![i].resolvedNumber=nil
        }
        if let parent = element.parentID, let id = mapping[parent] { element.parentID = id }
        if let clip = element.clipID, let id = mapping[clip] { element.clipID = id }
        if roots.contains(where: { $0.id == original }) {
          element.x += duplicateOffset.x
          element.y += duplicateOffset.y
        }
        result.elements.append(element)
      }
      result.duplicateSewingSeams(from: art, mapping: mapping)
      selection = Set(roots.compactMap { mapping[$0.id] })
    case "group":
      guard roots.count >= 2, Set(roots.map(\.parentID)).count == 1 else {
        throw FormError.invalid("Select at least two objects in the same group.")
      }
      let bounds = roots.map { localBounds($0) }.dropFirst().reduce(localBounds(roots[0])) {
        $0.union($1)
      }
      var group = ArtworkElement(
        kind: "group", x: bounds.x, y: bounds.y, width: max(bounds.width, 0.01),
        height: max(bounds.height, 0.01))
      group.name = "Group"
      group.parentID = roots[0].parentID
      group.contentSize = .init(group.width, group.height)
      for i in result.elements.indices
      where roots.contains(where: { $0.id == result.elements[i].id }) {
        result.elements[i].affine = Affine2.translation(-bounds.x, -bounds.y).followed(
          by: result.elements[i].affine ?? .init())
        result.elements[i].parentID = group.id
      }
      result.elements.append(group)
      selection = [group.id]
    case "ungroup":
      var ungrouped = Set<UUID>()
      for group in roots where group.kind == "group" {
        guard group.component == nil else { throw FormError.invalid("Detach the component before ungrouping its artwork.") }
        if group.booleanOperation == nil {
          guard group.clipID == nil, !group.hasActiveEffects, group.isolatedBlending != true,
            group.blendMode == nil || group.blendMode == "normal",
            (group.opacity ?? 1) == 1 else {
            throw FormError.invalid("Keep this group to preserve its combined appearance, or release its clipping mask and reset its opacity, blending, and effects before ungrouping.")
          }
        }
        if group.booleanOperation != nil, group.clipID != nil,
          (ArtworkMasks.isCoverage(group.clipMode) || result.elements.contains(where: { $0.parentID == group.id && $0.clipID != nil }))
        {
          let index = result.elements.firstIndex { $0.id == group.id }!
          result.elements[index].booleanOperation = nil
          // The retained group preserves combined clipping and effects. Its
          // former Boolean result paint belongs to neither the group nor the
          // restored operands, whose authored paint records remain intact.
          result.elements[index].paintStack = nil
          result.elements[index].opacity = nil
          result.elements[index].productionRole = nil
          result.elements[index].name = "Operands · clipping group"
          ungrouped.formUnion(
            result.elements.filter { $0.parentID == group.id && $0.hidden != true }.map(\.id))
          continue
        }
        let childIDs = Set(result.elements.filter { $0.parentID == group.id }.map(\.id))
        for i in result.elements.indices where childIDs.contains(result.elements[i].id) {
          result.elements[i].affine = group.localTransform.followed(
            by: result.elements[i].affine ?? .init())
          result.elements[i].parentID = group.parentID
          if group.booleanOperation != nil, let clip = group.clipID {
            result.elements[i].clipID = clip
            result.elements[i].clipMode = group.clipMode
          }
          if group.booleanOperation == nil || result.elements[i].hidden != true {
            ungrouped.insert(result.elements[i].id)
          }
        }
        if group.booleanOperation != nil {
          // Release at the group's current stack position, including after a
          // layer reorder. The operand records can sit anywhere in the array.
          let children = result.elements.filter { childIDs.contains($0.id) }
          let groupIndex = result.elements.firstIndex { $0.id == group.id }!
          let insertion = result.elements[..<groupIndex].filter { !childIDs.contains($0.id) }.count
          result.elements.removeAll { $0.id == group.id || childIDs.contains($0.id) }
          result.elements.insert(contentsOf: children, at: insertion)
        } else {
          result.elements.removeAll { $0.id == group.id }
        }
      }
      selection = ungrouped
    case "align", "distribute":
      guard roots.count >= 2 else {
        throw FormError.invalid("Select two or more objects to align.")
      }
      let mode = arguments["mode"] as? String ?? "left"
      // Canvas alignment uses the visible axes, including inside rotated,
      // scaled, reflected, or sheared parents. Convert each world translation
      // back into its own parent's coordinates without changing that hierarchy.
      let boxes = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, art.bounds(of: $0)) })
      let bounds = roots.dropFirst().reduce(boxes[roots[0].id]!) { $0.union(boxes[$1.id]!) }
      let byID = Dictionary(uniqueKeysWithValues: art.elements.map { ($0.id, $0) })
      func move(_ root: ArtworkElement, dx: Double, dy: Double) throws {
        guard dx != 0 || dy != 0 else { return }
        let parent = root.parentID.flatMap { byID[$0] }.map { art.worldTransform($0) } ?? .init()
        guard let inverse = parent.inverse else { throw FormError.invalid("The selected parent transform cannot be inverted.") }
        let i = result.elements.firstIndex { $0.id == root.id }!
        translate(&result.elements[i], dx: inverse.a * dx + inverse.c * dy, dy: inverse.b * dx + inverse.d * dy)
      }
      if command == "align" {
        guard
          ["left", "right", "top", "bottom", "center_x", "center_y", "width", "height"].contains(
            mode)
        else { throw FormError.invalid("Unknown alignment mode.") }
        for root in roots {
          let b = boxes[root.id]!
          let i = result.elements.firstIndex { $0.id == root.id }!
          var dx = 0.0
          var dy = 0.0
          switch mode {
          case "left": dx = bounds.x - b.x
          case "right": dx = bounds.maxX - b.maxX
          case "top": dy = bounds.y - b.y
          case "bottom": dy = bounds.maxY - b.maxY
          case "center_x": dx = bounds.center.x - b.center.x
          case "center_y": dy = bounds.center.y - b.center.y
          case "width": result.elements[i].width = roots[0].width
          case "height": result.elements[i].height = roots[0].height
          default: break
          }
          try move(root, dx: dx, dy: dy)
        }
      } else {
        guard roots.count >= 3, ["horizontal", "vertical", "horizontal_centers", "vertical_centers"].contains(mode) else {
          throw FormError.invalid("Distribute three or more objects horizontally or vertically.")
        }
        let horizontal = mode.hasPrefix("horizontal"), centers = mode.hasSuffix("_centers")
        let sorted = roots.enumerated().sorted {
          let a = boxes[$0.element.id]!, b = boxes[$1.element.id]!
          let first = horizontal ? (centers ? a.center.x : a.x) : (centers ? a.center.y : a.y)
          let second = horizontal ? (centers ? b.center.x : b.x) : (centers ? b.center.y : b.y)
          return first == second ? $0.offset < $1.offset : first < second
        }.map(\.element)
        if centers {
          let first = boxes[sorted[0].id]!, last = boxes[sorted[sorted.count - 1].id]!
          let start = horizontal ? first.center.x : first.center.y
          let end = horizontal ? last.center.x : last.center.y
          let step = (end - start) / Double(sorted.count - 1)
          for (index, root) in sorted.enumerated() {
            let b = boxes[root.id]!, target = start + Double(index) * step
            try move(root, dx: horizontal ? target - b.center.x : 0,
              dy: horizontal ? 0 : target - b.center.y)
          }
        } else {
          let total = sorted.reduce(0.0) {
            $0 + (horizontal ? boxes[$1.id]!.width : boxes[$1.id]!.height)
          }
          let gap = ((horizontal ? bounds.width : bounds.height) - total) / Double(sorted.count - 1)
          var next = horizontal ? bounds.x : bounds.y
          for root in sorted {
            let b = boxes[root.id]!
            try move(root, dx: horizontal ? next - b.x : 0, dy: horizontal ? 0 : next - b.y)
            next += (horizontal ? b.width : b.height) + gap
          }
        }
      }
    case "reorder":
      let mode = arguments["mode"] as? String ?? "front"
      guard ["front", "back", "forward", "backward"].contains(mode) else {
        throw FormError.invalid("Unknown layer order.")
      }
      if mode == "front" || mode == "back" {
        let selected = result.elements.filter { ids.contains($0.id) }
        result.elements.removeAll { ids.contains($0.id) }
        if mode == "front" {
          result.elements += selected
        } else {
          result.elements.insert(contentsOf: selected, at: 0)
        }
      } else {
        let forward = mode == "forward"
        // Element storage interleaves entire hierarchies. Layer order is the
        // order among siblings, not adjacency in that flat storage array.
        let siblings = Dictionary(grouping: result.elements.indices, by: { result.elements[$0].parentID })
        for positions in siblings.values {
          let traversal = forward ? Array(positions.indices.reversed()) : Array(positions.indices)
          for position in traversal where ids.contains(result.elements[positions[position]].id) {
            let next = position + (forward ? 1 : -1)
            if positions.indices.contains(next), !ids.contains(result.elements[positions[next]].id) {
              result.elements.swapAt(positions[position], positions[next])
            }
          }
        }
      }
    case "flip":
      for i in result.elements.indices where ids.contains(result.elements[i].id) {
        if arguments["axis"] as? String == "y" {
          result.elements[i].flipY = !(result.elements[i].flipY ?? false)
        } else {
          result.elements[i].flipX = !(result.elements[i].flipX ?? false)
        }
      }
    default: throw FormError.invalid("Unknown artwork command.")
    }
    try validateArtwork(result,maxTextCharacters:maxTextCharacters)
    art = result
    return selection
  }
  public static func localBounds(_ e: ArtworkElement) -> Rect2 {
    e.localTransform.bounds(
      .init(
        0, 0, e.kind == "group" ? e.contentSize?.x ?? e.width : e.width,
        e.kind == "group" ? e.contentSize?.y ?? e.height : e.height))
  }
  public static func translate(_ e: inout ArtworkElement, dx: Double, dy: Double) {
    if let affine = e.affine {
      e.affine = Affine2.translation(dx, dy).followed(by: affine)
    } else {
      e.x += dx
      e.y += dy
    }
  }
}
