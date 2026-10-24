import Foundation

public enum MCP {
  public static let protocolVersion = "2025-11-25"
  public static let toolNames = Set(tools.compactMap { $0["name"] as? String })
  public static let printToolNames: Set<String> = [
    "form_open_print", "form_get_print_setup", "form_set_print_options", "form_slice",
    "form_get_slice_status", "form_cancel_slice", "form_list_filaments", "form_save_filament",
    "form_list_printers", "form_connect_printer",
  ]
  public static var tools: [[String: Any]] {
    let string: [String: Any] = ["type": "string"]
    let number: [String: Any] = ["type": "number"]
    let position: [String: Any] = [
      "type": "array", "items": number, "minItems": 3, "maxItems": 3,
      "description": "[x, y, z] in millimeters; y is height above the Table.",
    ]
    let objectID: [String: Any] = [
      "type": "string", "description": "Object UUID from form_get_project or form_add_object.",
    ]
    let parameters: [String: Any] = [
      "type": "object", "additionalProperties": number,
      "description":
        "Recipe parameter IDs mapped to numeric values. Discover ranges with form_list_recipes. Dimensions are millimeters unless specified.",
    ]
    func tool(
      _ name: String, _ description: String, _ properties: [String: Any] = [:],
      required: [String] = [], readOnly: Bool = false, destructive: Bool = false
    ) -> [String: Any] {
      [
        "name": name, "description": description,
        "inputSchema": [
          "type": "object", "properties": properties, "required": required,
          "additionalProperties": false,
        ],
        "annotations": [
          "readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false,
        ],
      ]
    }
    return [
      tool(
        "form_status", "Read FORM's current project, selection, version, and library location.",
        readOnly: true),
      tool("form_list_projects", "List saved projects and their project IDs.", readOnly: true),
      tool(
        "form_create_project",
        "Create and open a persistent .form project. Default is a blank Table. No external AI calls are made.",
        [
          "name": string, "template": ["type": "string", "enum": ["blank", "cyanotype"]],
          "conversation_reference": [
            "type": "string",
            "description":
              "Optional Codex conversation URL or identifier to preserve with this project.",
          ],
        ], required: ["name"]),
      tool(
        "form_open_project", "Open a saved project in the running FORM window.",
        ["project_id": string], required: ["project_id"]),
      tool(
        "form_get_project",
        "Read all objects, editable parameters, recipes, artwork, materials, decisions, and history for the current project.",
        readOnly: true),
      tool(
        "form_list_recipes",
        "Discover built-in and project-defined parametric recipes, including their native inspector schemas, ranges, and defaults.",
        readOnly: true),
      tool(
        "form_list_materials", "List the reusable Studio Library and project materials.",
        readOnly: true),
      tool(
        "form_add_object",
        "Create an editable object on the Table. Native inspector controls are generated from its recipe. All dimensions and positions use millimeters.",
        [
          "recipe_id": string, "name": string, "parameters": parameters, "material_id": string,
          "color": string, "position": position,
        ], required: ["recipe_id"]),
      tool(
        "form_update_object",
        "Edit object parameters, material, color, placement, rotation (degrees), name, or locked state. Variant geometry remains linked; iterations are independent.",
        [
          "object_id": objectID, "parameters": parameters, "material_id": string, "color": string,
          "position": position, "rotation": number, "name": string, "locked": ["type": "boolean"],
        ], required: ["object_id"]),
      tool(
        "form_delete_objects", "Remove objects from the current project. Undo is available.",
        ["object_ids": ["type": "array", "items": string, "minItems": 1]], required: ["object_ids"],
        destructive: true),
      tool(
        "form_duplicate_object",
        "Make an independent iteration, a linked material/artwork variant, or a duplicate. The new object is placed beside the original.",
        [
          "object_id": objectID,
          "mode": ["type": "string", "enum": ["iteration", "variant", "duplicate"]], "name": string,
          "material_id": string,
        ], required: ["object_id"]),
      tool(
        "form_group_objects",
        "Group existing objects for joint selection and movement, or ungroup them.",
        [
          "object_ids": ["type": "array", "items": string, "minItems": 2],
          "ungroup": ["type": "boolean"],
        ], required: ["object_ids"]),
      tool(
        "form_create_recipe",
        "Define a new parametric object type in this project. Parameters: id,name,value,minimum,maximum, optional unit/step. Parts: kind (box/cylinder/cone/sphere/torus), values (arithmetic expression strings for width/height/depth/radius/topRadius/bottomRadius/ringRadius/pipeRadius/x/y/z/rotationX/rotationY/rotationZ/corner), optional hex color. Expressions support variables, numbers, + - * / and parentheses. Values are mm, rotations degrees. Parts inherit the object's material. This creates first-class editable controls without executing code.",
        [
          "recipe": [
            "type": "object",
            "properties": [
              "id": string, "name": string, "summary": string, "symbol": string,
              "parameters": ["type": "array", "items": ["type": "object"]],
              "parts": ["type": "array", "items": ["type": "object"]],
            ], "required": ["id", "name", "parameters", "parts"],
          ]
        ], required: ["recipe"]),
      tool(
        "form_set_artwork",
        "Replace linked surface artwork. Artwork: background (#RRGGBB), bleed (mm), elements. Each element needs id (UUID), kind (text/rectangle/ellipse/line/image), x,y,width,height in mm, text,color,fontSize (points), optional asset. Origin is the upper-left of the printable face. The 3D material updates immediately.",
        [
          "object_id": objectID,
          "artwork": [
            "type": "object",
            "properties": [
              "background": string, "bleed": number,
              "elements": ["type": "array", "items": ["type": "object"]],
            ], "required": ["background", "bleed", "elements"],
          ],
        ], required: ["object_id", "artwork"]),
      tool(
        "form_import_reference",
        "Import a local image into the project package and place it on the Table. Assets remain available after reopening.",
        ["path": string, "name": string, "position": position], required: ["path"]),
      tool(
        "form_add_note", "Record a design decision or unresolved question in the project.",
        ["text": string, "kind": ["type": "string", "enum": ["decision", "question"]]],
        required: ["text"]),
      tool(
        "form_set_view",
        "Set a camera preset or focus/isolate an object. Views: perspective, overhead, front, fit, focus, isolate, show_all, home, table, artwork, studio, print_bed, print_object. Optional object_id selects the target.",
        [
          "view": [
            "type": "string",
            "enum": [
              "perspective", "overhead", "front", "fit", "focus", "isolate", "show_all", "home",
              "table", "artwork", "studio", "print_bed", "print_object",
            ],
          ], "object_id": objectID,
        ], required: ["view"]),
      tool(
        "form_export",
        "Export PNG studio render, PDF artwork, SVG dieline, or JSON component/material summary. Files are written to the project's Exports folder by default. Optional path selects an absolute output file.",
        [
          "format": ["type": "string", "enum": ["png", "pdf", "svg", "json"]],
          "object_id": objectID, "path": string,
        ], required: ["format"]),
      tool(
        "form_batch",
        "Apply 1–100 object, artwork, group, recipe, or note edits atomically as one undo step. Each operation has name and arguments. The whole batch rolls back if any edit is invalid.",
        [
          "operations": [
            "type": "array",
            "items": [
              "type": "object", "properties": ["name": string, "arguments": ["type": "object"]],
              "required": ["name", "arguments"],
            ], "minItems": 1, "maxItems": 100,
          ]
        ], required: ["operations"]),
      tool(
        "form_open_print",
        "Open the dedicated native print-preparation window for a selected object or component. Places the real millimeter mesh on the printer bed. Sending and starting prints are disabled.",
        ["object_id": objectID]),
      tool(
        "form_get_print_setup",
        "Read the selected object/component, physical bed fit, printer, filament, slicing settings, engine availability, and live status. No credentials are returned.",
        readOnly: true),
      tool(
        "form_set_print_options",
        "Set native print options. Rotation is {x,y,z} in degrees in printer coordinates (Z up); scalePercent never changes original dimensions. Lamp components: Shade, Stem, Base, Complete object.",
        [
          "layerHeight": number, "infillPercent": number, "wallLoops": ["type": "integer"],
          "supports": ["type": "boolean"], "brimWidth": number, "scalePercent": number,
          "rotation": [
            "type": "object", "properties": ["x": number, "y": number, "z": number],
            "required": ["x", "y", "z"],
          ], "component": string, "filamentID": string, "printerID": string,
        ]),
      tool(
        "form_slice",
        "Start local OrcaSlicer preparation asynchronously. Returns job_id immediately; poll form_get_slice_status. Produces millimeter STL, G-code, sliced 3MF and a native layer preview. Never uploads or starts a print."
      ),
      tool(
        "form_get_slice_status",
        "Read local slicing progress, errors, output folder, layer count, material and time estimates. Does not contact a printer.",
        readOnly: true),
      tool(
        "form_cancel_slice",
        "Cancel the running local slicer process. Does not send printer commands."),
      tool(
        "form_list_filaments",
        "Read Studio filament inventory and profiles, including polymer, color, diameter, density, temperatures, flow, grams remaining and cost.",
        readOnly: true),
      tool(
        "form_save_filament",
        "Create or update a Studio filament. Provide id to update. Fields: name, vendor, polymer (PLA/PETG/ABS/ASA/TPU/PC/PA), color (#RRGGBB), diameter, density, nozzleTemperature, bedTemperature, maxVolumetricSpeed, remainingGrams, costPerKg, notes. Omitted fields use defaults.",
        ["filament": ["type": "object"]], required: ["filament"]),
      tool(
        "form_list_printers",
        "Read configured local printers and receive-only Bambu telemetry. Access codes stay in Keychain and are never returned.",
        readOnly: true),
      tool(
        "form_connect_printer",
        "Connect the selected configured printer for TLS MQTT status monitoring only. IP, serial and access code must first be saved in native Studio settings. No file transfer, motion, heating, calibration, or print-start commands exist."
      ),
      tool("form_undo", "Undo the last native or MCP edit."),
      tool("form_redo", "Redo an undone edit."),
    ]
  }

  /// JSON-RPC framing and discovery are independent of the running GUI.
  public static func respond(to data: Data, invoke: (String, [String: Any]) throws -> Any)
    -> [String: Any]?
  {
    let request: [String: Any]
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return error(NSNull(), -32600, "Invalid Request")
      }
      request = object
    } catch { return self.error(NSNull(), -32700, "Parse error") }
    let id = request["id"] ?? NSNull()
    guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
      return error(id, -32600, "Invalid Request")
    }
    guard request["id"] != nil else { return nil }
    let params = request["params"] as? [String: Any] ?? [:]
    var result: Any
    switch method {
    case "initialize":
      let requested = params["protocolVersion"] as? String ?? protocolVersion
      let version =
        ["2024-11-05", "2025-03-26", "2025-06-18", protocolVersion].contains(requested)
        ? requested : protocolVersion
      result = [
        "protocolVersion": version, "serverInfo": ["name": "form", "version": "0.1.0"],
        "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
        "instructions":
          "FORM is a native physical design studio. Use form_list_recipes and form_get_project before editing. Create custom recipes for new object categories. All physical dimensions are millimeters. Use form_batch for coherent multi-part changes. Native edits and MCP edits share undo history. No external model calls occur in FORM.",
      ]
    case "ping": result = [String: String]()
    case "tools/list": result = ["tools": tools]
    case "tools/call":
      guard let name = params["name"] as? String, toolNames.contains(name) else {
        return error(id, -32602, "Unknown tool")
      }
      if let arguments = params["arguments"], !(arguments is [String: Any]) {
        return error(id, -32602, "arguments must be an object")
      }
      do {
        let value = try invoke(name, params["arguments"] as? [String: Any] ?? [:])
        let text =
          String(
            data: try JSONSerialization.data(
              withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
            encoding: .utf8) ?? "{}"
        result = [
          "content": [["type": "text", "text": text]],
          "structuredContent": value is [String: Any] ? value : ["result": value], "isError": false,
        ]
      } catch {
        result = [
          "content": [["type": "text", "text": error.localizedDescription]], "isError": true,
        ]
      }
    case "resources/list":
      result = [
        "resources": [
          ["uri": "form://project", "name": "Current project", "mimeType": "application/json"],
          [
            "uri": "form://recipes", "name": "Editable object recipes",
            "mimeType": "application/json",
          ],
        ]
      ]
    case "resources/read":
      guard let uri = params["uri"] as? String, ["form://project", "form://recipes"].contains(uri)
      else { return error(id, -32602, "Unknown resource") }
      do {
        let value = try invoke(
          uri == "form://project" ? "form_get_project" : "form_list_recipes", [:])
        let text = String(
          data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          encoding: .utf8)!
        result = ["contents": [["uri": uri, "mimeType": "application/json", "text": text]]]
      } catch { return self.error(id, -32002, error.localizedDescription) }
    case "prompts/list":
      result = [
        "prompts": [
          [
            "name": "design_object",
            "description": "Create a physical object with editable native controls.",
            "arguments": [
              [
                "name": "description",
                "description": "Object, materials, dimensions, and variables to explore.",
                "required": true,
              ]
            ],
          ]
        ]
      ]
    case "prompts/get":
      guard params["name"] as? String == "design_object" else {
        return error(id, -32602, "Unknown prompt")
      }
      let description =
        (params["arguments"] as? [String: String])?["description"] ?? "a physical object"
      result = [
        "messages": [
          [
            "role": "user",
            "content": [
              "type": "text",
              "text":
                "In FORM, design \(description). Inspect available recipes and the current project. Create a project if needed. Reuse or define a parametric recipe with meaningful dimensions and controls. Create editable objects on the Table, choose materials, record assumptions as decisions or questions, and focus the result. Do not make external AI calls.",
            ],
          ]
        ]
      ]
    default: return error(id, -32601, "Method not found")
    }
    return ["jsonrpc": "2.0", "id": id, "result": result]
  }
  private static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
  }
}
