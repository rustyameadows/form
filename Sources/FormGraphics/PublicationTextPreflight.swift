import AppKit
import FormCore

extension PublicationOutput {
  /// Capacity precedes paint bounds: a frame with no accepted line has no ink
  /// bounds, but must still be reported as lost text.
  static func textPreflight(_ project: Project, document: PublicationDocument, page: PublicationPage,
                            object: ProductObject, artwork: Artwork, tree: ArtworkRenderTree)
    -> (frames: [[String: Any]], issues: [[String: Any]]) {
    var frames: [[String: Any]] = [], issues: [[String: Any]] = []
    let sources: [UUID: PublicationTextSource]
    do { sources = try project.publicationTextSources(for: object.id) }
    catch {
      sources = [:]
      issues.append(["severity": "error", "code": "text_source_unavailable", "message": error.localizedDescription,
        "page_id": object.id.uuidString, "page_object_id": object.id.uuidString, "publication_page_id": page.id.uuidString])
    }
    for original in artwork.elements where original.kind == "text" {
      let element = original.inheritingLanguage(artwork.language)
      let source = sources[element.id]
      let capacity = TypographyEngine.capacity(element)
      let included = tree.requiredForOutput(element) && TextPaintRenderer.hasEnabledPaint(element)
      let layoutStatus = !capacity.available ? "unavailable" : capacity.overflows ? "overset" : "fit"
      var address: [String: Any] = [
        "page_id": object.id.uuidString, // Retain the legacy page-object meaning.
        "page_object_id": object.id.uuidString, "publication_page_id": page.id.uuidString,
        "rendered_element_id": element.id.uuidString,
      ]
      if let source {
        address["object_id"] = source.objectID.uuidString; address["element_id"] = source.elementID.uuidString
        if let id = source.masterID { address["master_id"] = id.uuidString }
        if let id = source.masterSourceObjectID { address["master_source_object_id"] = id.uuidString }
        if let id = source.instanceObjectID { address["instance_object_id"] = id.uuidString }
        if let id = source.instanceElementID { address["instance_element_id"] = id.uuidString }
      }
      if let id = element.storyFrame?.storyID { address["story_id"] = id.uuidString }
      var record = address
      record["name"] = element.title
      record["kind"] = element.storyFrame != nil ? "story" : source?.masterID != nil ? "master" : "standalone"
      record["width_mm"] = element.width; record["height_mm"] = element.height
      record["included_in_output"] = included
      record["status"] = included || element.storyFrame != nil ? layoutStatus : "excluded"
      record["layout_status"] = layoutStatus
      record["source_length"] = capacity.sourceLength; record["display_length"] = capacity.displayLength
      record["source_location"] = capacity.sourceRange.location
      record["visible_source_length"] = capacity.sourceRange.length
      record["display_location"] = capacity.displayRange.location
      record["display_length_in_frame"] = capacity.displayRange.length
      record["overset_location"] = capacity.oversetRange.location; record["overset_length"] = capacity.oversetRange.length
      record["width_overflow"] = capacity.widthOverflow
      if let reference = element.storyFrame, let context = reference.resolved {
        record["terminal_story_frame"] = reference.frame == context.frames.last?.frame
      }
      frames.append(record)
      // Hidden linked frames still reserve global story capacity. Preserve the
      // existing story safety gate, but do not block output on excluded artwork.
      guard included || element.storyFrame != nil else { continue }
      if source == nil {
        var issue = address
        issue["severity"] = "error"; issue["code"] = "text_source_unavailable"
        issue["message"] = "The editable source for \(element.title) on \(page.label ?? object.name) could not be identified."
        issues.append(issue)
      }
      guard capacity.overflows else { continue }
      var issue = address
      issue["severity"] = "error"; issue["code"] = capacity.available ? "overset" : "text_layout_unavailable"
      issue["overset_location"] = capacity.oversetRange.location; issue["overset_length"] = capacity.oversetRange.length
      issue["width_overflow"] = capacity.widthOverflow
      let target = "\(element.title) on \(page.label ?? object.name)"
      if !capacity.available {
        issue["message"] = "The text layout for \(target) is unavailable. Repair its story/frame link before exporting."
      } else if capacity.oversetRange.length > 0 {
        let limit = element.storyFrame != nil ? "the final linked frame" : "its text frame"
        issue["message"] = "\(target) has \(capacity.oversetRange.length) source UTF-16 units beyond \(limit). Enlarge the frame or edit its source before exporting."
      } else {
        issue["message"] = "A glyph or unbreakable line in \(target) is wider than its text frame. Widen the frame or reduce its text size before exporting."
      }
      issues.append(issue)
    }
    return (frames, issues)
  }
}
