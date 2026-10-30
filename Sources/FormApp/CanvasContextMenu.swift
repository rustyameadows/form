import AppKit
import FormCore
import FormGraphics

extension Notification.Name {
  static let formShowCanvasInspector = Notification.Name("studio.form.showCanvasInspector")
}

private final class CanvasMenuAction: NSObject {
  enum Kind {
    case command(String, String?), select(UUID), inspector, enterGroup(UUID), leaveGroup, canvas
    case outlines, findOnTable(UUID), component(UUID)
  }
  let projectID: UUID, frameID: UUID
  let selection: Set<UUID>
  let kind: Kind
  init(projectID: UUID, frameID: UUID, selection: Set<UUID>, kind: Kind) {
    self.projectID = projectID; self.frameID = frameID; self.selection = selection; self.kind = kind
  }
}

extension VectorCanvasView {
  func makeCanvasContextMenu(for event: NSEvent) -> NSMenu {
    let menu = NSMenu(); menu.autoenablesItems = false
    guard let session, let store = session.store else { return menu }
    prepareForGroupNavigation()
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    finishText(); session.endGesture()
    store.activateDesignSurface(.artwork)
    synchronize()
    let physical = canvasPoint(convert(event.locationInWindow, from: nil))
    if session.maskEditing == nil, let frame = frame(atCanvasPoint: physical), frame.id != activeFrame?.id {
      session.activate(frame.id); synchronize()
    }
    guard let project = store.project, let frame = activeFrame else { return menu }
    let art = session.art
    let point = CGPoint(x: physical.x - frame.rect.minX, y: physical.y - frame.rect.minY)
    let hidden = ArtworkProduction.hiddenIDs(in: frame.artwork, roles: session.hiddenProductionRoles)
    let targets = ArtworkHitTesting.layers(at: point, in: art, tolerance: 3.5 / (TypographyEngine.pointsPerMM * zoom),
      excluding: hidden, renderedArtwork: frame.artwork)
    // Merely opening a menu must not leave mask editing. A deep layer choice is
    // explicit navigation; otherwise retain the mask and its inspector context.
    if session.maskEditing == nil {
      let scoped = targets.first { $0.parentID == session.scopeID }
      if let target = scoped ?? externalGroupTarget(at: point, in: art, frame: frame) {
        if target.parentID != session.scopeID || !session.selection.contains(target.id) {
          session.navigateGroup(to: target.parentID, selection: [target.id])
        }
      } else { session.choose([]) }
    }
    window?.makeFirstResponder(self)
    needsDisplay = true

    let roots = art.selectionRoots(session.selection)
    let editable = session.maskEditing == nil && frame.editable && !roots.isEmpty && roots.allSatisfy { !art.isLocked($0) }
    func item(_ title: String, _ kind: CanvasMenuAction.Kind, enabled: Bool = true) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(performCanvasMenuAction(_:)), keyEquivalent: "")
      item.target = self; item.isEnabled = enabled
      item.representedObject = CanvasMenuAction(projectID: project.id, frameID: session.activeFrameID ?? frame.id,
        selection: session.selection, kind: kind)
      return item
    }

    menu.addItem(item("Show Inspector", .inspector))
    let select = NSMenuItem(title: "Select Layer", action: nil, keyEquivalent: "")
    let selectionMenu = NSMenu(); selectionMenu.autoenablesItems = false
    let byID = Dictionary(uniqueKeysWithValues: art.elements.map { ($0.id, $0) })
    for target in targets {
      var names = [String(target.title.prefix(64))], parent = target.parentID, seen = Set<UUID>()
      while let id = parent, let group = byID[id], seen.insert(id).inserted {
        names.insert(String(group.title.prefix(40)), at: 0); parent = group.parentID
      }
      let label = names.joined(separator: " › ") + (art.isLocked(target) ? " (Locked)" : "")
      let choice = item(label, .select(target.id))
      choice.state = session.selection.contains(target.id) ? .on : .off
      choice.identifier = NSUserInterfaceItemIdentifier(target.id.uuidString)
      selectionMenu.addItem(choice)
    }
    select.submenu = selectionMenu; select.isEnabled = !targets.isEmpty
    menu.addItem(select)

    if let group = roots.first, roots.count == 1, group.kind == "group" {
      menu.addItem(item(group.component == nil ? "Enter Group" : "Edit Component Source",
        group.component == nil ? .enterGroup(group.id) : .component(group.id), enabled: editable))
    }
    if session.scopeID != nil { menu.addItem(item("Leave Group", .leaveGroup)) }
    if session.scopeID != nil || session.maskEditing != nil || session.componentReturn != nil {
      menu.addItem(item("Return to Canvas", .canvas))
    }
    menu.addItem(.separator())

    menu.addItem(item("Group", .command("group", nil),
      enabled: editable && roots.count >= 2 && Set(roots.map(\.parentID)).count == 1))
    let canUngroup = editable && roots.allSatisfy { group in
      group.kind == "group" && group.component == nil && (group.booleanOperation != nil ||
        (!group.hasActiveEffects && group.isolatedBlending != true && (group.opacity ?? 1) == 1
          && (group.blendMode == nil || group.blendMode == "normal")))
    }
    menu.addItem(item("Ungroup", .command("ungroup", nil), enabled: canUngroup))
    let arrange = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
    let arrangeMenu = NSMenu(); arrangeMenu.autoenablesItems = false
    for (title, mode) in [("Bring to Front", "front"), ("Bring Forward", "forward"),
      ("Send Backward", "backward"), ("Send to Back", "back")] {
      arrangeMenu.addItem(item(title, .command("reorder", mode), enabled: editable))
    }
    arrange.submenu = arrangeMenu; arrange.isEnabled = editable
    menu.addItem(arrange)
    let align = NSMenuItem(title: "Align", action: nil, keyEquivalent: "")
    let alignMenu = NSMenu(); alignMenu.autoenablesItems = false
    for (title, mode) in [("Align Left", "left"), ("Align Center", "center_x"), ("Align Right", "right"),
      ("Align Top", "top"), ("Align Middle", "center_y"), ("Align Bottom", "bottom")] {
      alignMenu.addItem(item(title, .command("align", mode), enabled: editable && roots.count >= 2))
    }
    align.submenu = alignMenu; align.isEnabled = editable && roots.count >= 2
    menu.addItem(align)
    let distribute = NSMenuItem(title: "Distribute", action: nil, keyEquivalent: "")
    let distributeMenu = NSMenu(); distributeMenu.autoenablesItems = false
    for (title, mode) in [("Horizontal Spacing", "horizontal"), ("Vertical Spacing", "vertical"),
      ("Horizontal Centers", "horizontal_centers"), ("Vertical Centers", "vertical_centers")] {
      distributeMenu.addItem(item(title, .command("distribute", mode), enabled: editable && roots.count >= 3))
    }
    distribute.submenu = distributeMenu; distribute.isEnabled = editable && roots.count >= 3
    menu.addItem(distribute)
    menu.addItem(item("Duplicate", .command("duplicate", nil), enabled: editable))
    menu.addItem(item("Convert Text to Outlines", .outlines,
      enabled: editable && roots.allSatisfy { $0.kind == "text" }))
    menu.addItem(item("Delete", .command("delete", nil), enabled: editable))

    var seenLinks = Set<UUID>()
    let links = LinkedInspectorRelationships.canvas(session, in: project).filter { seenLinks.insert($0.objectID).inserted }
    if !links.isEmpty {
      menu.addItem(.separator())
      if let link = links.first, links.count == 1 { menu.addItem(item("Find on Table", .findOnTable(link.objectID))) }
      else {
        let find = NSMenuItem(title: "Find on Table", action: nil, keyEquivalent: ""), submenu = NSMenu()
        submenu.autoenablesItems = false
        for link in links {
          submenu.addItem(item(project.objects.first { $0.id == link.objectID }?.name ?? link.title, .findOnTable(link.objectID)))
        }
        find.submenu = submenu; menu.addItem(find)
      }
    }
    return menu
  }

  @objc func performCanvasMenuAction(_ sender: NSMenuItem) {
    guard sender.isEnabled, let action = sender.representedObject as? CanvasMenuAction,
      let session, session.store?.project?.id == action.projectID,
      session.activeFrameID == action.frameID else { return }
    prepareForGroupNavigation()
    finishText(); session.endGesture()
    let art = session.art
    guard action.selection.isSubset(of: Set(art.elements.map(\.id))) else { return }
    switch action.kind {
    case .inspector:
      NotificationCenter.default.post(name: .formShowCanvasInspector, object: session)
    case .select(let id):
      guard let element = art.elements.first(where: { $0.id == id }) else { return }
      session.maskEditing = nil; session.navigateGroup(to: element.parentID, selection: [id])
      session.tool = .select
    case .enterGroup(let id):
      guard let group = art.elements.first(where: { $0.id == id }), group.kind == "group", !art.isLocked(group) else { return }
      session.enterGroup(id)
    case .leaveGroup:
      session.leaveGroup()
    case .canvas:
      if session.maskEditing != nil { session.returnFromMask() }
      if session.componentReturn != nil { session.returnToComponent() }
      session.leaveGroup(toRoot: true)
    case .command(let command, let mode):
      session.choose(action.selection)
      session.execute(command, mode.map { ["mode": $0] } ?? [:])
    case .outlines:
      session.choose(action.selection); session.convert()
    case .findOnTable(let id):
      _ = session.store?.findOnTable(id)
      return
    case .component(let id):
      guard let element = art.elements.first(where: { $0.id == id }), element.component != nil else { return }
      session.editComponentSource(element)
    }
    synchronize()
    window?.makeFirstResponder(self)
  }
}
