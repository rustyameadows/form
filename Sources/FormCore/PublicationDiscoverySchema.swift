import Foundation

/// Discovery metadata for the actual publication Codable contracts. Defaults
/// below come from init(from:), not just the convenience initializers.
enum PublicationDiscoverySchema {
  static let master: [String: Any] = [
    "type": "object", "required": ["sourceObjectID"],
    "description": "Live independent editable artboard outside the page sequence, without linked story frames. Text supports {{page.number}}, {{page.label}}, {{page.total}}, {{publication.name}} and {{chapter.title}}. Omitted or null optional fields use the documented decoding defaults.",
    "properties": [
      "id": ["type": ["string", "null"], "format": "uuid", "description": "Stable master identity; omission or null generates a UUID. Preserve it when editing an existing master."],
      "name": ["type": ["string", "null"], "minLength": 1, "maxLength": 160, "default": "Master"],
      "sourceObjectID": ["type": "string", "format": "uuid", "description": "Source artboard object UUID, not a logical publication-page UUID."],
      "x": ["type": ["number", "null"], "minimum": -100_000, "maximum": 100_000, "default": 0, "description": "Horizontal placement in millimeters; no automatic fitting."],
      "y": ["type": ["number", "null"], "minimum": -100_000, "maximum": 100_000, "default": 0, "description": "Vertical placement in millimeters; no automatic fitting."],
      "side": ["type": ["string", "null"], "enum": ["all", "recto", "verso", NSNull()] as [Any], "default": "all"],
      "behind": ["type": ["boolean", "null"], "default": false, "description": "Draw behind page artwork instead of above it."]
    ]
  ]
  static let layout: [String: Any] = [
    "type": ["object", "null"], "description": "Complete replacement; null clears layout. An empty object enables facing pages with recto first. Omission of the top-level field preserves existing settings.",
    "properties": [
      "facingPages": ["type": ["boolean", "null"], "default": true],
      "firstPageSide": ["type": ["string", "null"], "enum": ["recto", "verso", NSNull()] as [Any], "default": "recto"],
      "innerMargin": ["type": ["number", "null"], "minimum": 0, "maximum": 1000, "description": "Millimeters. Omitted or null inherits the page-side publication margin."],
      "outerMargin": ["type": ["number", "null"], "minimum": 0, "maximum": 1000, "description": "Millimeters. Omitted or null inherits the page-side publication margin."]
    ]
  ]
  static let numbering: [String: Any] = [
    "type": ["object", "null"], "description": "Complete replacement; null clears authored numbering. Omitted or null nested fields use decoding defaults.",
    "properties": [
      "start": ["type": ["integer", "null"], "minimum": 1, "maximum": 999_999, "default": 1],
      "style": ["type": ["string", "null"], "enum": ["arabic", "lowerRoman", "upperRoman", "lowerAlpha", "upperAlpha", NSNull()] as [Any], "default": "arabic"],
      "prefix": ["type": ["string", "null"], "maxLength": 100, "default": ""],
      "suffix": ["type": ["string", "null"], "maxLength": 100, "default": ""]
    ]
  ]
  static let margins: [String: Any] = [
    "type": ["object", "null"], "required": ["top", "right", "bottom", "left"],
    "description": "Complete millimeter margins. All four fields are required when supplied. Creation without margins uses 14 mm on each side; page_settings null restores inherited publication margins.",
    "properties": Dictionary(uniqueKeysWithValues: ["top", "right", "bottom", "left"].map {
      ($0, ["type": "number", "minimum": 0, "maximum": 1000, "description": "Millimeters."] as [String: Any])
    })
  ]
  static let baselineGrid: [String: Any] = [
    "type": ["object", "null"], "required": ["spacing", "origin"],
    "description": "Complete grid in typographic points (1/72 inch). Both fields are required; null disables the grid.",
    "properties": [
      "spacing": ["type": "number", "minimum": 4, "maximum": 200, "description": "Baseline spacing in points."],
      "origin": ["type": "number", "minimum": -10_000, "maximum": 10_000, "description": "Page-relative baseline origin in points."]
    ]
  ]
}
