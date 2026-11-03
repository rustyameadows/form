import FormCore
import Foundation

/// Prevent a still-rendering linked placement from being exported as though its
/// last saved image represented the current source. Frozen views are deliberate.
enum ObjectViewExportGuard {
  static func validate(project: Project, object: ProductObject, elementIDs: [String]? = nil) throws {
    let owner = project.artworkOwner(object)
    var documents = object.storedArtworks + (owner.id == object.id ? [] : owner.storedArtworks)
    // The effective surface also contains live running furniture and its derived
    // element IDs. Raw page documents alone omit those master placements.
    if let effective = project.surfaceArtwork(object, keepingSwatchReferences: true) {
      documents.append(effective)
    }
    let selected = Set((elementIDs ?? []).compactMap(UUID.init(uuidString:)))
    for document in documents {
      var art = (try? project.resolvingComponents(in:document, keepingSwatchReferences:true)) ?? document
      if !selected.isEmpty {
        guard let exported = try? art.exporting(selected) else { continue }
        art = exported.artwork
      }
      if art.renderDefinition.elements.contains(where: {
        $0.objectView?.linked == true && $0.objectView?.renderPending == true
      }) {
        throw FormError.invalid("A linked object view is still updating. Wait for its render to finish or freeze it before exporting.")
      }
    }
  }
}
