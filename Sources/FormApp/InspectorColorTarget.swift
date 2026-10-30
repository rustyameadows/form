import Foundation

extension ArtworkSession {
  func inspectorColorTarget(_ channel: String) -> String {
    let selected = selection.map(\.uuidString).sorted().joined(separator: ",")
    return "\(store?.project?.id.uuidString ?? "")/\((activeFrameID ?? objectID)?.uuidString ?? "")/\(selected)/\(editingText)/\(characterRange.location):\(characterRange.length)/\(channel)"
  }
  var inspectorEditing: (Bool) -> Void {
    store?.inspectorInteraction("artwork-\(objectID?.uuidString ?? "")") ?? { _ in }
  }
}

extension StudioStore {
  /// Each rendered control owns its interaction generation, including its final callback after retargeting.
  func inspectorInteraction(_ key: String) -> (Bool) -> Void {
    let engine = engine
    var generation: UUID?
    return { active in
      if active { generation = engine.beginInteraction(key) }
      else if let token = generation {
        engine.endInteraction(ifGeneration: token)
        generation = nil
      }
    }
  }
}
