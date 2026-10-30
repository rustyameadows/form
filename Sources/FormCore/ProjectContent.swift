import Foundation

public enum ProjectContent {
  public static func description(objects:Int,canvasItems:Int) -> String {
    let physical = "\(objects) \(objects == 1 ? "object" : "objects")"
    guard canvasItems > 0 else { return physical }
    return physical + " · \(canvasItems) Canvas \(canvasItems == 1 ? "item" : "items")"
  }
  public static func looseItems(in artwork:Artwork?) -> Int {
    guard let artwork else { return 0 }
    let masks = Set(artwork.elements.compactMap(\.clipID))
    return artwork.elements.filter { $0.parentID == nil && $0.hidden != true && !masks.contains($0.id) }.count
  }
}

extension Project {
  public var physicalObjectCount:Int { objects.filter(\.hasTablePresentation).count }
  public var looseCanvasItemCount:Int { ProjectContent.looseItems(in:canvasWorkspace?.artwork) }
  public var contentDescription:String {
    ProjectContent.description(objects:physicalObjectCount,canvasItems:looseCanvasItemCount)
  }
}

extension ProjectSummary {
  public var contentDescription:String {
    ProjectContent.description(objects:objectCount,canvasItems:canvasItemCount ?? 0)
  }
}
