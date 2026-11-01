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
    if let mask=maskEditing {
      let members=artwork.editableMaskElementIDs(rootID:mask.maskID)
      let rootParent=artwork.elements.first{$0.id==mask.maskID}?.parentID
      if !(scope.map(members.contains) ?? false) && !(scope==rootParent && ids==[mask.maskID]) {maskEditing=nil}
    }
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
      group.kind == "group", (maskEditing.map{artwork.editableMaskElementIDs(rootID:$0.maskID).contains(id)} ?? artwork.editable(group)) else { return }
    if maskEditing != nil,group.component != nil{return}
    if group.component != nil { editComponentSource(group); return }
    navigateGroup(to: id)
  }

  func leaveGroup(toRoot: Bool = false) {
    if let mask=maskEditing {
      let members=art.editableMaskElementIDs(rootID:mask.maskID)
      if toRoot {maskEditing=nil;tool=mask.tool;navigateGroup(to:nil);return}
      if scopeID==mask.maskID || scopeID.map(members.contains) != true {returnFromMask();return}
    }
    guard !toRoot, let group = art.elements.first(where: { $0.id == scopeID }) else {
      navigateGroup(to: nil)
      return
    }
    navigateGroup(to: group.parentID, selection: [group.id])
  }
}
