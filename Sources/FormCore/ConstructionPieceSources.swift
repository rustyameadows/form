import Foundation
import FormCADModel

extension Project {
  /// Independent cut-piece sources are canonical physical-size artwork. Disabled
  /// options retain their identities; their extents are checked when activated.
  func validateConstructionPieceSources(_ object:ProductObject,source:PaperConstruction)throws {
    guard let definition=source.authored,definition.version>=4 else{return}
    let context=try PlanarAssemblySourceContext(definition,fallbackStock:source.stock),variables=context.values
    for component in definition.components ?? [] {
      guard let bounds=context.bounds[component.id] else{throw FormError.missing("Cut piece ‘\(component.id)’ has no saved pattern bounds.")}
      let active=context.enabledIDs.contains(component.id)
      for declaration in [component.front,component.back].compactMap({$0}) {
        guard let target=objects.first(where:{$0.id==declaration.sourceObjectID}),target.id != object.id,
          target.sheetAssembly==nil,!target.isCanvasWorkspace,
          isIndependentFlatArtworkSource(target) || PaperConstruction.isPaper(target),
          (PaperConstruction.isPaper(target) ? paperArtwork(for:target,inside:declaration.sourceSide == .inside):surfaceArtwork(target)) != nil else {
          throw FormError.invalid("Cut piece ‘\(component.id)’ retains an unavailable canonical artwork source. Repair it before accepting this edit.")
        }
        _ = try resolvedSheetFace(declaration,size:.init(bounds.width,bounds.height),variables:variables,
          assemblyID:object.id,validateSourceCrops:active)
      }
      for finish in component.finishes ?? [] {
        try finish.validate()
        let declaration=finish.side == .outside ? component.front:component.back
        let artwork:Artwork?
        if let declaration,let target=objects.first(where:{$0.id==declaration.sourceObjectID}) {
          artwork=PaperConstruction.isPaper(target) ? paperArtwork(for:target,inside:declaration.sourceSide == .inside):surfaceArtwork(target)
        }else{artwork=paperArtwork(for:object,inside:finish.side == .inside)}
        if finish.enabled {
          guard let artwork,Set(finish.elementIDs).isSubset(of:Set(artwork.elements.map(\.id))) else {
            throw FormError.invalid("Finish ‘\(finish.name)’ on cut piece ‘\(component.id)’ needs its original source layers. Restore or explicitly retarget the finish.")
          }
        }
      }
    }
    guard !artworkDependencyCycle(from:object.id) else{throw FormError.invalid("A cut-piece artwork source cannot feed a live physical view back into its own assembly.")}
  }
}
