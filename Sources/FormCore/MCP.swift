import Foundation

public enum MCP {
  public static let protocolVersion = "2025-11-25"
  public static let toolNames = Set(tools.compactMap { $0["name"] as? String })
  public static let printToolNames: Set<String> = [
    "form_open_print", "form_get_print_setup", "form_set_print_options", "form_slice",
    "form_get_slice_status", "form_cancel_slice", "form_list_filaments", "form_save_filament",
    "form_list_printers", "form_connect_printer",
  ]
  public static let graphicsToolNames: Set<String> = [
    "form_import_image", "form_image_info",
    "form_list_fonts", "form_font_features", "form_convert_to_paths", "form_boolean_artwork",
    "form_export_artwork", "form_import_svg",
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
          "name": string,
          "template": ["type": "string", "enum": ["blank"] + Samples.templates.map(\.id)],
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
        "Replace linked surface artwork. Artwork: background, bleed (mm), elements, optional unit/guides/gridSpacing/snapEnabled. Elements: id,kind (text/rectangle/ellipse/line/image/polygon/star/path/group), x,y,width,height in mm, text,color,fontSize in pt. Optional name,rotation,opacity,hidden,locked,parentID,stroke,gradient,path,typography,textRuns,productionRole. Typography preserves installed fontName, tracking, leading, alignment, variable axes/features, paragraphs and UTF-16 rich text ranges. The native editor and 3D material use the same definition.",
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
        "form_link_artwork",
        "Link a physical flat surface to an independent artwork sheet. Editing either source or surface updates every consumer. Actual preserves physical typography and centers it; fit scales proportionally to the surface. Omit source_object_id to detach while preserving the rendered artwork. Linked product variants share the link.",
        [
          "object_id": objectID, "source_object_id": string,
          "fit": ["type": "string", "enum": ["actual", "fit"]],
        ], required: ["object_id"]),
      tool(
        "form_extract_artwork",
        "Turn an object's inline surface artwork into an independent editable sheet and link the object and its variants to that document. Returns the new sheet; the physical appearance is preserved.",
        ["object_id": objectID], required: ["object_id"]),
      tool(
        "form_get_artwork",
        "Read editable artwork, hierarchy, typography, paths, guides, and physical units. resolved:true returns a derived ordinary hierarchy with component instances expanded; edit the raw source or instance reference instead of persisting resolved copies.",
        ["object_id": objectID, "resolved": ["type": "boolean"]], required: ["object_id"], readOnly: true),
      tool(
        "form_component",
        "Reusable artwork across project frames and physical faces. list reads source frames/parts. create moves selected sibling artwork into a new editable source frame and places a linked instance. insert places a source in another frame. override sets a global fill color (null clears it) and/or replaces per-part overrides; reset clears overrides; detach bakes ordinary editable artwork. Instances retain independent transforms and sizes. Source edits update linked placements. All mutations are undoable and support atomic batches.",
        [
          "command": ["type": "string", "enum": ["list", "create", "insert", "override", "reset", "detach"]],
          "object_id": objectID, "source_object_id": objectID, "name": string,
          "element_ids": ["type": "array", "items": string],
          "x": number, "y": number, "width": number, "height": number,
          "color": ["type": ["string", "null"]],
          "overrides": ["type": "array", "items": ["type": "object", "properties": [
            "elementID": string, "color": string, "text": string, "opacity": number,
          ], "required": ["elementID"], "additionalProperties": false]],
        ], required: ["command"]),
      tool(
        "form_edit_paint",
        "Edit vector stroke and gradient paint without replacing geometry. command update patches stroke (enabled, width/color/opacity, cap/join/miter, dash lengths and dash_offset in mm, alignment center/inside/outside) and gradient (kind, normalized start/end, optional affine transform). null removes explicit stroke or gradient; lines retain their implicit stroke unless enabled:false. Inside/outside require closed geometry. Single-object add_stop/update_stop/delete_stop use stop_id, offset, color, opacity; add samples current shared colors when color is omitted and accepts an optional new UUID. reverse_stops reverses colors. Stops retain UUIDs across reordering; at least two remain. Native/MCP edits share undo and atomic batches.",
        ["object_id":objectID,"element_ids":["type":"array","items":string],
          "command":["type":"string","enum":PaintCommands.names],
          "stroke":["type":["object","null"],"properties":["enabled":["type":"boolean"],"width":number,"color":string,"opacity":number,"cap":string,"join":string,"miter":number,"dash":["type":["array","null"],"items":number],"dash_offset":number,"alignment":["type":"string","enum":["center","inside","outside"]]],"additionalProperties":false],
          "gradient":["type":["object","null"],"properties":["kind":["type":"string","enum":["linear","radial"]],"start":["type":"object"],"end":["type":"object"],"transform":["type":["object","null"]]],"additionalProperties":false],
          "stop_id":string,"offset":number,"color":string,"opacity":number],required:["object_id","element_ids"]),
      tool(
        "form_import_image",
        "Place a local image into editable artwork, or replace element_id while retaining its frame, transform, masks, opacity, and adjustments. Originals are copied into the project. Placement defaults to an aspect-preserving fit; explicit width/height crops to fill. Replacement refills the same frame around the previous crop center. x/y/width/height are physical mm; anchor defaults to top-left and also accepts center. PDF/SVG references retain vector appearance; raster formats support adjustments. File import is outside atomic batches.",
        ["object_id": objectID, "path": string, "element_id": string, "parent_id": string,
          "x": number, "y": number, "width": number, "height": number, "name": string,
          "anchor":["type":"string","enum":["top-left","center"]]], required: ["object_id", "path"]),
      tool(
        "form_edit_image",
        "Patch non-destructive image crop and color adjustments on unlocked image layers. Crop x/y/width/height are normalized 0–1 top-left original-image coordinates, at least .01 wide/high. Adjustments: brightness −1–1, contrast 0–4, saturation 0–2. null clears a setting; command reset clears crop and adjustments. Originals, frame geometry, transforms and masks stay intact. Shared undo and atomic batches.",
        ["object_id": objectID, "element_ids": ["type":"array","items":string],
          "command": ["type":"string","enum":["update","reset"]],
          "crop": ["type":["object","null"],"properties":["x":number,"y":number,"width":number,"height":number],"additionalProperties":false],
          "adjustments": ["type":["object","null"],"properties":["brightness":number,"contrast":number,"saturation":number],"additionalProperties":false]], required:["object_id","element_ids"]),
      tool(
        "form_image_info",
        "Inspect original oriented pixel dimensions, format/frame count, crop and conservative effective DPI at the resolved physical output size. DPI includes ancestors, shear, crop, component placement and surface fitting. Reports below-300/150-DPI flags. Vector PDF/SVG references have no fixed raster DPI. Does not change native editing focus.",
        ["object_id":objectID,"element_ids":["type":"array","items":string]],required:["object_id"],readOnly:true),
      tool(
        "form_appearance",
        "Edit non-destructive layer appearance on selected roots, including groups and linked components. update patches opacity (0–1), blend_mode, group isolate, blur (enabled/radius in mm), and shadow (enabled, x/y offset in mm, blur in mm, color, opacity). null removes blur or shadow. reset restores normal blending, full opacity, and no effects. Disabled effects retain settings. Clipping is applied after effects. Native and MCP edits share undo, validation, and atomic batches.",
        [
          "command": ["type": "string", "enum": ["update", "reset"]],
          "object_id": objectID, "element_ids": ["type": "array", "items": string],
          "values": ["type": "object", "properties": [
            "opacity": number, "blend_mode": ["type": "string", "enum": AppearanceCommands.blendModes], "isolate": ["type": "boolean"],
            "blur": ["type": ["object", "null"], "properties": ["enabled": ["type": "boolean"], "radius": number], "additionalProperties": false],
            "shadow": ["type": ["object", "null"], "properties": ["enabled": ["type": "boolean"], "x": number, "y": number, "blur": number, "color": string, "opacity": number], "additionalProperties": false],
          ], "additionalProperties": false],
        ], required: ["object_id", "element_ids"]),
      tool(
        "form_swatch",
        "Manage the project's named sRGB palette. list reads swatches; create/update changes a named color. assign binds artwork fill, stroke, shadow, gradient_stop, background, component_part, or a UTF-16 text_range. Changes update every reference across source documents and physical faces. detach freezes that reference's current appearance; delete freezes all references before removing the color. Instance fill binding is a component override. All mutations share native undo and atomic batches; stored consumer resources are unchanged by palette color updates.",
        [
          "command": ["type": "string", "enum": ["list", "create", "update", "assign", "detach", "delete"]],
          "swatch_id": string, "name": string, "color": string, "object_id": objectID,
          "element_ids": ["type": "array", "items": string],
          "target": ["type": "string", "enum": ["fill", "stroke", "shadow", "gradient_stop", "background", "component_part", "text_range"]],
          "stop_id": string, "part_id": string, "location": ["type": "integer"], "length": ["type": "integer"],
        ], required: ["command"]),
      tool(
        "form_edit_artwork",
        "Apply a native artwork command: add/replace elements, delete, duplicate, group, ungroup, align, distribute, reorder, flip, clip, release_clip. Use complete element values for add/replace. clip uses mask_id or the bottom selected area shape; targets and mask must be siblings. Geometry stays editable; use nested clipped groups for nested masks. release_clip preserves the mask shape. Alignment modes: left/right/top/bottom/center_x/center_y/width/height; distribution: horizontal/vertical; order: front/back/forward/backward. Returns selected element IDs. All changes share native undo.",
        [
          "object_id": objectID, "mask_id": string, "command": ["type": "string", "enum": ArtworkCommands.names],
          "element_ids": ["type": "array", "items": string],
          "elements": ["type": "array", "items": ["type": "object"]], "mode": string,
          "axis": string,
        ], required: ["object_id", "command"]),
      tool(
        "form_edit_path",
        "Edit one path with element_id, or multiple paths with element_ids. Operations: insert, delete, split, join two open endpoints (including separate sibling paths), reverse, open, close, corner, smooth, symmetric, transform, combine into an even-odd compound, or release compound contours. Combine/join uses the frontmost path's appearance and retains its ID; combine requires a shared parent and clipping mask. Transform matrices use physical artwork coordinates, including parent transforms. Node IDs come from form_get_artwork. Returns selected element/node IDs; all changes are atomic and undoable.",
        [
          "object_id": objectID, "element_id": string,
          "element_ids": ["type": "array", "items": string],
          "operation": ["type": "string", "enum": PathCommands.names],
          "node_ids": ["type": "array", "items": string], "t": number,
          "matrix": [
            "type": "object",
            "properties": [
              "a": number, "b": number, "c": number, "d": number, "tx": number, "ty": number,
            ], "additionalProperties": false,
          ],
        ], required: ["object_id", "operation"]),
      tool(
        "form_list_fonts",
        "Search installed Mac font families and their actual faces. No font upload is required.",
        ["query": string], readOnly: true),
      tool(
        "form_font_features",
        "Inspect the selected installed face's actual OpenType feature selectors and variable-font axes/ranges. Missing fonts are reported explicitly.",
        ["font_name": string], required: ["font_name"], readOnly: true),
      tool(
        "form_convert_to_paths",
        "Convert selected shaped text, geometric shapes, or strokes to editable Bézier paths. Text uses Core Text glyph runs, ligatures, kerning, and variations. Shape conversion preserves geometry, transforms, and appearance. Original source elements are retained hidden for recovery.",
        [
          "object_id": objectID, "element_ids": ["type": "array", "items": string],
          "mode": ["type": "string", "enum": ["text", "stroke", "shape"]],
        ], required: ["object_id", "element_ids"]),
      tool(
        "form_boolean_artwork",
        "Combine compatible vectors with union/subtract/intersect/exclude. Default mode live retains editable operands in a live group; mode path produces a flat path with hidden sources. On a selected live group, update changes its operation, flatten produces ordinary paths and retains the group hidden, and release restores operands. Mode divide partitions 2–16 operands into separate editable regions using each region's frontmost paint. Subtract uses the bottom operand as its base. Locked or incompatible input rejects atomically.",
        [
          "object_id": objectID, "element_ids": ["type": "array", "items": string],
          "operation": [
            "type": "string", "enum": ["union", "subtract", "intersect", "exclude", "divide"],
          ],
          "mode": [
            "type": "string", "enum": ["live", "path", "update", "flatten", "release", "divide"],
          ],
        ], required: ["object_id", "element_ids"]),
      tool(
        "form_export_artwork",
        "Export the selected artboard/product face as actual-size SVG/PDF or PNG/JPEG at a chosen DPI. Optional element_ids exports a selection. SVG text can be converted to portable outlines.",
        [
          "object_id": objectID,
          "format": ["type": "string", "enum": ["svg", "pdf", "png", "jpeg"]], "path": string,
          "dpi": number, "outline_text": ["type": "boolean"],
          "element_ids": ["type": "array", "items": string],
        ], required: ["object_id", "format"]),
      tool(
        "form_import_svg",
        "Import a local SVG as editable native artwork, preserving physical dimensions, groups, text, paths, and the original SVG asset. Omit object_id to create a new frame, or provide a target to add at original size, centered in its canonical artwork source. dry_run returns dimensions and fidelity issues without changing the project or writing assets. Warnings require allow_unsupported=true after inspection. External resources and scripts are never loaded.",
        [
          "path": string, "object_id": objectID, "name": string, "dry_run": ["type": "boolean"],
          "allow_unsupported": ["type": "boolean"],
        ], required: ["path"]),
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
        "Set a camera preset or focus/isolate an object. Views: perspective, overhead, front, fit, focus, isolate, show_all, home, table, artwork, studio, print_bed, print_object. Optional object_id selects the target. In artwork, element_ids selects layers and optional node_ids activates direct selection on a path.",
        [
          "view": [
            "type": "string",
            "enum": [
              "perspective", "overhead", "front", "fit", "focus", "isolate", "show_all", "home",
              "table", "artwork", "studio", "print_bed", "print_object",
            ],
          ], "object_id": objectID, "element_ids": ["type": "array", "items": string],
          "node_ids": ["type": "array", "items": string],
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
