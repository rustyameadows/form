import Foundation

public enum SewingLayoutCommands {
  public static func edit(_ artwork: inout Artwork, arguments: [String: Any]) throws {
    let action = arguments["layout_action"] as? String ?? "save"
    guard ["save", "plan"].contains(action) else { throw FormError.invalid("layout_action must be save or plan.") }
    var candidate = artwork, definition = artwork.sewingLayout
    if let raw = arguments["cutting_layout"] {
      if raw is NSNull { definition = nil }
      else if let object = raw as? [String: Any] {
        definition = try JSONDecoder.form.decode(SewingCutLayout.self, from: JSONSerialization.data(withJSONObject: object))
      } else { throw FormError.invalid("cutting_layout must be a complete layout object or null.") }
    } else if action == "save" { throw FormError.invalid("Provide cutting_layout metadata, or null to remove it.") }
    if action == "plan" {
      guard let definition else { throw FormError.invalid("Configure a cutting layout before planning.") }
      candidate.sewingLayout = try SewingLayouts.planned(definition, source: artwork).layout
    } else {
      try definition?.validateMetadata(); candidate.sewingLayout = definition
    }
    try validateArtwork(candidate)
    artwork = candidate
  }
}

extension Artwork {
  public mutating func removeSewingLayoutReferences(to ids: Set<UUID>) {
    guard var layout = sewingLayout else { return }
    if let scope = layout.elementIDs, Set(scope).isSubset(of: ids) { sewingLayout = nil; return }
    if !elements.contains(where: { $0.sewingPiece != nil && !ids.contains($0.id) }) { sewingLayout = nil; return }
    layout.removeReferences(to: ids); sewingLayout = layout
  }
  /// A saved manual layout is moved only with its entire source scope. Its physical stock poses
  /// remain unchanged when source contours move between Canvas owners.
  public mutating func transferSewingLayout(to destination: inout Artwork, moved: Set<UUID>, mapping: [UUID: UUID]) throws {
    guard var layout = sewingLayout else { return }
    let references: Set<UUID>
    if let scope = layout.elementIDs { references = Set(scope) }
    else {
      references = Set(elements.filter { e in
        guard let piece = e.sewingPiece else { return false }
        return piece.materialID == nil || piece.materialID == layout.materialID
      }.map(\.id)).union(layout.placements.map(\.elementID))
    }
    if references.isDisjoint(with: moved) { return }
    guard references.isSubset(of: moved) else { throw FormError.invalid("Transfer all pieces in this saved cutting layout together, or remove the layout first.") }
    guard destination.sewingLayout == nil else { throw FormError.invalid("The destination already has a saved cutting layout. Use a separate Canvas frame or remove one layout first.") }
    layout.elementIDs = layout.elementIDs?.map { mapping[$0] ?? $0 }
    for index in layout.placements.indices { layout.placements[index].elementID = mapping[layout.placements[index].elementID] ?? layout.placements[index].elementID }
    destination.sewingLayout = layout; sewingLayout = nil
  }
}

extension Project {
  public func validateSewingLayoutMaterials() throws {
    for object in objects {
      guard let layout = object.artwork?.sewingLayout else { continue }
      let stock = material(layout.materialID)
      guard stock.id == layout.materialID, stock.fabric != nil else {
        throw FormError.invalid("A cutting layout must reference a fabric material stored in this project or its built-in presets.")
      }
    }
  }
}
