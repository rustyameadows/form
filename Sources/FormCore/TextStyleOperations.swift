import Foundation

extension OperationEngine {
  func textStyleCall(_ a: [String: Any], source: String) throws -> Any {
    guard let command = a["command"] as? String, let current = project else {
      throw FormError.invalid("Open a project and provide a text style command.")
    }
    if command == "list" { return ["styles": try jsonObject(current.textStyles ?? [])] }
    for key in ["location", "length"] where a[key] != nil {
      guard a[key] is Int else { throw FormError.invalid("Provide integer UTF-16 range values.") }
    }
    if let value = a["font_size"], !(value is Double) { throw FormError.invalid("Use a numeric font_size in points.") }
    if let value = a["name"], !(value is String) { throw FormError.invalid("Use a text style name.") }
    func uuid(_ key: String) throws -> UUID {
      guard let raw = a[key] as? String, let value = UUID(uuidString: raw) else {
        throw FormError.invalid("Provide a valid \(key).")
      }
      return value
    }
    func ids() throws -> Set<UUID> {
      guard let raw = a["element_ids"] as? [String], !raw.isEmpty else { throw FormError.invalid("Choose text element IDs.") }
      let values = Set(raw.compactMap(UUID.init(uuidString:)))
      guard values.count == raw.count else { throw FormError.invalid("Use unique valid text element IDs.") }
      return values
    }
    let coalescing = source == "Studio" && command == "update" ? "text-style-\(a["style_id"] ?? "")" : nil
    var result: [String: Any] = [:]
    try edit("Text style: \(command)", source: source, coalescing: coalescing) { p in
      switch command {
      case "create", "update":
        let id = command == "update" ? try uuid("style_id") : nil
        let old = p.textStyles?.first { $0.id == id }
        if command == "update", old == nil { throw FormError.missing("Text style not found.") }
        var type = old?.typography ?? Typography()
        if let raw = a["typography"] {
          guard let changes = raw as? [String: Any], Set(changes.keys).isSubset(of: TextStyleCommands.propertyNames.subtracting(["fontSize"])) else {
            throw FormError.invalid("Provide supported character/paragraph style properties.")
          }
          var value = try jsonObject(type) as! [String: Any]
          for (key, field) in changes { value[key] = field is NSNull ? nil : field }
          type = try JSONDecoder.form.decode(Typography.self, from: JSONSerialization.data(withJSONObject: value))
          if changes["opticalSizing"] is NSNull {type.setOpticalSizing(nil)}
        }
        let saved = try TextStyleCommands.save(in: &p, id: id,
          name: a["name"] as? String ?? old?.name ?? "Untitled style", typography: type,
          fontSize: a["font_size"] as? Double ?? old?.fontSize ?? 14)
        if command == "create", a["object_id"] != nil {
          try TextStyleCommands.apply(in: &p, objectID: uuid("object_id"), ids: ids(),
            styleID: saved, location: a["location"] as? Int, length: a["length"] as? Int)
        }
        if command == "update", a["reset_selection"] as? Bool == true {
          try TextStyleCommands.apply(in: &p, objectID: uuid("object_id"), ids: ids(),
            styleID: saved, mode: "reset", location: a["location"] as? Int, length: a["length"] as? Int)
        }
        result = ["style": try jsonObject(p.textStyles!.first { $0.id == saved }!)]
      case "assign", "reset", "detach":
        let selected = try ids()
        try TextStyleCommands.apply(in: &p, objectID: uuid("object_id"), ids: selected,
          styleID: command == "assign" || (command == "reset" && a["style_id"] != nil) ? try uuid("style_id") : nil, mode: command,
          location: a["location"] as? Int, length: a["length"] as? Int)
        result = ["selected_elements": selected.map(\.uuidString)]
      case "delete":
        try TextStyleCommands.delete(in: &p, id: uuid("style_id"))
        result = ["deleted": true]
      default: throw FormError.invalid("Unknown text style command.")
      }
    }
    return result
  }
}
