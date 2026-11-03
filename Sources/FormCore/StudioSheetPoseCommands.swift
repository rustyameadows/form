import Foundation
import CoreFoundation

/// Targeted edits retain the saved scene revision/Undo contract and the existing
/// StudioSheetPose inheritance model. They never edit the physical source.
public enum StudioSheetPoseCommands {
  public static let names: Set<String> = ["pose_get", "pose_update", "pose_reset"]
  public static let readOnlyNames: Set<String> = ["pose_get"]
  public static func call(engine: OperationEngine, arguments: [String: Any], source author: String) throws -> Any {
    guard let project = engine.project, let command = arguments["command"] as? String, names.contains(command) else {
      throw FormError.invalid("Open a project and choose a publication instance pose command.")
    }
    let fields: Set<String>
    if command == "pose_get" { fields = ["command", "scene_id", "instance_id", "offset", "limit"] }
    else if command == "pose_reset" { fields = ["command", "scene_id", "instance_id", "revision"] }
    else { fields = ["command", "scene_id", "instance_id", "revision", "pose", "publication_page_id", "page_object_id", "page_label"] }
    guard Set(arguments.keys).isSubset(of: fields) else { throw FormError.invalid("Unknown publication instance pose argument.") }
    func id(_ key: String) throws -> UUID {
      guard let raw = arguments[key] as? String, let id = UUID(uuidString: raw) else { throw FormError.invalid("Provide a valid \(key).") }; return id
    }
    let sceneID = try id("scene_id"), instanceID = try id("instance_id")
    guard var scene = project.studioPresentation?.scenes?.first(where: { $0.id == sceneID }),
      let index = scene.instances.firstIndex(where: { $0.id == instanceID }),
      let sourceID = scene.instances[index].sourceObjectID,
      let object = project.objects.first(where: { $0.id == sourceID }), let definition = object.sheetAssembly,
      let document = project.publications?.first(where: { $0.id == definition.publicationID }) else {
      throw FormError.missing("Choose an instance of an existing physical publication in a saved Studio scene.")
    }
    if command == "pose_get" {
      return try inspect(project: project, scene: scene, instance: scene.instances[index], object: object,
        pagination: .parse(arguments))
    }
    guard let revision = arguments["revision"] as? NSNumber, CFGetTypeID(revision) != CFBooleanGetTypeID(),
      revision.doubleValue == Double(scene.revision) else {
      throw FormError.invalid("The saved scene changed or its revision is missing. Read pose_get before updating this instance.")
    }
    let previous = scene
    if command == "pose_reset" { scene.instances[index].sheetPose = nil }
    else {
      let selectors = ["publication_page_id", "page_object_id", "page_label"].filter { arguments[$0] != nil }
      guard selectors.count <= 1 else { throw FormError.invalid("Choose one logical-page ID, artwork-page ID or exact unique page label.") }
      let patch: [String: Any]
      if let raw = arguments["pose"] {
        try PublicationPhysicalToolSchema.validateFields(raw, schema: PublicationPhysicalToolSchema.posePatch, path: "pose")
        guard let value = raw as? [String: Any] else { throw FormError.invalid("pose must be a partial object; use pose_reset to clear it.") }
        patch = value
      } else { patch = [:] }
      guard !patch.isEmpty || !selectors.isEmpty else { throw FormError.invalid("Provide a pose field or a page selector.") }
      guard selectors.isEmpty || patch["activeSpread"] == nil else {
        throw FormError.invalid("A page selector and pose.activeSpread cannot be supplied together.")
      }
      var raw = try jsonObject(scene.instances[index].sheetPose ?? StudioSheetPose()) as! [String: Any]
      for (key, value) in patch { if value is NSNull { raw.removeValue(forKey: key) } else { raw[key] = value } }
      var pose = try JSONDecoder.form.decode(StudioSheetPose.self, from: JSONSerialization.data(withJSONObject: raw))
      if let selector = selectors.first {
        let page: PublicationPage?
        if selector == "page_label" {
          guard let label = arguments[selector] as? String, !label.isEmpty, label.utf8.count <= 512 else { throw FormError.invalid("Use a bounded exact page label.") }
          let matching = document.pages.filter { document.pageLabel(for: $0.objectID) == label }
          guard matching.count == 1 else { throw FormError.invalid("That printed page label is missing or ambiguous; use publication_page_id or page_object_id.") }
          page = matching.first
        } else {
          let requested = try id(selector)
          page = document.pages.first { selector == "publication_page_id" ? $0.id == requested : $0.objectID == requested }
        }
        guard let page else { throw FormError.missing("The selected page is not in this instance's publication.") }
        let leaves = try project.resolvedSheetAssembly(object).leaves
        let positions = leaves.enumerated().compactMap { index, leaf -> Int? in
          if leaf.frontPageID == page.id { return index }; if leaf.backPageID == page.id { return index + 1 }; return nil
        }
        guard positions.count == 1, let spread = positions.first else { throw FormError.invalid("The selected page has no unique physical leaf face in this assembly.") }
        pose.activeSpread = spread
      }
      scene.instances[index].sheetPose = pose.isEmpty ? nil : pose
    }
    if scene == previous {
      return try inspect(project: project, scene: scene, instance: scene.instances[index], object: object, pagination: .init())
    }
    scene.revision += 1
    try scene.validate(); try scene.validateSourcePoses(in: project, previous: previous)
    let report = try inspect(project: project, scene: scene, instance: scene.instances[index], object: object, pagination: .init())
    try engine.edit(command == "pose_reset" ? "Reset Studio publication pose" : "Changed Studio publication pose", source: author) { candidate in
      guard let target = candidate.studioPresentation?.scenes?.firstIndex(where: { $0.id == sceneID }),
        candidate.studioPresentation?.scenes?[target].revision == previous.revision else {
        throw FormError.invalid("The saved scene changed before the pose could be applied.")
      }
      candidate.studioPresentation!.scenes![target] = scene
    }
    return report
  }
  private static func inspect(project: Project, scene: StudioComposition, instance: StudioInstance,
    object: ProductObject, pagination: PublicationPhysicalInspection.Page) throws -> [String: Any] {
    guard let source = object.sheetAssembly,
      let document = project.publications?.first(where: { $0.id == source.publicationID }) else { throw FormError.missing("Physical publication source is missing.") }
    let effectiveObject = try (instance.sheetPose ?? .init()).applying(to: object, in: project, clampingSpread: true)
    let effective = effectiveObject.sheetAssembly!, resolved = try project.resolvedSheetAssembly(effectiveObject)
    let pose = instance.sheetPose
    let reader = PublicationPhysicalInspection.spread(effective.activeSpread, document: document, leaves: resolved.leaves)
    let closed = effective.openingDegrees == 0
    let shown: [String: Any] = closed
      ? ["front": PublicationPhysicalInspection.page(resolved.leaves.first?.frontPageID, document: document),
         "back": PublicationPhysicalInspection.page(resolved.leaves.last?.backPageID, document: document)]
      : ["left": reader["left"]!, "right": reader["right"]!]
    return try PublicationPhysicalInspection.bounded([
      "schema_version": 1, "project_id": project.id.uuidString, "scene_id": scene.id.uuidString,
      "revision": scene.revision, "instance_id": instance.id.uuidString, "source_object_id": object.id.uuidString,
      "publication_id": document.id.uuidString, "instance_name": instance.name,
      "units": ["length": "millimeters", "angle": "degrees", "active_spread": "turned physical leaves"],
      "authored": try pose.map(jsonObject) ?? NSNull(), "source": try PublicationPhysicalInspection.pose(source),
      "effective": try PublicationPhysicalInspection.pose(effective),
      "field_origins": ["openingDegrees": pose?.openingDegrees == nil ? "source" : "instance",
        "activeSpread": pose?.activeSpread == nil ? "source" : "instance", "bendMM": pose?.bendMM == nil ? "source" : "instance",
        "bindingStyle": pose?.bindingStyle == nil ? "source" : "instance"],
      "spread_clamped": pose?.activeSpread.map { $0 != effective.activeSpread } ?? false,
      "source_binding": try source.binding.map(jsonObject) ?? NSNull(),
      "resolved_binding": try resolved.binding.map(jsonObject) ?? NSNull(),
      "leaf_count": resolved.leaves.count, "selected_reader_spread": reader,
      "displayed_faces": shown, "closed": closed,
      "face_semantics": "Principal physical reader faces or closed outer faces; not a camera-occlusion guarantee. A page selector changes the remembered spread, not the opening angle.",
      "available_spreads": pagination.section(Array(0...resolved.leaves.count)) {
        PublicationPhysicalInspection.spread($0, document: document, leaves: resolved.leaves)
      }])
  }
}
