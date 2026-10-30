import Foundation

extension PaperAppearanceCommands {
  static var profileSchema: [String: Any] {
    ["type": ["object", "null"], "additionalProperties": false, "properties": [
      "texture": ["type": "string", "enum": PaperSurfaceProfile.Texture.allCases.map(\.rawValue)],
      "color": ["type": ["string", "null"]],
      "roughness": ["type": "number", "minimum": 0, "maximum": 1],
      "textureScaleMM": ["type": "number", "minimum": 0.05, "maximum": 100],
      "textureDepthMM": ["type": "number", "minimum": 0, "maximum": 0.5],
      "opacity": ["type": "number", "minimum": 0, "maximum": 1]]]
  }
  static var stockSchema: [String: Any] {
    ["type": "object", "additionalProperties": false,
      "description": "Partial PaperStock in millimeters. profile is a visual assumption; null clears it. plies are bonded physical layers in back-to-front order, distinct from front/back printing. A replacement ply array derives thicknessMM from its sum unless explicitly supplied; construction parameters must match atomically. Existing instance color remains an explicit override.",
      "properties": [
        "name": ["type": "string"], "vendor": ["type": ["string", "null"]],
        "gsm": ["type": ["number", "null"], "minimum": 10, "maximum": 5000],
        "thicknessMM": ["type": "number", "minimum": 0.01, "maximum": 20],
        "grain": ["type": "string", "enum": ["parallelHeight", "parallelWidth", "unknown"]],
        "sheetSizeMM": ["type": ["object", "null"], "additionalProperties": false,
          "required": ["x", "y"], "properties": ["x": ["type": "number", "minimum": 50, "maximum": 5000], "y": ["type": "number", "minimum": 50, "maximum": 5000]]],
        "verified": ["type": "boolean"], "notes": ["type": "string"], "profile": profileSchema,
        "plies": ["type": ["array", "null"], "minItems": 1, "maxItems": 16, "items": [
          "type": "object", "additionalProperties": false, "required": ["name", "color", "thicknessMM"],
          "properties": ["id": ["type": "string", "format": "uuid"], "name": ["type": "string"],
            "color": ["type": "string"], "thicknessMM": ["type": "number", "minimum": 0.01, "maximum": 20],
            "gsm": ["type": ["number", "null"], "minimum": 10, "maximum": 5000], "profile": profileSchema]]]]]
  }
  static var finishSchema: [String: Any] {
    ["type": "object", "additionalProperties": false,
      "description": "Canonical editable artwork mask attached to this physical paper owner. New assignments need kind and elementIDs; defaults are outside, zero depth/height, opacity1, enabledtrue. Supply an existing id for a partial update. Array ordering is retained. Inside means the registered back-facing artwork source; it does not create another bonded stock ply. Depth/height remain intent and native surface shading, not tooling geometry.",
      "properties": ["id": ["type": "string", "format": "uuid"], "name": ["type": "string"],
        "kind": ["type": "string", "enum": PaperFinishAssignment.Kind.allCases.map(\.rawValue)],
        "side": ["type": "string", "enum": ["outside", "inside"]],
        "elementIDs": ["type": "array", "minItems": 1, "maxItems": 5000, "uniqueItems": true, "items": ["type": "string", "format": "uuid"]],
        "color": ["type": ["string", "null"]], "depthMM": ["type": "number", "minimum": 0, "maximum": 2],
        "heightMM": ["type": "number", "minimum": 0, "maximum": 2],
        "roughness": ["type": ["number", "null"], "minimum": 0, "maximum": 1],
        "metallic": ["type": ["number", "null"], "minimum": 0, "maximum": 1],
        "opacity": ["type": "number", "minimum": 0, "maximum": 1], "enabled": ["type": "boolean"]]]
  }
}
