import Foundation
import CoreFoundation

/// Read-only projections of the canonical assembly. Large maps are paged, and
/// finish artwork is addressed by its owner rather than duplicated into a report.
public enum PublicationPhysicalInspection {
  public struct Page {
    public let offset: Int, limit: Int
    public init(offset: Int = 0, limit: Int = 25) throws {
      guard (0...200).contains(offset), (1...50).contains(limit) else {
        throw FormError.invalid("Inspection offset must be 0–200 and limit 1–50.")
      }
      self.offset = offset; self.limit = limit
    }
    static func parse(_ arguments: [String: Any]) throws -> Self {
      func integer(_ key: String, _ fallback: Int) throws -> Int {
        guard let raw = arguments[key] else { return fallback }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
          (0...200).contains(value.doubleValue) else { throw FormError.invalid("Use a bounded integer for \(key).") }
        return value.intValue
      }
      return try .init(offset: integer("offset", 0), limit: integer("limit", 25))
    }
    func section<T>(_ values: [T], row: (T) throws -> [String: Any]) rethrows -> [String: Any] {
      let end = min(values.count, offset + limit), start = min(offset, end)
      return ["total": values.count, "offset": offset, "limit": limit,
        "truncated": start > 0 || end < values.count,
        "next_offset": end < values.count ? end as Any : NSNull(),
        "items": try values[start..<end].map(row)]
    }
  }
  static func bounded(_ value: [String: Any]) throws -> [String: Any] {
    guard try JSONSerialization.data(withJSONObject: value).count <= 1_048_576 else {
      throw FormError.invalid("Physical inspection exceeds 1 MiB; request a smaller limit.")
    }
    return value
  }
  static func bindingState(_ value: SheetBindingDefinition?) -> String {
    value.map { $0.style == .none ? "unbound" : "bound" } ?? "unspecified"
  }
  static func page(_ id: UUID?, document: PublicationDocument) -> Any {
    guard let id, let page = document.pages.first(where: { $0.id == id }) else { return NSNull() }
    return ["publication_page_id": id.uuidString, "page_object_id": page.objectID.uuidString,
      "label": document.pageLabel(for: page.objectID)]
  }
  static func spread(_ index: Int, document: PublicationDocument, leaves: [ResolvedSheetAssemblyLeaf]) -> [String: Any] {
    ["active_spread": index,
      "left": page(index > 0 && index <= leaves.count ? leaves[index - 1].backPageID : nil, document: document),
      "right": page(leaves.indices.contains(index) ? leaves[index].frontPageID : nil, document: document)]
  }
  static func pose(_ definition: SheetAssemblyDefinition) throws -> [String: Any] {
    ["openingDegrees": definition.openingDegrees, "activeSpread": definition.activeSpread, "bendMM": definition.bendMM,
      "bindingStyle": definition.binding?.style.rawValue as Any? ?? NSNull(),
      "binding_state": bindingState(definition.binding)]
  }
  public static func inspect(project: Project, object: ProductObject, page pagination: Page) throws -> [String: Any] {
    guard let definition = object.sheetAssembly,
      let document = project.publications?.first(where: { $0.id == definition.publicationID }) else {
      throw FormError.missing("Choose a physical sheet assembly with an existing publication.")
    }
    let resolved = try project.resolvedSheetAssembly(object)
    let closedBounds:Any
    if let bounds=resolved.closedBoundsMM {
      closedBounds=["minimum_mm":[bounds.minimum.x,bounds.minimum.y,bounds.minimum.z],
        "maximum_mm":[bounds.maximum.x,bounds.maximum.y,bounds.maximum.z]]
    }else{closedBounds=NSNull()}
    var authored = try pose(definition)
    authored["version"] = definition.version; authored["stock"] = try jsonObject(definition.stock)
    authored["binding"] = try definition.binding.map(jsonObject) ?? NSNull()
    authored["leaf_pairing"] = definition.leaves == nil ? "derived" : "explicit"
    authored["parent_sheet_mapping"] = definition.parentSheets?.isEmpty == false ? "declared" : "unspecified"
    authored["edge_artwork"] = try definition.edgeArtwork.map(jsonObject) ?? NSNull()
    authored["derived"] = definition.derived as Any? ?? NSNull()
    let leaves = try pagination.section(Array(resolved.leaves.enumerated())) { index, leaf in
      let original = definition.leaves?.first(where: { $0.id == leaf.id })
      return ["index": index, "leaf_id": leaf.id.uuidString,
        "front": page(leaf.frontPageID, document: document), "back": page(leaf.backPageID, document: document),
        "size_mm": try jsonObject(leaf.size), "stock": try jsonObject(leaf.stock),
        "authored_stock": try original?.stock.map(jsonObject) ?? NSNull(),
        "parent_sheet_id": leaf.parentSheetID?.uuidString as Any? ?? NSNull(),
        "signature_id":leaf.signatureID?.uuidString as Any? ?? NSNull(),
        "auxiliary_id":leaf.auxiliaryID?.uuidString as Any? ?? NSNull(),
        "name":leaf.name as Any? ?? NSNull(),
        "attachment":try leaf.attachment.map(jsonObject) ?? NSNull(),
        "stack_offset_mm": leaf.stackOffsetMM, "turned": leaf.turned,
        "front_render_candidate": leaf.frontVisible, "back_render_candidate": leaf.backVisible,
        "finish_count": leaf.finishes.count]
    }
    let parents = try pagination.section(resolved.parentSheets) { parent in
      ["id": parent.id.uuidString, "front": parent.frontPageIDs.map { page($0, document: document) },
        "back": parent.backPageIDs.map { page($0, document: document) }, "stock": try jsonObject(parent.stock),
        "size_mm": try jsonObject(parent.sizeMM), "print_intent": parent.printIntent.rawValue]
    }
    let enclosure = try pagination.section(resolved.enclosure) { plane in
      let source = definition.enclosure!.first { $0.id == plane.id }!
      return ["id": plane.id, "name": plane.name, "stock": try jsonObject(plane.stock),
        "authored": ["size": try jsonObject(source.size), "positionMM": try jsonObject(source.positionMM),
          "rotationDegrees": try jsonObject(source.rotationDegrees),
          "front": try source.front.map(jsonObject) ?? NSNull(), "back": try source.back.map(jsonObject) ?? NSNull(),
          "features":try source.features.map(jsonObject) ?? NSNull()],
        "resolved": ["size_mm": try jsonObject(plane.size), "position_mm": try jsonObject(plane.positionMM),
          "rotation_degrees": try jsonObject(plane.rotationDegrees),
          "front": try plane.front.map(jsonObject) ?? NSNull(), "back": try plane.back.map(jsonObject) ?? NSNull(),
          "features":try plane.features.map(jsonObject) ?? NSNull()],
        "finish_count": plane.finishes.count]
    }
    return try bounded([
      "schema_version": 1, "project_id": project.id.uuidString, "object_id": object.id.uuidString,
      "publication_id": document.id.uuidString, "name": object.name, "publication_name": document.name,
      "units": ["length": "millimeters", "angle": "degrees", "active_spread": "turned physical leaves"],
      "authored": authored,
      "resolved": ["size_mm": try jsonObject(resolved.size), "stack_thickness_mm": resolved.stackThicknessMM,
        "trim_width_mm":resolved.trimWidth,"trim_height_mm":resolved.trimHeight,
        "text_block_thickness_mm":resolved.textBlockThickness,"binding_allowance_mm":resolved.bindingAllowance,
        "spine_thickness_mm":resolved.spineThickness,"closed_width_mm":resolved.closedWidth,
        "closed_height_mm":resolved.closedHeight,"closed_thickness_mm":resolved.closedThickness,
        "closed_bounds_mm":closedBounds,
        "edge_artwork":try resolved.edgeArtwork.map(jsonObject) ?? NSNull(),
        "binding": try resolved.binding.map(jsonObject) ?? NSNull(), "binding_state": bindingState(definition.binding),
        "logical_page_count": document.pages.count, "leaf_count": resolved.leaves.count,
        "parent_sheet_count": resolved.parentSheets.count, "enclosure_count": resolved.enclosure.count,
        "signature_count":resolved.signatures.count,"auxiliary_leaf_count":definition.auxiliaryLeaves?.count ?? 0],
      "pages": pagination.section(document.pages) { entry in page(entry.id, document: document) as! [String: Any] },
      "leaves": leaves, "parent_sheets": parents, "enclosure": enclosure,
      "signatures":try pagination.section(resolved.signatures){try jsonObject($0) as! [String:Any]},
      "auxiliary_leaves":try pagination.section(definition.auxiliaryLeaves ?? []){try jsonObject($0) as! [String:Any]},
      "source_object_ids":resolved.sourceObjectIDs.map(\.uuidString).sorted(),
      "reader_spreads": pagination.section(Array(0...resolved.leaves.count)) { spread($0, document: document, leaves: resolved.leaves) },
      "selected_reader_spread": spread(resolved.activeSpread, document: document, leaves: resolved.leaves),
      "finish_details": "Canonical source definitions retain finish assignments; inspection reports counts without copying mask artwork.",
      "visibility_semantics": "Render candidates are conservative physical face flags, not camera occlusion or an image-recognition claim.",
      "mechanics": "Idealized viewing geometry; no contact, gravity, adhesive or manufacturing-strength simulation."])
  }
}
