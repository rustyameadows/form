import Foundation

extension ArtworkSession {
  func inspectorColorTarget(_ channel: String) -> String {
    let selected = selection.map(\.uuidString).sorted().joined(separator: ",")
    return "\(store?.project?.id.uuidString ?? "")/\((activeFrameID ?? objectID)?.uuidString ?? "")/\(selected)/\(editingText)/\(characterRange.location):\(characterRange.length)/\(channel)"
  }
  var inspectorEditing: (Bool) -> Void {
    let ordinary=store?.inspectorInteraction("artwork-\(objectID?.uuidString ?? "")") ?? { _ in }
    var finish:(()->Void)?
    return { [weak self] active in
      if active {
        guard finish==nil else{return}
        if self?.editingText==true,let canvas=self?.canvas,let token=canvas.beginNumericTextInteraction() {
          // A slider is one native text action, inside the editor's existing
          // artwork/story interaction. Ending it must not fence prior native
          // collection or character actions out of the Undo timeline.
          finish={ [weak canvas] in canvas?.endNumericTextInteraction(ifToken:token) }
        } else {ordinary(true);finish={ordinary(false)}}
      } else {let end=finish;finish=nil;end?()}
    }
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
