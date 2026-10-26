import Foundation

public enum PatternAssemblyPlanning {
  /// Explicit neutral arrangement for a user to edit. It deliberately selects
  /// no seams: correspondence/side/reversal are construction decisions.
  public static func arrangedPieces(in project:inout Project,sourceID:UUID,elements:Set<UUID>? = nil)throws -> PatternAssemblyDefinition {
    guard let source=project.objects.first(where:{$0.id==sourceID}),let art=source.artwork else {throw FormError.invalid("Choose an independent artwork source with annotated sewing pieces.")}
    let selected=elements ?? Set(art.elements.filter{$0.sewingPiece != nil}.map(\.id))
    let prepared=try PatternAssemblySource.prepare(in:&project,objectID:sourceID,elements:selected)
    var panels:[PatternPanelPlacement]=[],pins:[PatternAssemblyPin]=[],x=0.0
    for element in prepared.elements where selected.contains(element.id) {
      let geometry=try SewingPatterns.geometry(element,in:prepared),edges=try SewingCurves.boundaries(element,in:prepared).filter{!$0.isHole}.flatMap(\.edges)
      guard let edge=edges.first,let edgeID=edge.id,let endID=edge.endID else {throw FormError.invalid("Prepare original closed source boundaries before arranging assembly panels.")}
      let material=project.material(geometry.piece.materialID ?? "flight-nylon")
      guard let gsm=material.fabric?.weightGSM else {throw FormError.invalid("Declare fabric GSM before creating a mass-bearing assembly.")}
      guard (1...100).contains(geometry.piece.cutQuantity) else {throw FormError.invalid("Declare 1–100 source copies before assembly.")}
      for copy in 1...geometry.piece.cutQuantity {
        guard panels.count<8 else {throw FormError.invalid("Select at most 8 declared piece copies for one assembly study.")}
        let id=PatternPanelID(elementID:element.id,copy:copy)
        panels.append(.init(panel:id,pose:.init(originMm:.init(x,geometry.bounds.height+80,0)),material:material,densityGSM:gsm))
        pins.append(.init(panel:id,edgeID:edgeID,endID:endID,fraction:0.5));x+=geometry.bounds.width+30
      }
    }
    guard !panels.isEmpty else {throw FormError.invalid("Select annotated sewing pieces to arrange.")}
    var result=PatternAssemblyDefinition(sourceObjectID:sourceID,panels:panels,seamIDs:[],pins:pins,maximumEdgeMm:25)
    result.colliders=[.plane()];return result
  }
}
