import Foundation

// Independent cut edges and explicit relief shoulders must survive portable
// material, publication and nested-panel saves, not only direct paper objects.
extension PaperStock {
  var usesCutEdgeAppearance:Bool {
    profile?.edgeAppearance != nil || plies?.contains(where:{$0.profile?.edgeAppearance != nil}) == true
  }
}
extension SheetPanelFeatures {
  var usesCutEdgeAppearance:Bool {
    wrap?.stock.usesCutEdgeAppearance == true || recesses?.contains(where:{$0.insert?.stock.usesCutEdgeAppearance == true}) == true
  }
}
extension ProductObject {
  var usesPaperMateriality:Bool {
    if patternAssembly?.panels.contains(where:{$0.material.paperStock?.usesCutEdgeAppearance == true}) == true {return true}
    if let paper=paperConstruction,
       paper.stock.usesCutEdgeAppearance || paper.finishes?.contains(where:{$0.shoulderRadiusMM != nil}) == true ||
       paper.authored?.components?.contains(where:{$0.stock?.usesCutEdgeAppearance == true || $0.finishes?.contains(where:{$0.shoulderRadiusMM != nil}) == true}) == true ||
       paper.authored?.panels.contains(where:{$0.features?.usesCutEdgeAppearance == true}) == true {return true}
    guard let sheet=sheetAssembly else{return false}
    return sheet.stock.usesCutEdgeAppearance ||
      sheet.leaves?.contains(where:{$0.stock?.usesCutEdgeAppearance == true || $0.finishes?.contains(where:{$0.shoulderRadiusMM != nil}) == true}) == true ||
      sheet.enclosure?.contains(where:{$0.stock.usesCutEdgeAppearance || $0.finishes?.contains(where:{$0.shoulderRadiusMM != nil}) == true || $0.features?.usesCutEdgeAppearance == true}) == true ||
      sheet.parentSheets?.contains(where:{$0.stock.usesCutEdgeAppearance}) == true ||
      sheet.auxiliaryLeaves?.contains(where:{$0.stock.usesCutEdgeAppearance}) == true
  }
}
