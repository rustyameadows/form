import CoreFoundation
import Foundation

extension OperationEngine {
  public func objectLibraryCall(_ args: [String: Any], source: String = "Studio") throws -> Any {
    let command = args["command"] as? String ?? "list"
    switch command {
    case "list":
      let query = args["query"] as? String ?? ""
      let references = ObjectLibrary.search(query, domain: args["domain"] as? String,
        readyOnly: args["ready_only"] as? Bool ?? false)
      func integer(_ key: String, _ fallback: Int, maximum: Int) throws -> Int {
        guard let raw = args[key] else { return fallback }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
          n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
          (0...Double(maximum)).contains(n.doubleValue) else { throw FormError.invalid("Use a bounded nonnegative integer for \(key).") }
        return n.intValue
      }
      let offset = try integer("offset", 0, maximum: 10000), limit = try integer("limit", 40, maximum: 211)
      let page = references.dropFirst(offset).prefix(limit)
      return ["source": ObjectLibrary.catalog.sourceName, "reference_date": ObjectLibrary.catalog.sourceDate,
        "total": references.count, "offset": offset,
        "items": page.map { r in
          ["id": r.id, "name": r.name, "domain": r.domain, "category": r.category,
           "construction": r.construction, "reference_name": r.referenceName,
           "starters": ObjectLibrary.starters.filter { $0.referenceID == r.id }.map { ["entry_id": $0.id, "name": $0.name, "recipe_id": $0.recipeID] }] as [String: Any]
        }] as [String: Any]
    case "get":
      if let id = args["entry_id"] as? String, let e = ObjectLibrary.entry(id) {
        return ["starter": try jsonObject(e), "reference": try jsonObject(ObjectLibrary.reference(e.referenceID)!),
          "units": "mm", "commercial_status": "No live availability, pricing, provider variants or ordering connection."] as [String: Any]
      }
      if let id = args["reference_id"] as? String, let r = ObjectLibrary.reference(id) {
        return ["reference": try jsonObject(r), "starters": try jsonObject(ObjectLibrary.starters.filter { $0.referenceID == id }),
          "material_options": try jsonObject(ObjectLibrary.catalog.materialOptions.filter { $0.domain == r.domain })]
      }
      throw FormError.missing("Provide a valid entry_id or reference_id.")
    case "examples": return try jsonObject(ObjectLibrary.catalog.workExamples)
    case "add":
      guard let id = args["entry_id"] as? String else { throw FormError.invalid("entry_id is required.") }
      var position = Vector3()
      if let raw = args["position"] {
        guard let v = raw as? [Double], v.count == 3, v.allSatisfy({ $0.isFinite && abs($0) <= 100000 }) else {
          throw FormError.invalid("Position must contain three finite millimeter values within ±100000.")
        }
        position = .init(v[0], v[1], v[2])
      }
      var created: ProductObject?
      try edit("Added library starter", source: source) { created = try $0.addLibraryObject(id, position: position) }
      selection = [created!.id]
      return try jsonObject(created!)
    case "replace", "state":
      guard let raw = args["object_id"] as? String, let id = UUID(uuidString: raw) else { throw FormError.invalid("object_id is required.") }
      try edit(command == "replace" ? "Changed proposed blank" : "Changed blank selection", source: source) { p in
        if command == "replace" {
          guard let entry = args["entry_id"] as? String else { throw FormError.invalid("entry_id is required.") }
          try p.replaceLibraryObject(id, with: entry)
        } else {
          guard let raw = args["state"] as? String, let state = ObjectLibrarySelection.State(rawValue: raw) else {
            throw FormError.invalid("Use concept, proposedBlank or chosenBlank. Production readiness is checked separately.")
          }
          try p.setLibraryState(id, state)
        }
      }
      return try jsonObject(project!.objects.first { $0.id == id }!)
    default: throw FormError.invalid("Library command must be list, get, examples, add, replace or state.")
    }
  }
}
