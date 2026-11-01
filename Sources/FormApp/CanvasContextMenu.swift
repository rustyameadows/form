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
    case generate(Point2, CanvasGenerationReference?), resumeGeneration(CanvasImagePromptIdentity)
    case copy(LABSelectionReference?, Bool)
  }
  let projectID: UUID, frameID: UUID
  let originFrameID: UUID?, scopeID: UUID?
  let selection: Set<UUID>
  let kind: Kind
  init(projectID: UUID, frameID: UUID, originFrameID: UUID?, scopeID: UUID?, selection: Set<UUID>, kind: Kind) {
    self.projectID = projectID; self.frameID = frameID; self.selection = selection; self.kind = kind
    self.originFrameID = originFrameID; self.scopeID = scopeID
  }
}

extension VectorCanvasView {
  func makeCanvasContextMenu(for event: NSEvent) -> NSMenu {
    let menu = NSMenu(); menu.autoenablesItems = false
    guard let session, let store = session.store else { return menu }
    prepareForGroupNavigation()
    synchronize()
    let physical = canvasPoint(convert(event.locationInWindow, from: nil))
    let header = session.frames.last { !$0.isWorkspace &&
      CanvasFrameChrome.headerRect(for: $0,scale: TypographyEngine.pointsPerMM*zoom).contains(physical) }
    guard let project = store.project,
      let frame = session.maskEditing == nil ? header ?? self.frame(atCanvasPoint: physical) ?? activeFrame : activeFrame else { return menu }
    let isActive = frame.id == activeFrame?.id
    let source = frame.projection?.requiresInsideSource == true
      ? frame.surfaceObject.paperConstruction?.insideArtwork ?? Artwork(background: "#FFFFFF")
      : project.editableArtwork(frame.object) ?? Artwork(background: "#FFFFFF")
    let art = isActive ? session.art : frame.projection?.display(source) ?? source
    var selection = isActive ? session.selection : [], scopeID = isActive ? session.scopeID : nil
    let point = CGPoint(x: physical.x - frame.rect.minX, y: physical.y - frame.rect.minY)
    let hidden = ArtworkProduction.hiddenIDs(in: frame.artwork, roles: session.hiddenProductionRoles)
    let targets = ArtworkHitTesting.layers(at: point, in: art, tolerance: 3.5 / (TypographyEngine.pointsPerMM * zoom),
      excluding: hidden, renderedArtwork: frame.artwork, outerClip: physicalPickingClip(for: frame), assets: session.assets)
    // Merely opening a menu must not leave mask editing. A deep layer choice is
    // explicit navigation; otherwise retain the mask and its inspector context.
    if session.maskEditing == nil {
      let scoped = targets.first { $0.parentID == scopeID }
      if let target = scoped ?? (isActive ? externalGroupTarget(at: point, in: art, frame: frame) : nil) {
        if target.parentID != scopeID || !selection.contains(target.id) {
          scopeID = target.parentID; selection = [target.id]
        }
      } else { selection = [] }
    }

    let roots = art.selectionRoots(selection)
    let editable = session.maskEditing == nil && frame.editable && !roots.isEmpty && roots.allSatisfy { !art.isLocked($0) }
    func item(_ title: String, _ kind: CanvasMenuAction.Kind, enabled: Bool = true) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(performCanvasMenuAction(_:)), keyEquivalent: "")
      item.target = self; item.isEnabled = enabled
      item.representedObject = CanvasMenuAction(projectID: project.id, frameID: frame.id,
        originFrameID: session.activeFrameID, scopeID: scopeID, selection: selection, kind: kind)
      return item
    }

    let reference = store.canvasSelectionReference(frameID: frame.id, elementIDs: selection)
    let copy = item("Copy reference", .copy(reference, false), enabled: reference != nil)
    copy.identifier = .init("canvas-copy-reference"); menu.addItem(copy)
    let ids = item(selection.count > 1 ? "Copy IDs" : "Copy ID", .copy(reference, true), enabled: reference != nil)
    ids.identifier = .init("canvas-copy-id"); menu.addItem(ids)
    menu.addItem(.separator())

    let generation=store.canvasImages
    if let identity = canvasImagePromptIdentity, identity.destinationID == frame.object.id {
      menu.addItem(item("Continue Image Prompt…", .resumeGeneration(identity)))
    }
    menu.addItem(item("Generate Image Here…", .generate(.init(physical.x,physical.y),nil), enabled:!generation.busy))
    if frame.object.recipeID == "artboard", !frame.object.isCanvasWorkspace || !roots.isEmpty {
      let reference=CanvasGenerationReference(objectID:frame.object.id,
        elementIDs:Array(selection),title:roots.count == 1 ? roots[0].title : roots.isEmpty ? frame.object.name : "Selected artwork")
      let selectionBounds = roots.map { art.bounds(of: $0) }.reduce(nil as Rect2?) { result, bounds in
        result.map { $0.union(bounds) } ?? bounds
      }
      let bounds=frame.object.isCanvasWorkspace ? selectionBounds.map {
        CGRect(x:$0.x+frame.rect.minX,y:$0.y+frame.rect.minY,width:$0.width,height:$0.height)
      } ?? frame.rect : frame.rect
      menu.addItem(item("Generate Image Using This as Reference…",
        .generate(.init(bounds.maxX+16,bounds.minY),reference),enabled:!generation.busy))
      if !frame.object.isCanvasWorkspace,!roots.isEmpty {
        let artboard=CanvasGenerationReference(objectID:frame.object.id,title:frame.object.name)
        menu.addItem(item("Generate Image Using This Artboard…",
          .generate(.init(frame.rect.maxX+16,frame.rect.minY),artboard),enabled:!generation.busy))
      }
    }
    menu.addItem(.separator())
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
      choice.state = selection.contains(target.id) ? .on : .off
      choice.identifier = NSUserInterfaceItemIdentifier(target.id.uuidString)
      selectionMenu.addItem(choice)
    }
    select.submenu = selectionMenu; select.isEnabled = !targets.isEmpty
    menu.addItem(select)

    if let group = roots.first, roots.count == 1, group.kind == "group" {
      let maskNavigation=group.component==nil && session.maskEditing.map{art.editableMaskElementIDs(rootID:$0.maskID).contains(group.id)} == true
      menu.addItem(item(group.component == nil ? "Enter Group" : "Edit Component Source",
        group.component == nil ? .enterGroup(group.id) : .component(group.id), enabled: editable || maskNavigation))
    }
    if scopeID != nil { menu.addItem(item("Leave Group", .leaveGroup)) }
    if scopeID != nil || session.maskEditing != nil || session.componentReturn != nil {
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
    let links = (isActive ? LinkedInspectorRelationships.canvas(session, in: project)
      : project.objects.filter { $0.hasTablePresentation && LinkedInspectorRelationships.hasPhysicalView($0,in:project) }
        .flatMap { LinkedInspectorRelationships.table($0,in:project) }
        .filter { $0.sourceID == frame.object.id && (frame.projection == nil || $0.objectID == frame.surfaceObject.id) })
      .filter { seenLinks.insert($0.objectID).inserted }
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
      let session, session.store?.project?.id == action.projectID else { return }
    if case .copy(let reference, let idsOnly) = action.kind {
      session.store?.copySelectionReference(reference, idsOnly: idsOnly)
      return
    }
    if case .resumeGeneration(let identity) = action.kind {
      requestCanvasImagePrompt(identity)
      return
    }
    guard session.activeFrameID == action.originFrameID else { return }
    prepareForGroupNavigation()
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    finishText(); session.endGesture()
    session.store?.activateDesignSurface(.artwork)
    if activeFrame?.id != action.frameID { session.activate(action.frameID); synchronize() }
    guard activeFrame?.id == action.frameID else { return }
    let art = session.art
    guard action.selection.isSubset(of: Set(art.elements.map(\.id))) else { return }
    if session.maskEditing == nil {
      session.navigateGroup(to: action.scopeID, selection: action.selection)
    }
    switch action.kind {
    case .generate(let point,let reference):
      do {
        _ = try session.store?.canvasImages.begin(at:point,reference:reference)
        synchronize()
        if let identity = canvasImagePromptIdentity {
          _ = fit(frameIDs: [identity.destinationID])
          requestCanvasImagePrompt(identity)
        }
      } catch { session.store?.error=error.localizedDescription }
      return
    case .resumeGeneration, .copy: return
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
