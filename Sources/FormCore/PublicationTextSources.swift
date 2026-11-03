import Foundation

/// A transient address for a rendered publication layer. Derived master and
/// component IDs never replace the independently editable source address.
public struct PublicationTextSource: Equatable, Sendable {
  public let objectID: UUID
  public let elementID: UUID
  public var masterID: UUID?
  public var masterSourceObjectID: UUID?
  public var instanceObjectID: UUID?
  public var instanceElementID: UUID?
}

extension Project {
  /// Uses exactly the component/furniture ID derivation used by rendering.
  /// This maps identities only; layout still uses the resolved, overridden,
  /// token-expanded text on each physical page.
  public func publicationTextSources(for objectID: UUID) throws -> [UUID: PublicationTextSource] {
    guard let object = objects.first(where: { $0.id == objectID }),
      let stored = artworkOwner(object).artwork else { return [:] }
    let owner = artworkOwner(object)
    let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
    var visitedElements = 0
    func sources(_ art: Artwork, owner: UUID, stack: Set<UUID>, depth: Int) throws -> [UUID: PublicationTextSource] {
      guard depth <= 8 else { throw FormError.invalid("Component nesting exceeds eight levels.") }
      var result: [UUID: PublicationTextSource] = [:]
      for element in art.elements {
        visitedElements += 1
        guard visitedElements <= 20_000 else { throw FormError.invalid("Publication text source addressing exceeds its bounded layer budget.") }
        if element.kind == "text" { result[element.id] = .init(objectID: owner, elementID: element.id) }
        guard let reference = element.component else { continue }
        guard !stack.contains(reference.sourceObjectID), let source = byID[reference.sourceObjectID],
          source.componentDefinition == true, let nested = source.artwork else {
          throw FormError.invalid("A publication text component source is missing or cyclic.")
        }
        for (id, var address) in try sources(nested, owner: source.id,
          stack: stack.union([source.id]), depth: depth + 1) {
          // The outer editable instance is also exposed for per-instance text
          // overrides; the source address still names its real text element.
          address.instanceObjectID = owner; address.instanceElementID = element.id
          result[ComponentCommands.derivedID(element.id, id)] = address
        }
      }
      return result
    }
    var result = try sources(stored, owner: owner.id, stack: [owner.id], depth: 0)
    guard let document = publicationDocument(for: objectID),
      let page = document.pages.first(where: { $0.objectID == objectID }) else { return result }
    for master in document.appliedMasters(for: objectID) {
      guard let source = byID[master.sourceObjectID], let art = source.artwork else {
        throw FormError.missing("A publication master source is missing.")
      }
      let rootID = ComponentCommands.derivedID(page.id, master.id)
      for (id, var address) in try sources(art, owner: source.id, stack: [source.id], depth: 0) {
        address.masterID = master.id; address.masterSourceObjectID = source.id
        result[ComponentCommands.derivedID(rootID, id)] = address
      }
    }
    return result
  }
}
