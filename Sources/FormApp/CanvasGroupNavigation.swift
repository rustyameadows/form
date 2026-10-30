import AppKit
import FormCore

extension ArtworkSession {
  /// Isolation is view state. Changing it must not retain a pointer transaction
  /// belonging to the previous scope or add an artwork Undo entry.
  func navigateGroup(to scope: UUID?, selection ids: Set<UUID> = []) {
    canvas?.prepareForGroupNavigation()
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    canvas?.finishText()
    endGesture()
    let artwork = art
    guard scope == nil || artwork.elements.contains(where: { $0.id == scope && $0.kind == "group" }) else { return }
    scopeID = scope
    croppingImageID = nil
    selectedGradientStopID = nil
    choose(ids.intersection(Set(artwork.elements.map(\.id))))
    canvas?.synchronize()
    canvas?.window?.makeFirstResponder(canvas)
  }

  func enterGroup(_ id: UUID) {
    let artwork = art
    guard let group = artwork.elements.first(where: { $0.id == id }),
      group.kind == "group", artwork.editable(group) else { return }
    if group.component != nil { editComponentSource(group); return }
    navigateGroup(to: id)
  }

  func leaveGroup(toRoot: Bool = false) {
    guard !toRoot, let group = art.elements.first(where: { $0.id == scopeID }) else {
      navigateGroup(to: nil)
      return
    }
    navigateGroup(to: group.parentID, selection: [group.id])
  }
}
