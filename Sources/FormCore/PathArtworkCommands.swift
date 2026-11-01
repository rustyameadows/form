import Foundation

public struct PathEditResult: Sendable {
  public var elements: Set<UUID>
  public var nodes: Set<UUID>
}

extension PathCommands {
  /// Document-level path operations shared by native direct selection and MCP.
  /// Work on a candidate so invalid selections never partially modify artwork.
  public static func edit(
    _ operation: String, artwork: inout Artwork, elements ids: Set<UUID>,
    nodes: Set<UUID> = [], arguments: [String: Any] = [:]
  ) throws -> PathEditResult {
    let paths = artwork.elements.filter { ids.contains($0.id) }
    guard !ids.isEmpty, paths.count == ids.count,
      paths.allSatisfy({ $0.kind == "path" && $0.path != nil })
    else { throw FormError.invalid("Select editable vector paths. Convert shapes to paths first.") }
    guard paths.allSatisfy({ !artwork.isLocked($0) }) else {
      throw FormError.invalid("Unlock the selected paths before editing them.")
    }
    if ["combine","release","join"].contains(operation),paths.contains(where:{$0.sewingPiece != nil}) {
      throw FormError.invalid("Remove manufacturing annotations and seam pairs before combining, separating, or joining sewing source topology. Compose holes before annotating the piece.")
    }
    let nodeIDs = paths.flatMap { $0.path!.contours.flatMap(\.nodes).map(\.id) }
    let counts = nodeIDs.reduce(into: [UUID: Int]()) { $0[$1, default: 0] += 1 }
    guard nodes.isSubset(of: Set(nodeIDs)) else { throw FormError.invalid("Unknown path node ID.") }
    if !nodes.isEmpty {
      guard nodes.allSatisfy({ counts[$0] == 1 }) else {
        throw FormError.invalid(
          "These paths contain repeated node IDs. Combine them before selecting nodes together.")
      }
    }
    var next = artwork
    var selectedElements = ids
    var selectedNodes = Set<UUID>()
    if operation == "combine" {
      let result = try combine(paths, in: &next)
      selectedElements = [result.id]
    } else if operation == "release" {
      guard paths.count == 1, let source = paths.first, let path = source.path,
        path.contours.count > 1
      else { throw FormError.invalid("Select one compound path with multiple contours.") }
      guard !next.elements.contains(where: { $0.clipID == source.id }) else {
        throw FormError.invalid(
          "Release this path's clipping-mask use before separating its contours.")
      }
      let index = next.elements.firstIndex { $0.id == source.id }!
      var parts: [ArtworkElement] = []
      for (i, contour) in path.contours.enumerated() {
        var part = source
        part.id = i == 0 ? source.id : UUID()
        part.name = "\(source.title.prefix(480)) · \(i + 1)"
        part.path?.contours = [contour]
        normalize(&part, preservingPaint: true)
        parts.append(part)
      }
      next.elements.replaceSubrange(index...index, with: parts)
      selectedElements = Set(parts.map(\.id))
    } else {
      if ["insert", "split"].contains(operation), nodes.count != 1 {
        throw FormError.invalid("Select one path node for this operation.")
      }
      let owners = paths.filter { e in
        e.path!.contours.flatMap(\.nodes).contains { nodes.contains($0.id) }
      }
      var targets = nodes.isEmpty ? paths : owners
      if operation == "join", owners.count > 1 {
        guard nodes.count == 2, owners.count == 2 else {
          throw FormError.invalid("Select exactly two open endpoints to join.")
        }
        let result = try combine(owners, in: &next, name: "Joined path")
        selectedElements.subtract(owners.map(\.id))
        selectedElements.insert(result.id)
        targets = [result]
      }
      for target in targets {
        let index = next.elements.firstIndex { $0.id == target.id }!
        let localIDs = Set(target.path!.contours.flatMap(\.nodes).map(\.id)).intersection(nodes)
        let world = next.worldTransform(target)
        selectedNodes.formUnion(
          try apply(
            operation, to: &next.elements[index], nodes: localIDs,
            arguments: arguments, world: world))
        if next.elements[index].path?.contours.isEmpty == true {
          next.elements.remove(at: index)
          selectedElements.remove(target.id)
          for i in next.elements.indices where next.elements[i].clipID == target.id {
            next.elements[i].clipID = nil
            next.elements[i].clipMode = nil
          }
        }
      }
    }
    try validateArtwork(next)
    artwork = next
    return .init(elements: selectedElements, nodes: selectedNodes)
  }

  private static func combine(
    _ paths: [ArtworkElement], in artwork: inout Artwork, name: String = "Compound path"
  ) throws
    -> ArtworkElement
  {
    guard paths.count >= 2, Set(paths.map(\.parentID)).count == 1 else {
      throw FormError.invalid("Select two or more paths in the same group.")
    }
    guard Set(paths.map(\.clipID)).count == 1, Set(paths.map { $0.clipMode ?? "outline" }).count == 1 else {
      throw FormError.invalid("The paths must share the same clipping mask before combining.")
    }
    let ids = Set(paths.map(\.id))
    guard !artwork.elements.contains(where: { $0.clipID.map(ids.contains) == true }) else {
      throw FormError.invalid("Release these paths' clipping-mask use before combining them.")
    }
    var result = paths.last!
    guard let inverse = result.localTransform.inverse else {
      throw FormError.invalid("The path transform is singular.")
    }
    var used = Set<UUID>()
    let contours = paths.flatMap { source -> [VectorContour] in
      let path = source.path!
      let map = inverse.followed(by: source.localTransform).followed(
        by: .scale(source.width / path.width, source.height / path.height))
      return path.contours.map { contour in
        var contour = contour
        contour.nodes = contour.nodes.map { node in
          var node = transformed(node, by: map)
          if !used.insert(node.id).inserted {
            node.id = UUID()
            used.insert(node.id)
          }
          return node
        }
        return contour
      }
    }
    result.path = .init(width: result.width, height: result.height, contours: contours)
    result.path?.evenOdd = true
    result.name = name
    normalize(&result, preservingPaint: true)
    let index = artwork.elements.firstIndex { $0.id == result.id }!
    artwork.elements[index] = result
    artwork.elements.removeAll { ids.contains($0.id) && $0.id != result.id }
    return result
  }
}
