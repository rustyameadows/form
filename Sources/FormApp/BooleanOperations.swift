import FormCore
import FormGraphics
import Foundation

extension StudioStore {
  func editBoolean(
    object: ProductObject, artwork art: Artwork, ids: Set<UUID>, arguments: [String: Any]
  ) throws -> [String: Any] {
    let selected = art.selectionRoots(ids)
    let roots = Set(selected.map(\.id))
    guard !selected.isEmpty, selected.allSatisfy({ !art.isLocked($0) }) else {
      throw FormError.invalid("Choose unlocked vector operands or a live boolean group.")
    }
    let operation = arguments["operation"] as? String ?? selected.first?.booleanOperation ?? "union"
    let mode = arguments["mode"] as? String ?? (operation == "divide" ? "divide" : "live")
    guard ["live", "path", "update", "flatten", "release", "divide"].contains(mode) else {
      throw FormError.invalid("Unknown boolean editing mode.")
    }
    var next = art
    var selection = Set<UUID>()
    var empty = false
    switch mode {
    case "update":
      guard selected.count == 1, selected[0].booleanOperation != nil,
        BooleanCommands.operations.contains(operation)
      else {
        throw FormError.invalid("Select one live boolean and a supported operation.")
      }
      let index = next.elements.firstIndex { $0.id == selected[0].id }!
      if next.elements[index].name == selected[0].booleanOperation?.capitalized {
        next.elements[index].name = operation.capitalized
      }
      next.elements[index].booleanOperation = operation
      try validateArtwork(next)
      empty = try BooleanGeometry.path(next.elements[index], in: next).isEmpty
      selection = [selected[0].id]
    case "release":
      guard selected.allSatisfy({ $0.booleanOperation != nil }) else {
        throw FormError.invalid("Select live boolean groups to release.")
      }
      selection = try ArtworkCommands.apply("ungroup", to: &next, ids: ids)
    case "flatten":
      guard selected.allSatisfy({ $0.booleanOperation != nil }) else {
        throw FormError.invalid("Select live boolean groups to flatten.")
      }
      for group in selected {
        var path = try BooleanGeometry.proxy(group, in: art, normalize: true)
        path.id = UUID()
        PathCommands.refreshNodeIDs(in: &path)
        path.name = "\(group.title.prefix(470)) · path"
        empty = empty || path.path?.contours.isEmpty == true
        let groupIndex = next.elements.firstIndex { $0.id == group.id }!
        next.elements.insert(path, at: groupIndex + 1)
        selection.insert(path.id)
        let index = next.elements.firstIndex { $0.id == group.id }!
        next.elements[index].hidden = true
        next.elements[index].name = "\(group.title.prefix(470)) · editable source"
      }
    case "divide":
      // Validate the same operand/lock/clip contract as a live group first.
      var candidate = art
      _ = try BooleanCommands.create("union", artwork: &candidate, elements: ids)
      let regions = try BooleanGeometry.divide(selected, in: art)
      guard !regions.isEmpty else {
        throw FormError.invalid("These operands contain no filled regions to divide.")
      }
      var paths: [ArtworkElement] = []
      for (i, region) in regions.enumerated() {
        let path = try BooleanGeometry.regionElement(region, in: art, name: "Region \(i + 1)")
        paths.append(path)
        selection.insert(path.id)
      }
      let frontIndex = next.elements.firstIndex { $0.id == selected.last!.id }!
      next.elements.insert(contentsOf: paths, at: frontIndex + 1)
      for i in next.elements.indices where roots.contains(next.elements[i].id) {
        next.elements[i].hidden = true
      }
    default:
      let id = try BooleanCommands.create(operation, artwork: &next, elements: ids)
      let group = next.elements.first { $0.id == id }!
      empty = try BooleanGeometry.path(group, in: next).isEmpty
      if mode == "path" {
        var path = try BooleanGeometry.proxy(group, in: next, normalize: true)
        path.id = UUID()
        PathCommands.refreshNodeIDs(in: &path)
        path.name = operation.capitalized
        next = art
        for i in next.elements.indices where roots.contains(next.elements[i].id) {
          next.elements[i].hidden = true
        }
        let frontIndex = next.elements.firstIndex { $0.id == selected.last!.id }!
        next.elements.insert(path, at: frontIndex + 1)
        selection = [path.id]
      } else {
        selection = [id]
      }
    }
    try validateArtwork(next)
    try engine.edit("Artwork: boolean \(mode)", source: "Graphics") {
      try $0.setArtwork(next, for: object.id)
    }
    let result = next.elements.filter { selection.contains($0.id) }
    return [
      "selected_elements": selection.map(\.uuidString),
      "elements": try result.map { try jsonObject($0) }, "empty_result": empty, "mode": mode,
    ]
  }
}
