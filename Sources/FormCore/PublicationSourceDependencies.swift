import Foundation

private enum PublicationArtworkDependency: Hashable {
  case canonical(UUID), rendered(UUID)
  var key: String {
    switch self {
    case .canonical(let id): return "canonical:" + id.uuidString
    case .rendered(let id): return "rendered:" + id.uuidString
    }
  }
}

extension Project {
  /// Canonical graphics dependencies. A physical aggregate contributes its
  /// selected source faces; pages contribute their applied original masters.
  /// Frozen object views are deliberate pixels and add no live dependency.
  public func artworkDependencyObjectIDs(for objectID:UUID)->Set<UUID> {
    guard let object=objects.first(where:{$0.id==objectID}) else{return []}
    var result=object.paperConstruction?.authored?.featureArtworkSourceObjectIDs ?? Set<UUID>()
    if let source=object.artworkSourceID {result.insert(source)}
    if let source=object.paperConstruction?.insideArtworkSourceID {result.insert(source)}
    result.formUnion((object.surfaceArtworkBindings ?? []).compactMap(\.sourceObjectID))
    if let document=publicationDocument(for:objectID) {result.formUnion(document.appliedMasters(for:objectID).map(\.sourceObjectID))}
    if let definition=object.sheetAssembly,let document=publications?.first(where:{$0.id==definition.publicationID}) {
      if let leaves=definition.leaves {
        let entries=Dictionary(uniqueKeysWithValues:document.pages.map{($0.id,$0.objectID)})
        result.formUnion(leaves.flatMap{[$0.frontPageID,$0.backPageID].compactMap{$0}.compactMap{entries[$0]}})
      }else{result.formUnion(document.pages.map(\.objectID))}
      result.formUnion(definition.artworkSourceObjectIDs)
    }
    for artwork in object.storedArtworks {
      for element in artwork.elements {
        if let component=element.component {result.insert(component.sourceObjectID)}
        if let view=element.objectView,view.linked {result.insert(view.sourceID)}
      }
    }
    return result
  }
  // A rendered page crops canonical neighbor artwork, not another rendered
  // page. Distinguishing these phases prevents an ordinary facing spread from
  // appearing cyclic while retaining real live-view feedback detection.
  private func publicationArtworkDependencies(_ node: PublicationArtworkDependency) -> Set<PublicationArtworkDependency> {
    switch node {
    case .canonical(let id):
      guard let object=objects.first(where:{$0.id==id}) else{return []}
      var result=Set<PublicationArtworkDependency>()
      for artwork in object.storedArtworks {for element in artwork.elements {
        if let component=element.component {result.insert(.canonical(component.sourceObjectID))}
        if let view=element.objectView,view.linked {result.insert(.rendered(view.sourceID))}
      }}
      return result
    case .rendered(let id):
      guard let object=objects.first(where:{$0.id==id}) else{return []}
      var result:Set<PublicationArtworkDependency>=[.canonical(id)]
      for source in object.paperConstruction?.authored?.featureArtworkSourceObjectIDs ?? [] {result.insert(.rendered(source))}
      if let source=object.artworkSourceID {result.insert(.rendered(source))}
      if let source=object.paperConstruction?.insideArtworkSourceID {result.insert(.rendered(source))}
      for source in (object.surfaceArtworkBindings ?? []).compactMap(\.sourceObjectID) {result.insert(.rendered(source))}
      if let document=publicationDocument(for:id) {
        for source in document.appliedMasters(for:id).map(\.sourceObjectID) {result.insert(.canonical(source))}
      }
      if let spread=publicationReaderSpread(for:id) {
        for page in spread.pages where page.objectID != id {result.insert(.canonical(page.objectID))}
      }
      if let definition=object.sheetAssembly,let document=publications?.first(where:{$0.id==definition.publicationID}) {
        if let leaves=definition.leaves {
          let entries=Dictionary(uniqueKeysWithValues:document.pages.map{($0.id,$0.objectID)})
          for source in leaves.flatMap({[$0.frontPageID,$0.backPageID].compactMap{$0}.compactMap{entries[$0]}}) {result.insert(.rendered(source))}
        }else{for page in document.pages {result.insert(.rendered(page.objectID))}}
        for source in definition.artworkSourceObjectIDs {result.insert(.rendered(source))}
      }
      return result
    }
  }
  public func artworkDependencyCycle(from objectID:UUID)->Bool {
    var visiting=Set<PublicationArtworkDependency>(),visited=Set<PublicationArtworkDependency>()
    var stack:[(PublicationArtworkDependency,Bool)]=[(.rendered(objectID),false)]
    while let (node,exiting)=stack.popLast() {
      if exiting {visiting.remove(node);visited.insert(node);continue}
      if visited.contains(node) {continue}
      if !visiting.insert(node).inserted {return true}
      stack.append((node,true))
      for dependency in publicationArtworkDependencies(node).sorted(by:{$0.key<$1.key}) {stack.append((dependency,false))}
    }
    return false
  }
  public func validatePublicationSpreadViewDependencies()throws {
    for document in publications ?? [] where document.layout?.facingPages==true {
      for page in document.pages {
        guard !artworkDependencyCycle(from:page.objectID) else{throw FormError.invalid("A reader spread cannot print a live view that feeds its own page sources back into the rendered spread. Freeze that view before using it as artwork.")}
      }
    }
  }
  public func validateSheetAssemblyViewDependencies()throws {
    for object in objects where object.sheetAssembly != nil {
      guard !artworkDependencyCycle(from:object.id) else{throw FormError.invalid("A sheet assembly cannot contain a live view of itself through its pages, masters or source components. Freeze the view before using it as printed artwork.")}
    }
  }
}
