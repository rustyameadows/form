import FormCore

extension StudioStore {
  /// Refresh a captured menu address without adopting the current selection or
  /// activating its editor. A partial surviving selection is not the same target.
  func resolvedSelectionReference(_ reference: LABSelectionReference) -> LABSelectionReference? {
    guard let project, project.id == reference.projectID else { return nil }
    switch reference.kind {
    case "object", "objects":
      let ids = Set(reference.objectIDs)
      guard !ids.isEmpty, ids.count == reference.objectIDs.count,
        let resolved = objectSelectionReference(ids), Set(resolved.objectIDs) == ids,
        resolved.objectID == reference.objectID, resolved.kind == reference.kind else { return nil }
      return resolved
    case "canvas", "artboard", "physical_surface", "artwork_elements":
      guard let frameID = reference.frameID else { return nil }
      let ids = Set(reference.elementIDs), nodes = Set(reference.nodeIDs)
      guard ids.count == reference.elementIDs.count, nodes.count == reference.nodeIDs.count,
        var resolved = canvasSelectionReference(frameID: frameID, elementIDs: ids),
        Set(resolved.elementIDs) == ids, resolved.kind == reference.kind,
        resolved.frameID == reference.frameID, resolved.objectID == reference.objectID,
        resolved.physicalObjectID == reference.physicalObjectID,
        resolved.surfaceID == reference.surfaceID, resolved.side == reference.side else { return nil }
      if !nodes.isEmpty {
        guard let sourceID = resolved.objectID,
          let source = project.objects.first(where: { $0.id == sourceID }),
          let art = project.editableArtwork(source) else { return nil }
        let available = Set(art.elements.filter { ids.contains($0.id) }
          .flatMap { $0.path?.contours.flatMap(\.nodes).map(\.id) ?? [] })
        guard nodes.isSubset(of: available) else { return nil }
      }
      resolved.nodeIDs = reference.nodeIDs
      return resolved
    case "studio_scene", "studio_instance":
      guard let sceneID = reference.sceneID,
        let resolved = studioSelectionReference(sceneID: sceneID, instanceID: reference.instanceID),
        resolved.kind == reference.kind, resolved.instanceID == reference.instanceID,
        resolved.sourceObjectID == reference.sourceObjectID else { return nil }
      return resolved
    case "studio_shot":
      guard let id = reference.shotID,
        let shot = project.studioPresentation?.shots.first(where: { $0.id == id }) else { return nil }
      var resolved = LABSelectionReference(projectID: project.id, kind: "studio_shot", label: shot.name)
      resolved.shotID = id; resolved.saved = true
      return resolved
    default:
      return nil
    }
  }
}
