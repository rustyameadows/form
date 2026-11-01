import AppKit
import FormCore

/// A portable, explicit address for chat. IDs remain source IDs; view-only
/// projection and Studio instance IDs are named separately, never substituted.
struct LABSelectionReference: Codable, Equatable {
  static let contextIDLimit = 4_096
  var version = 1
  var projectID: UUID
  var kind: String
  var label: String
  var objectID: UUID?
  var objectIDs: [UUID] = []
  var frameID: UUID?
  var elementIDs: [UUID] = []
  var nodeIDs: [UUID] = []
  var physicalObjectID: UUID?
  var surfaceID: String?
  var side: String?
  var shotID: UUID?
  var sceneID: UUID?
  var instanceID: UUID?
  var sourceObjectID: UUID?
  var saved: Bool?
  var sceneSaved: Bool?
  var instanceSaved: Bool?
  var hasUnsavedChanges: Bool?
  var sourceAvailable: Bool?
  enum CodingKeys: String, CodingKey {
    case version, kind, label, side, saved
    case projectID = "project_id", objectID = "object_id", objectIDs = "object_ids"
    case frameID = "frame_id", elementIDs = "element_ids", nodeIDs = "node_ids"
    case physicalObjectID = "physical_object_id", surfaceID = "surface_id"
    case sceneID = "scene_id", instanceID = "instance_id", sourceObjectID = "source_object_id"
    case shotID = "shot_id"
    case sourceAvailable = "source_available"
    case sceneSaved = "scene_saved", instanceSaved = "instance_saved", hasUnsavedChanges = "has_unsaved_changes"
  }
  var json: [String: Any] { (try? jsonObject(self)) as? [String: Any] ?? [:] }
  /// Bridge snapshots are bounded; an explicit clipboard reference retains all
  /// IDs. Completeness and totals prevent a preview from becoming an edit scope.
  var contextJSON: [String: Any] {
    var preview = self
    preview.elementIDs = Array(elementIDs.prefix(Self.contextIDLimit))
    preview.nodeIDs = Array(nodeIDs.prefix(Self.contextIDLimit))
    preview.objectIDs = Array(objectIDs.prefix(Self.contextIDLimit))
    var result = preview.json
    result["ids_limit"] = Self.contextIDLimit
    result["ids_complete"] = elementIDs.count <= Self.contextIDLimit
      && nodeIDs.count <= Self.contextIDLimit && objectIDs.count <= Self.contextIDLimit
    result["element_count"] = elementIDs.count
    result["node_count"] = nodeIDs.count
    result["object_count"] = objectIDs.count
    return result
  }
  var copiedText: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "" }
    return "LAB selection reference\n" + text
  }
  var copiedIDs: String {
    let ids: [UUID]
    if !nodeIDs.isEmpty { ids = nodeIDs }
    else if !elementIDs.isEmpty { ids = elementIDs }
    else if let instanceID { ids = [instanceID] }
    else if let sceneID { ids = [sceneID] }
    else if let shotID { ids = [shotID] }
    else if !objectIDs.isEmpty { ids = objectIDs }
    else if let objectID { ids = [objectID] }
    else if let physicalObjectID { ids = [physicalObjectID] }
    else if let frameID { ids = [frameID] }
    else { ids = [] }
    return ids.map(\.uuidString).joined(separator: "\n")
  }
}

extension StudioStore {
  var currentSelectionReference: LABSelectionReference? {
    guard !showingHome, project != nil else { return nil }
    if environment == .studio || (environment == .form && mode == .studio) {
      if studioShowingImages { return nil }
      if studioShowingShots { return objectSelectionReference(engine.selection) ?? shotSelectionReference() }
      return studioSelectionReference()
    }
    if environment == .function || environment == .fabricate {
      return objectSelectionReference(engine.selection)
    }
    if mode == .artwork { return canvasSelectionReference() }
    return objectSelectionReference(engine.selection)
  }

  func objectSelectionReference(_ ids: Set<UUID>) -> LABSelectionReference? {
    guard let project else { return nil }
    let objects = project.objects.filter { ids.contains($0.id) && $0.hasTablePresentation }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    guard let first = objects.first else { return nil }
    var ref = LABSelectionReference(projectID: project.id, kind: objects.count == 1 ? "object" : "objects",
      label: objects.count == 1 ? first.name : "\(objects.count) Table objects")
    ref.objectIDs = objects.map(\.id)
    if objects.count == 1 { ref.objectID = first.id }
    return ref
  }

  /// Supplying a frame/selection addresses a context-menu row without activating
  /// it. Reading this method must not reconcile, commit fields or move the camera.
  func canvasSelectionReference(frameID: UUID? = nil, elementIDs: Set<UUID>? = nil) -> LABSelectionReference? {
    guard let project else { return nil }
    let session = artworkSession
    let requested = frameID ?? session.activeFrameID
    guard let requested, let frame = session.frames.first(where: { $0.id == requested }) else { return nil }
    let projection = frame.projection
    let sourceID = projection?.sourceID ?? project.artworkOwner(frame.object).id
    let source = project.objects.first { $0.id == sourceID }
    let sourceAvailable = source != nil && projection?.requiresInsideSource != true
    let art = sourceAvailable ? source.flatMap { project.editableArtwork($0) } : nil
    let chosen = elementIDs ?? (frame.id == session.activeFrameID ? session.selection : [])
    let elements = (art?.elements ?? []).filter { chosen.contains($0.id) }
    // Explicit missing layers are not silently promoted into a whole-artboard target.
    guard chosen.isEmpty || !elements.isEmpty else { return nil }
    var ref = LABSelectionReference(projectID: project.id,
      kind: !elements.isEmpty ? "artwork_elements" : projection != nil ? "physical_surface" : frame.isWorkspace ? "canvas" : "artboard",
      label: elements.count == 1 ? elements[0].title : elements.isEmpty ? frame.title : "\(elements.count) layers · \(frame.title)")
    ref.frameID = frame.id
    ref.objectID = sourceAvailable ? sourceID : nil
    ref.sourceAvailable = sourceAvailable
    ref.elementIDs = elements.map(\.id).sorted { $0.uuidString < $1.uuidString }
    if elementIDs == nil, frame.id == session.activeFrameID {
      let available = Set(elements.flatMap { $0.path?.contours.flatMap(\.nodes).map(\.id) ?? [] })
      ref.nodeIDs = session.nodes.intersection(available).sorted { $0.uuidString < $1.uuidString }
    }
    if let projection {
      ref.physicalObjectID = projection.constructionID
      ref.surfaceID = projection.panelID
      ref.side = projection.inside ? "inside" : "outside"
    } else if frame.surfaceObject.id != sourceID { ref.physicalObjectID = frame.surfaceObject.id }
    return ref
  }

  func shotSelectionReference() -> LABSelectionReference? {
    guard let project, let id = studioShots.reviewingID ?? studioShots.editingID,
      let shot = project.studioPresentation?.shots.first(where: { $0.id == id }) else { return nil }
    var ref = LABSelectionReference(projectID: project.id, kind: "studio_shot", label: shot.name)
    ref.shotID = shot.id; ref.saved = true
    return ref
  }

  func studioSelectionReference(sceneID: UUID? = nil, instanceID: UUID? = nil) -> LABSelectionReference? {
    guard let project else { return nil }
    let controller = studioComposition
    let savedScenes = project.studioPresentation?.scenes ?? []
    let scene: StudioComposition
    if let sceneID {
      if controller.contextProjectID == project.id, let draft = controller.draft, draft.id == sceneID,
         !controller.contextWasSaved || savedScenes.contains(where: { $0.id == sceneID }) {
        scene = draft
      } else if let found = savedScenes.first(where: { $0.id == sceneID }) {
        scene = found
      } else { return nil }
    } else {
      guard controller.contextProjectID == project.id, let draft = controller.draft,
        !controller.contextWasSaved || savedScenes.contains(where: { $0.id == draft.id }) else { return nil }
      scene = draft
    }
    let requestedInstance = instanceID ?? (sceneID == nil ? controller.selectedInstanceID : nil)
    let instance = scene.instances.first { $0.id == requestedInstance }
    guard requestedInstance == nil || instance != nil else { return nil }
    var ref = LABSelectionReference(projectID: project.id, kind: instance == nil ? "studio_scene" : "studio_instance",
      label: instance.map { $0.name + " · " + scene.name } ?? scene.name)
    ref.sceneID = scene.id; ref.instanceID = instance?.id
    let savedScene = savedScenes.first { $0.id == scene.id }
    ref.sceneSaved = savedScene != nil
    ref.hasUnsavedChanges = savedScene != scene
    if let instance {
      ref.instanceSaved = savedScene?.instances.contains { $0.id == instance.id } == true
      ref.saved = ref.instanceSaved
    } else { ref.saved = ref.sceneSaved }
    ref.sourceObjectID = instance?.sourceObjectID
    if let sourceID = instance?.sourceObjectID {
      ref.sourceAvailable = project.objects.contains { $0.id == sourceID && $0.hasTablePresentation }
    }
    return ref
  }

  @discardableResult
  func copySelectionReference(_ reference: LABSelectionReference?, idsOnly: Bool = false,
                              pasteboard: NSPasteboard? = nil) -> Bool {
    guard let reference, let reference = resolvedSelectionReference(reference) else { return false }
    let value = idsOnly ? reference.copiedIDs : reference.copiedText
    guard !value.isEmpty else { return false }
    let pasteboard = pasteboard ?? selectionReferencePasteboard ?? .general
    pasteboard.clearContents()
    guard pasteboard.setString(value, forType: .string) else { return false }
    toast(idsOnly ? "ID copied" : "Reference copied · paste into chat")
    return true
  }

  /// Compact, read-only native state. The active target follows the last LAB
  /// surface, even while another application (such as Codex) is foreground.
  func selectionContext() -> [String: Any] {
    let null = NSNull()
    let physicalEnvironment = environment == .function || environment == .fabricate
    let inStudio = environment == .studio || (environment == .form && mode == .studio)
    var result: [String: Any] = [
      "schema_version": 1, "ui_available": true,
      "project_id": project?.id.uuidString as Any? ?? null,
      "project_name": project?.name as Any? ?? null,
      "home_visible": showingHome,
      "environment": showingHome ? "home" : environment.rawValue,
      "focused_surface": showingHome ? "home" : physicalEnvironment ? "table" : mode.rawValue.lowercased(),
      "focus_scope": "last_active_lab_surface",
      "layout": surfaceLayout.rawValue,
      "canvas_window_open": canvasWindowController?.window?.isVisible == true,
      "active_target": null, "canvas": null, "table": null, "studio": null,
    ]
    guard let project, !showingHome else { return result }
    let studioSubview = studioShowingImages ? "images" : studioShowingShots ? "shots" : "composition"
    result["studio_subview"] = inStudio ? studioSubview as Any : null
    result["project_generation"] = engine.projectGeneration
    result["active_target"] = currentSelectionReference?.contextJSON ?? null as Any
    let tableObjects = project.objects.filter { engine.selection.contains($0.id) && $0.hasTablePresentation }
    let idLimit = LABSelectionReference.contextIDLimit
    let tableIDs = tableObjects.map { $0.id.uuidString }.sorted()
    let isolatedIDs = isolated.intersection(Set(project.objects.map(\.id))).map(\.uuidString).sorted()
    let paperObject = tableObjects.count == 1 ? tableObjects.first(where: { $0.id == paperSelectionObjectID && PaperConstruction.isPaper($0) }) : nil
    let paperNet = paperObject.flatMap { try? PaperConstruction.definition(for: $0).net() }
    let panel = paperSelectedPanelID.flatMap { id in paperNet?.panels.contains(where: { $0.id == id }) == true ? id : nil }
    let fold = paperSelectedFoldID.flatMap { id in paperNet?.folds.contains(where: { $0.id == id }) == true ? id : nil }
    result["table"] = [
      "active": physicalEnvironment || (environment == .form && mode == .table) || (inStudio && studioSubview == "shots"),
      "selected_object_ids": Array(tableIDs.prefix(idLimit)),
      "selected_object_count": tableIDs.count,
      "selection_complete": tableIDs.count <= idLimit,
      "selected_objects": tableObjects.prefix(64).map { ["id": $0.id.uuidString, "name": $0.name, "recipe_id": $0.recipeID, "locked": $0.locked] as [String: Any] },
      "details_truncated": tableObjects.count > 64,
      "isolated_object_ids": Array(isolatedIDs.prefix(idLimit)),
      "isolated_object_count": isolatedIDs.count,
      "isolation_complete": isolatedIDs.count <= idLimit,
      "paper_object_id": paperObject?.id.uuidString as Any? ?? null,
      "selected_panel_id": panel as Any? ?? null,
      "selected_fold_id": fold as Any? ?? null,
      "paper_side": paperObject == nil ? null as Any : paperInside ? "inside" : "outside",
    ] as [String: Any]
    if let ref = canvasSelectionReference(), let frameID = ref.frameID,
       let frame = artworkSession.frames.first(where: { $0.id == frameID }) {
      let session = artworkSession
      let art = ref.objectID.flatMap { id in project.objects.first { $0.id == id } }.flatMap { project.editableArtwork($0) }
      let selectedIDs = Set(ref.elementIDs)
      let elements = (art?.elements ?? []).filter { selectedIDs.contains($0.id) }
      let available = Set((art?.elements ?? []).map(\.id))
      var canvas: [String: Any] = [
        "active": environment == .form && mode == .artwork,
        "reference": ref.contextJSON, "frame_name": frame.title, "tool": session.tool.rawValue,
        "editable": frame.editable && ref.sourceAvailable == true,
        "selected_element_ids": ref.elementIDs.prefix(idLimit).map(\.uuidString),
        "selected_node_ids": ref.nodeIDs.prefix(idLimit).map(\.uuidString),
        "selected_element_count": ref.elementIDs.count,
        "selected_node_count": ref.nodeIDs.count,
        "selection_complete": ref.elementIDs.count <= idLimit && ref.nodeIDs.count <= idLimit,
        "selected_elements": elements.prefix(64).map { e in
          ["id": e.id.uuidString, "name": String(e.title.prefix(160)), "kind": e.kind,
           "parent_id": e.parentID?.uuidString as Any? ?? null,
           "locked": art?.isLocked(e) ?? (e.locked == true),
           "component_source_id": e.component?.sourceObjectID.uuidString as Any? ?? null] as [String: Any]
        },
        "details_truncated": elements.count > 64,
        "group_scope_id": session.scopeID.flatMap { available.contains($0) ? $0.uuidString : nil } as Any? ?? null,
        "mask_editing_id": session.maskEditing.flatMap { available.contains($0.maskID) ? $0.maskID.uuidString : nil } as Any? ?? null,
        "text_editing": session.editingText,
        "text_selection_utf16": session.editingText ? ["location": session.characterRange.location, "length": session.characterRange.length] as Any : null,
        "uncommitted_text_may_differ": session.editingText,
      ]
      if let sourceID = ref.objectID { canvas["canonical_artwork_query"] = ["object_id": sourceID.uuidString] }
      if let projection = frame.projection {
        canvas["physical_surface"] = ["kind": projection.physicalIdentity.kind.rawValue,
          "object_id": projection.constructionID.uuidString, "surface_id": projection.panelID as Any? ?? null,
          "side": projection.inside ? "inside" : "outside", "source_to_view": (try? jsonObject(projection.sourceToLocal)) ?? null] as [String: Any]
        if ref.sourceAvailable == true, PaperConstruction.isPaper(frame.surfaceObject) {
          var physical: [String: Any] = ["side": projection.inside ? "inside" : "outside"]
          if let id = projection.panelID { physical["surface_id"] = id }
          canvas["view_artwork_query"] = ["object_id": projection.constructionID.uuidString, "physical_frame": physical]
        }
      }
      result["canvas"] = canvas
    }
    let controller = studioComposition
    if controller.contextProjectID == project.id, let scene = controller.draft,
       !controller.contextWasSaved || project.studioPresentation?.scenes?.contains(where: { $0.id == scene.id }) == true {
      let instance = scene.instances.first { $0.id == controller.selectedInstanceID }
      result["studio"] = [
        "active": inStudio && studioSubview == "composition",
        "scene_id": scene.id.uuidString, "scene_name": scene.name, "scene_revision": scene.revision,
        "saved": project.studioPresentation?.scenes?.contains(where: { $0.id == scene.id }) == true,
        "has_unsaved_changes": (project.studioPresentation?.scenes?.first(where: { $0.id == scene.id })) != scene,
        "native_draft_changed": controller.dirty,
        "selected_instance_id": instance?.id.uuidString as Any? ?? null,
        "selected_instance": instance.flatMap { try? jsonObject($0) } ?? null,
        "source_object_id": instance?.sourceObjectID?.uuidString as Any? ?? null,
        "pending_scene_id": controller.pendingSceneID?.uuidString as Any? ?? null,
        "reference": studioSelectionReference()?.contextJSON ?? null as Any,
      ] as [String: Any]
    }
    if inStudio && studioSubview == "shots" {
      result["shot"] = shotSelectionReference()?.contextJSON ?? null as Any
    }
    return result
  }
}
