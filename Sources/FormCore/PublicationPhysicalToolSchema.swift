import Foundation

/// Tool descriptions of the existing portable model, not a second physical schema.
public enum PublicationPhysicalToolSchema {
  private static let uuid: [String: Any] = ["type": "string", "format": "uuid"]
  private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
    var result: [String: Any] = ["type": "object", "additionalProperties": false, "properties": properties]
    if !required.isEmpty { result["required"] = required }
    return result
  }
  private static func optional(_ schema: [String: Any]) -> [String: Any] {
    var result = schema
    var types = schema["type"] as? [String] ?? [schema["type"] as? String ?? "object"]
    if !types.contains("null") { types.append("null") }
    result["type"] = types
    if var values = schema["enum"] as? [Any], !values.contains(where: { $0 is NSNull }) {
      values.append(NSNull()); result["enum"] = values
    }
    return result
  }
  private static func array(_ item: [String: Any], maximum: Int, nullable: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["type": "array", "items": item, "maxItems": maximum]
    if nullable { result["type"] = ["array", "null"] }
    return result
  }
  private static func number(_ minimum: Double, _ maximum: Double) -> [String: Any] {
    ["type": "number", "minimum": minimum, "maximum": maximum]
  }
  private static var expression: [String: Any] { ["type": ["number", "string"], "maxLength": 4096,
    "description": "Existing CAD scalar: finite number or bounded expression in source parameters and assembly dimensions; physical lengths are millimeters."] }
  private static var point: [String: Any] { object(["x": expression, "y": expression], required: ["x", "y"]) }
  private static var vector: [String: Any] { object(["x": expression, "y": expression, "z": expression], required: ["x", "y", "z"]) }
  private static var profile: [String: Any] {
    var value = PaperAppearanceCommands.profileSchema
    value["required"] = ["texture", "roughness", "textureScaleMM", "textureDepthMM", "opacity"]
    return value
  }
  public static var stock: [String: Any] {
    var value = PaperAppearanceCommands.stockSchema
    var properties = value["properties"] as! [String: Any]
    properties["profile"] = profile
    var plies = properties["plies"] as! [String: Any]
    var ply = plies["items"] as! [String: Any]
    ply["required"] = ["id", "name", "color", "thicknessMM"]
    var plyProperties = ply["properties"] as! [String: Any]
    plyProperties["profile"] = profile
    ply["properties"] = plyProperties; plies["items"] = ply; properties["plies"] = plies
    value["properties"] = properties
    value["required"] = ["name", "thicknessMM", "grain", "verified", "notes"]
    value["description"] = "Complete canonical PaperStock. Physical caliper is derived from bonded plies when present; verified records source evidence, not manufacturing approval."
    return value
  }
  public static var binding: [String: Any] {
    var value = object([
      "style": ["type": "string", "enum": SheetBindingStyle.allCases.map(\.rawValue)],
      "count": ["type": "integer", "minimum": 1, "maximum": 8],
      "positionsMM": optional(array(number(0, 10000), maximum: 8)),
      "endMarginMM": number(0, 5000), "edgeInsetMM": number(0.5, 40),
      "crownLengthMM": number(1, 40), "wireDiameterMM": number(0.1, 2),
      "clinchLengthMM": number(0.5, 10), "flexWidthMM": number(1, 50)])
    let defaults = SheetBindingDefinition()
    let fields: [String: Any] = ["style": defaults.style.rawValue, "count": defaults.count,
      "endMarginMM": defaults.endMarginMM, "edgeInsetMM": defaults.edgeInsetMM,
      "crownLengthMM": defaults.crownLengthMM, "wireDiameterMM": defaults.wireDiameterMM,
      "clinchLengthMM": defaults.clinchLengthMM, "flexWidthMM": defaults.flexWidthMM]
    var properties = value["properties"] as! [String: [String: Any]]
    for (key, fallback) in fields { properties[key]?["default"] = fallback }
    value["properties"] = properties
    value["description"] = "Explicit physical binding. style:none declares unbound; omitted/null binding is unspecified. Positions are crown centers from the head edge. Other dimensions default to the native SheetBindingDefinition values."
    return value
  }
  private static var finishes: [String: Any] {
    var item = PaperAppearanceCommands.finishSchema
    item["required"] = ["id", "name", "kind", "side", "elementIDs", "depthMM", "heightMM", "opacity", "enabled"]
    return array(item, maximum: 128, nullable: true)
  }
  private static var face: [String: Any] {
    object(["sourceObjectID": uuid, "sourceSide": ["type": "string", "enum": ["outside", "inside"]],
      "sourceOriginMM": optional(point)], required: ["sourceObjectID", "sourceSide"])
  }
  public static var assembly: [String: Any] {
    let leaf = object(["id": uuid, "frontPageID": optional(uuid), "backPageID": optional(uuid),
      "stock": optional(stock), "finishes": finishes], required: ["id"])
    var slots = array(optional(uuid), maximum: 2); slots["minItems"] = 2
    let parent = object(["id": uuid, "frontPageIDs": slots, "backPageIDs": slots,
      "stock": stock, "sizeMM": object(["x": number(1, 20000), "y": number(1, 20000)], required: ["x", "y"]),
      "printIntent": ["type": "string", "enum": SheetParentPrintIntent.allCases.map(\.rawValue)]],
      required: ["frontPageIDs", "backPageIDs", "stock", "sizeMM"])
    let plane = object(["id": ["type": "string", "maxLength": 128], "name": ["type": "string", "maxLength": 256],
      "size": point, "positionMM": vector, "rotationDegrees": vector, "stock": stock,
      "front": optional(face), "back": optional(face), "finishes": finishes],
      required: ["id", "name", "size", "positionMM", "rotationDegrees", "stock"])
    var value = object(["version": ["type": "integer", "enum": [1]], "publicationID": uuid, "stock": stock,
      "openingDegrees": number(0, 180), "activeSpread": ["type": "integer", "minimum": 0, "maximum": 200],
      "bendMM": number(0, 20), "leaves": array(leaf, maximum: 200, nullable: true),
      "enclosure": array(plane, maximum: 32, nullable: true), "binding": optional(binding),
      "parentSheets": array(parent, maximum: 51, nullable: true)],
      required: ["version", "publicationID", "stock", "openingDegrees", "activeSpread", "bendMM"])
    value["description"] = "Complete SheetAssemblyDefinition. Leaf and parent face UUIDs are PublicationPage.id (logical IDs), not artwork object IDs. activeSpread counts turned physical leaves. Parent stock and nested front/back ordering are authoritative. Enclosure crops never scale artwork."
    return value
  }
  public static var pose: [String: Any] {
    var value = object(["openingDegrees": number(0, 180),
      "activeSpread": ["type": "integer", "minimum": 0, "maximum": 200], "bendMM": number(0, 20),
      "bindingStyle": ["type": "string", "enum": SheetBindingStyle.allCases.map(\.rawValue)]])
    value["description"] = "Per-instance presentation overrides. Omitted fields inherit the physical source; bindingStyle:none explicitly shows an unbound instance. Does not alter publication artwork, stock or canonical binding."
    return optional(value)
  }
  public static var posePatch: [String: Any] {
    var value = pose; value["type"] = "object"
    let properties = pose["properties"] as! [String: [String: Any]]
    value["properties"] = properties.mapValues(optional)
    value["description"] = "Sparse per-instance pose patch. Omitted fields retain the saved override; null clears that field to inherit the source."
    return value
  }
  /// Keep forward-compatible Codable project loading separate from strict tool input.
  static func validateFields(_ raw: Any, schema: [String: Any], path: String) throws {
    let types = schema["type"] as? [String] ?? (schema["type"] as? String).map { [$0] } ?? []
    if raw is NSNull {
      guard types.contains("null") else { throw FormError.invalid("\(path) cannot be null.") }; return
    }
    if types.contains("object") {
      let declared=schema["properties"] as? [String:Any],additional=schema["additionalProperties"] as? [String:Any]
      guard let object=raw as? [String:Any],declared != nil || additional != nil,
        object.count <= (schema["maxProperties"] as? Int ?? Int.max) else {throw FormError.invalid("Unknown, malformed or excessive \(path) fields.")}
      let properties=declared ?? [:]
      if let names=(schema["propertyNames"] as? [String:Any])?["enum"] as? [String],!Set(object.keys).isSubset(of:Set(names)) {
        throw FormError.invalid("Unknown \(path) dictionary key.")
      }
      guard additional != nil || Set(object.keys).isSubset(of:Set(properties.keys)) else {throw FormError.invalid("Unknown \(path) field.")}
      let required = schema["required"] as? [String] ?? []
      guard Set(required).isSubset(of: Set(object.keys)) else {
        throw FormError.invalid("\(path) is missing required fields: \(Set(required).subtracting(object.keys).sorted().joined(separator: ", ")).")
      }
      for (key, value) in object {
        if let child=(properties[key] as? [String:Any]) ?? additional {try validateFields(value,schema:child,path:path+"."+key)}
      }
    } else if types.contains("array") {
      guard let values = raw as? [Any], values.count <= (schema["maxItems"] as? Int ?? 5000) else { throw FormError.invalid("Invalid or excessive \(path) entries.") }
      if let item = schema["items"] as? [String: Any] {
        for value in values { try validateFields(value, schema: item, path: path + "[]") }
      }
    }
  }
}
