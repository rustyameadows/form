import Foundation

public struct PublicationReaderPageGeometry: Codable, Equatable, Sendable {
  public var pageID: UUID
  public var objectID: UUID
  public var originMM: Point2
  public var sizeMM: Point2
}
public struct PublicationReaderSpreadGeometry: Codable, Equatable, Sendable {
  public var publicationID: UUID
  public var spreadID: UUID
  public var pages: [PublicationReaderPageGeometry]
  public var sizeMM: Point2
}

private let publicationSpreadNamespace = UUID(uuidString: "286A9F3C-87B2-47CF-A3B7-745FC0E44853")!

extension Project {
  /// Physical reader geometry is independent of Canvas positions, the page rail,
  /// and folded-sheet imposition. Page entries retain their canonical owners.
  public func publicationReaderSpreads(_ publicationID: UUID) -> [PublicationReaderSpreadGeometry] {
    guard let document = publications?.first(where: { $0.id == publicationID }),
      document.layout?.facingPages == true else { return [] }
    let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return document.spreads().compactMap { spread in
      var x = 0.0, height = 0.0, pages: [PublicationReaderPageGeometry] = []
      for entry in spread.pages {
        guard let object = byID[entry.objectID] else { return nil }
        let size = object.artworkSize
        pages.append(.init(pageID: entry.id, objectID: object.id, originMM: .init(x, 0), sizeMM: size))
        x += size.x; height = max(height, size.y)
      }
      return .init(publicationID: document.id, spreadID: spread.id, pages: pages, sizeMM: .init(x, height))
    }
  }
  public func publicationReaderSpread(for objectID: UUID) -> PublicationReaderSpreadGeometry? {
    guard let document = publicationDocument(for: objectID) else { return nil }
    return publicationReaderSpreads(document.id).first { $0.pages.contains { $0.objectID == objectID } }
  }
  public func sharesPublicationReaderSpread(_ first: UUID, _ second: UUID) -> Bool {
    publicationReaderSpread(for: first)?.pages.contains { $0.objectID == second } == true
  }
  private func publicationSpreadRoot(target: UUID, source: UUID) -> UUID {
    ComponentCommands.derivedID(target, ComponentCommands.derivedID(source, publicationSpreadNamespace))
  }
  /// Runtime neighbor groups are never accepted as another editable source.
  public func removingPublicationSpreadArtwork(from artwork: Artwork, objectID: UUID) -> Artwork {
    guard let document = publicationDocument(for: objectID),
      let target = document.pages.first(where: { $0.objectID == objectID }) else { return artwork }
    let roots = Set(document.pages.filter { $0.id != target.id }.map {
      publicationSpreadRoot(target: target.id, source: $0.id)
    })
    let removed = artwork.descendants(of: roots).union(roots)
    var result = artwork; result.elements.removeAll { removed.contains($0.id) }; return result
  }
  /// An element remains on its original page, in its original page coordinates.
  /// Other physical page crops see a deterministic derived group. Canvas renders
  /// the original once across the spread instead of editing these derived copies.
  public func resolvingPublicationSpreadArtwork(in owned: Artwork, objectID: UUID) -> Artwork {
    guard let geometry = publicationReaderSpread(for: objectID), geometry.pages.count > 1,
      let target = geometry.pages.first(where: { $0.objectID == objectID }),
      let document = publicationDocument(for: objectID) else { return owned }
    let canonical = removingPublicationFurniture(from: owned, objectID: objectID)
    let canonicalIDs = Set(canonical.elements.map(\.id))
    let behindRoots = Set(document.appliedMasters(for: objectID).filter(\.behind).map {
      ComponentCommands.derivedID(target.pageID, $0.id)
    })
    let behindIDs = owned.descendants(of: behindRoots).union(behindRoots)
    let furniture = owned.elements.filter { !canonicalIDs.contains($0.id) }
    var result = owned
    result.elements = furniture.filter { behindIDs.contains($0.id) }
    for page in geometry.pages {
      if page.objectID == objectID { result.elements += canonical.elements; continue }
      guard let source = objects.first(where: { $0.id == page.objectID }), let stored = source.artwork else { continue }
      let sourceArtwork = removingPublicationFurniture(
        from: resolvingTextStories(in: stored, objectID: source.id), objectID: source.id).resolvingLists
      let rootID = publicationSpreadRoot(target: target.pageID, source: page.pageID)
      var root = ArtworkElement(kind: "group", x: page.originMM.x - target.originMM.x,
        y: page.originMM.y - target.originMM.y, width: page.sizeMM.x, height: page.sizeMM.y)
      root.id = rootID; root.name = source.name + " · reader spread"
      root.contentSize = page.sizeMM; root.locked = true
      result.elements.append(root)
      for var child in sourceArtwork.elements {
        child.id = ComponentCommands.derivedID(rootID, child.id)
        child.parentID = child.parentID.map { ComponentCommands.derivedID(rootID, $0) } ?? rootID
        child.clipID = child.clipID.map { ComponentCommands.derivedID(rootID, $0) }
        child.locked = true
        for index in child.listItems?.indices ?? 0..<0 {
          let item = child.listItems![index]
          child.listItems![index].id = ComponentCommands.derivedID(rootID, item.id)
          child.listItems![index].listID = ComponentCommands.derivedID(rootID, item.listID)
          if let number = item.resolvedNumber { child.listItems![index].restart = number }
        }
        if var path = child.path {
          for contour in path.contours.indices {
            for node in path.contours[contour].nodes.indices {
              path.contours[contour].nodes[node].id = ComponentCommands.derivedID(rootID, path.contours[contour].nodes[node].id)
            }
          }
          child.path = path
        }
        if child.kind == "text", let language = sourceArtwork.language {
          var type = child.typography ?? .init(); type.language = type.language ?? language; child.typography = type
          for index in child.textRuns?.indices ?? 0..<0 {
            var run = child.textRuns![index]
            run.typography.language = run.typography.language ?? type.language
            child.textRuns![index] = run
          }
        }
        result.elements.append(child)
      }
    }
    result.elements += furniture.filter { !behindIDs.contains($0.id) }
    return result
  }
}
