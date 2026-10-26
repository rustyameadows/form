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
    "form_list_fonts", "form_font_features", "form_replace_font", "form_convert_to_paths", "form_boolean_artwork",
    "form_export_artwork", "form_import_svg",
    "form_export_publication", "form_textile_stock", "form_production_job", "form_color_profile", "form_cloth",
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
    let tileOptions: [String: Any] = [
      "type":"object","additionalProperties":false,"required":["sheetSize","margins","overlap"],
      "properties":[
        "sheetSize":["type":"object","additionalProperties":false,"required":["x","y"],"properties":["x":["type":"number","minimum":100,"maximum":1000],"y":["type":"number","minimum":100,"maximum":1000]]],
        "margins":["type":"object","additionalProperties":false,"required":["top","right","bottom","left"],"properties":Dictionary(uniqueKeysWithValues:["top","right","bottom","left"].map{($0,["type":"number","minimum":0,"maximum":50] as [String:Any])})],
        "overlap":["type":"number","minimum":0,"maximum":40]
      ],
      "description":"Physical millimeters: sheetSize{x,y}, margins{top,right,bottom,left}, overlap. A4=210×297; Letter=215.9×279.4; swap dimensions for landscape. Defaults10mm margins/overlap;12mm reserved footer. At least100×140mm usable design area. No automatic printer-margin assumption or scaling."
    ]
    let textile: [String: Any] = [
      "type": ["object", "null"], "required": ["kind", "process"],
      "properties": [
        "kind": ["type": "string", "enum": TextileProduct.Kind.allCases.map(\.rawValue)],
        "process": ["type": "string", "enum": TextileProduct.Process.allCases.map(\.rawValue)],
        "blankName": string, "size": string, "manufacturer": string, "sku": string,
        "measurementsVerified": ["type": "boolean"], "liningMaterialID": string, "trimMaterialID": string,
        "border": string, "backing": string, "attachmentMethod": string, "notes": string,
        "threadColors": ["type": "array", "items": string, "maxItems": 64],
        "laidFaceDown": ["type": "boolean"],
        "attachment": ["type": ["object", "null"], "required": ["garmentID", "zone"], "properties": [
          "garmentID": objectID, "zone": ["type": "string", "enum": TextileAttachment.Zone.allCases.map(\.rawValue)],
          "offset": ["type": "object", "properties": ["x": number, "y": number], "required": ["x", "y"]],
          "rotation": number, "clearance": ["type": "number", "minimum": 0, "maximum": 50],
        ]],
      ],
      "description": "Complete textile product specification or null to clear. Garments are generic presentation blanks. Optional embroidery stores regenerable digitizing settings; machine programs export separately. Attachments reference a supported garment and physical region; offsets are centered region-local millimeters. Discover bounds with form_textile_zones for crewTee/curvedCap/canvasTote. Direct artwork uses textilePrint/directPrint and clearance 0–0.25 mm; cap rigid patch/label/embroidery placements reject. laidFaceDown explicitly turns over tee/tote with every attachment; caps remain upright.",
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
      tool("form_cloth", "Configure and inspect real bounded cloth studies. Initial mesh, masses, material UVs, pins, seams, static colliders and solver settings are saved/undoable. Runtime Run/Stop/Step/Reset and snapshots share the native controller, never commit text drafts, append project history or persist motion. Contacts: static plane, swept vertex/sphere and discrete triangle/sphere; no self-collision/calibrated fit. Cloth remains an open surface and cannot be sliced as a solid. Add clothPanel or clothTote with form_add_object for prepared templates; pouchAssembly is an original curved-pattern project template. assemble creates source-linked sewn panels with explicit rigid poses, source-edge seam fractions and material-coordinate attachments. Pattern assemblies first perform bounded gravity-free preparation: physical seconds/frames stay 0 until every structural length is within 5% and P95 absolute error within 1%; source pose remains visible until ready. Step advances a preparation batch before physical frames; inspect diagnostics.preparation and reset after failure. Initial/worst joining strain and unready candidate positions remain separately inspectable. No generated mesh is an editable document source. Attach a separate object at physical material coordinates; detach before deleting its surface.", [
        "command":["type":"string","enum":["get","configure","remove","run","stop","step","reset","snapshot","attach","detach","assemble"]],"object_id":objectID,
        "definition":["type":"object","description":"Complete ClothStudy {mesh:{restPositionsMm,massesKg,triangles,uv,links,pins,panelIDs?,initialVelocitiesMPerSecond?},settings,colliders,preparation?}. Discover canonical definitions via get on a cloth template. Millimeter geometry, kg masses, seconds; no runtime frames saved."],
        "assembly":["type":"object","description":"Original PatternAssemblyDefinition: sourceObjectID, panels:[{panel:{elementID,copy},pose:{originMm,uAxis,vAxis,materialFront},material:portable Material snapshot,densityGSM,textureOriginMm}], seamIDs, pins:[{panel,edgeID,endID,fraction,targetMm?}], maximumEdgeMm, boundaryToleranceMm, maximumVertices, maximumMeshingOperations, settings, colliders. assemble uses object_id as source owner and creates a separate derived surface as one Undo. Omit assembly to arrange all declared pieces without guessing seams. configure edits an existing assembly; no derived mesh persists. get returns declarations/panels and explicit invalid-source issues."],
        "element_ids":["type":"array","items":string,"description":"Optional annotated source piece UUIDs for a neutral assemble arrangement; all declared copies are included up to8 total. No seams are inferred."],"name":string,"material_x_mm":number,"material_y_mm":number,
        "settings":["type":"object","description":"Partial declared ClothSettings fields; get discovers names/current values. Exclusive with definition. Invalid/nonfinite/budget-exceeding settings reject atomically."],
        "frames":["type":"integer","minimum":1,"maximum":120,"description":"Fixed frames for paused Step, additionally bounded by two million evaluations per request."],
        "path":["type":"string","description":"Optional local .json path for an actual open-surface snapshot with coordinates/UVs/normals/triangles/diagnostics and SHA256. Without path, snapshot returns the mesh."],
        "surface_object_id":objectID,"u":number,"v":number,"panel":["type":"integer","minimum":0,"maximum":63],"offset_mm":number,"rotation":number
      ],required:["command","object_id"]),
      tool("form_textile_stock", "Studio thread inventory and embroidery equipment declarations. Stock edits never rewrite assigned project snapshots or deduct inventory. assign_thread copies a complete portable stock record into one configured, unlocked decoration thread, as one undoable edit. Profiles check declared hoop/format only and never connect to machines.", [
        "command":["type":"string","enum":["list","save_thread","remove_thread","save_equipment","remove_equipment","assign_thread"]],
        "thread":["type":"object","description":"id optional UUID; required name/color; optional brand,sku,supplier,fiber,location,availableMeters,spoolMeters,spoolPrice,currency,notes. Unknown numeric values may be omitted. Known prices need a three-letter currency; spool length is required to derive cost per meter."],
        "equipment":["type":"object","description":"id optional UUID; required name; optional manufacturer/model, hoops:[{name,width,height}] mm, formats:[lowercase extension], needleCount, declarationsVerified, notes. Empty hoops/formats mean unknown; no network credentials exist."],
        "stock_id":objectID,"equipment_id":objectID,"object_id":objectID,"thread_index":["type":"integer","minimum":0,"maximum":31]
      ],required:["command"]),
      tool("form_production_job", "Use kind:decoration for native HTV/DTF preparation preflight/create/list/get/remove/export with immutable original source, physical files and explicit mirror/background/white/material decisions. No tool sends to machines. Omit kind (or use embroidery) to capture and review immutable local embroidery production revisions, explicit BOM/consumption/cost assumptions, and user-recorded sample/quality/status notes. Source/stock/equipment snapshots and actual needle programs are SHA-addressed inside the project. Unknowns stay unknown; stock is never reserved/deducted and no machine is contacted. Export uses archived commands, even after source changes or deletion, and produces a review PDF with actual-size hoop page, chosen physical outputs, JSON specs and file digests in a local ZIP/folder.", [
        "command":["type":"string","enum":["list","create","get","event","export","preflight","remove"]],
        "kind":["type":"string","enum":["embroidery","decoration"],"description":"Embroidery is the unchanged default. Decoration uses preflight/create/list/get/remove/export; event remains embroidery-only."],
        "preparation":["type":"object","description":"Decoration options: process:htv|dtf required; mirror (default HTV true, DTF false), includeBackground false, weedMargin 0–50 mm (HTV only), dpi 72–600 (default 300), whitePolicy:printOpaqueWhite|showThrough, colorDelivery:sRGBRaster|profiledProcess, convertSpotAlternates false, includeUnderbaseReference (DTF true), layerMaterials:[{paintKey,name,supplier?,sku?,notes?}], materialNotes?,equipmentNotes?. Current physical dimensions and actual target zone are used without auto scaling. Flat opaque vectors/shared text/masks only; unsupported paints and fractional HTV spot tints reject."],
        "include_source":["type":"boolean","description":"Decoration get may include its archived source records up to 1 MB; larger snapshots remain in the exported packet."],"notes":string,
        "object_id":objectID,"job_id":objectID,"equipment_id":objectID,"supersedes_job_id":objectID,"name":string,
        "quantity":["type":"integer","minimum":1,"maximum":100000],
        "outputs":["type":"array","items":["type":"string","enum":["dst","svg","json"]],"minItems":1,"maxItems":3,"uniqueItems":true],
        "assumptions":["type":"object","description":"Optional upperThreadFactor,allowanceMetersPerThreadPerItem (both required for consumption estimate), baseUnitCost/baseCurrency, laborMinutesPerItem/hourlyLaborRate/laborCurrency, notes, extraBOM:[{id?,name,quantityPerItem,unit,unitCost?,currency?,supplier?,sku?}]. Needle length is measured; usage/cost remain explicit estimates. No FX conversion or automatic zero prices."],
        "record":["type":"object","description":"User record: kind note/sample/quality/status, notes, optional recordedBy/outcome(pass/needsChanges/fail)/reportedMeters/sourceDigest. Status records require status planned/sampling/approved/held/completed. IDs/date default locally. Approval/completion is user-reported and does not automatically verify a sew-out."],
        "format":["type":"string","enum":["zip","folder"]],"path":string
      ],required:["command"]),
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
      tool("form_textile_zones","Read exact bounded decoration regions of a crewTee, curvedCap or canvasTote. Returns physical centered zone dimensions, surface mapping and allowed processes. Curved cap art uses arc-length millimeters below the dome and clear of the back opening; it rejects rigid patches/labels/embroidery. This does not fit or mutate decorations.",["object_id":objectID],required:["object_id"],readOnly:true),
      tool(
        "form_list_recipes",
        "Discover built-in and project-defined parametric recipes, including their native inspector schemas, ranges, and defaults.",
        readOnly: true),
      tool(
        "form_list_materials", "List the reusable Studio Library and project materials.",
        readOnly: true),
      tool(
        "form_add_object",
        "Create an editable object on the Table. Native inspector controls are generated from its recipe. All dimensions and positions use millimeters. With recipe_id artboard and canvas_workspace true, return or create the project's shared unframed Canvas workspace; physical object options do not apply to that container.",
        [
          "recipe_id": string, "name": string, "parameters": parameters, "material_id": string,
          "color": string, "position": position,
          "canvas_workspace":["type":"boolean","description":"With recipe_id artboard, true returns/creates the single unframed editing workspace. It has no physical Table/print face and cannot directly drive a product surface."],
          "textile": textile,
        ], required: ["recipe_id"]),
      tool(
        "form_update_object",
        "Edit object parameters, material, color, placement, rotation (degrees), name, or locked state. fabric_pattern updates this project's shared fabric material design using an editable independent artwork frame as source; null removes it. Variant geometry remains linked; iterations are independent.",
        [
          "object_id": objectID, "parameters": parameters, "material_id": string, "color": string,
          "position": position, "rotation": number, "name": string, "locked": ["type": "boolean"],
          "textile": textile,
          "embroidery": ["type":["object","null"], "description":"Regenerable embroidery design: hoopWidth/hoopHeight mm (20–500), margin mm, trimJumpThreshold mm, maximumStitches <=100000, threads [{name,color,brand?,catalog?}], regions [{id?,elementIDs:[UUID],method:running|satin|fill,threadIndex,stitchLength mm,spacing mm,satinWidth mm,angle degrees,underlay?:{method:centerWalk|sparseFill,stitchLength,spacing,inset}}], optional process:{threadDiameter,tieIn,tieOff,tieLength,tieRepeats}. Center-walk requires satin; sparse fill requires fill and spacing >=1.5x top spacing. These opt-in process fields use schema28. Export/preflight regenerates actual needle commands from editable source. No machine is contacted."],
          "fabric_pattern": ["type":["object","null"], "description":"Project-scoped fabric repeat: sourceObjectID (frame UUID), repeatMode (straight/halfDrop/brick/mirror), scale, spacing {x,y} mm, offset {x,y} mm, rotation degrees, outputWidth/outputLength mm, includeTileBackground, colorways [{id,name,baseColor,replacements:{sourceHex:targetHex}}], activeColorwayID. Omitted values use physical defaults."],
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
      tool("form_story",
        "Manage one global rich text story flowing through ordered physical text frames. list/get/layout are read-only. create merges source words and formatting from the listed independent text frames; empty frames add capacity. append adds capacity and explicitly appends any target words. edit accepts a complete source ArtworkElement returned by get (kind text), keeping all rich UTF-16 spans, glyph choices, list identities and style links; raw text-only edits must supply compatible existing formatting. Source locations are global across all frames. reorder changes capacity order; unlink removes capacity while retaining recoverable global source. publication assigns a page document or null; delete removes the story with native Undo. layout returns actual source/display ranges and overset from the native compositor.",
        ["command":["type":"string","enum":["list","get","create","append","reorder","unlink","edit","publication","delete","layout"]],
         "story_id":string,"publication_id":["type":["string","null"]],"name":string,"text":string,"source":["type":"object"],"language":["type":["string","null"]],
         "frames":["type":"array","minItems":1,"maxItems":400,"items":["type":"object","properties":["object_id":string,"element_id":string],"required":["object_id","element_id"],"additionalProperties":false]]],required:["command"]),
      tool("form_publication",
        "Manage an explicit ordered physical page document. list/get/preflight are read-only. create adopts independent artwork sheets in page_ids order; settings changes name, language, millimeter margins and optional baseline_grid in points. reorder includes all current page IDs exactly once. add_page creates a physical sheet with one to four body columns, optionally appended to story_id; no displayed text fragments are duplicated. Grid alignment is an opt-in paragraph Typography.alignToBaselineGrid property. preflight reports actual story overset, frame/font issues, physical page sizes and output-profile conflicts before export. delete removes document membership while retaining pages/stories. All mutations share native Undo and atomic batches.",
        ["command":["type":"string","enum":["list","get","create","settings","reorder","add_page","delete","preflight"]],
         "publication_id":string,"name":string,"page_ids":["type":"array","items":string,"maxItems":200],"language":["type":["string","null"]],
         "margins":["type":"object","properties":["top":number,"right":number,"bottom":number,"left":number],"required":["top","right","bottom","left"]],
         "baseline_grid":["type":["object","null"],"properties":["spacing":number,"origin":number],"required":["spacing","origin"]],
         "story_id":string,"width":number,"height":number,"columns":["type":"integer","minimum":1,"maximum":4],"gutter":number],required:["command"]),
      tool("form_export_publication",
        "Export a real ordered multipage physical PDF from a publication. Pages retain individual MediaBox/TrimBox/BleedBox dimensions, shared story composition, rich text, generated lists and vector artwork. Default export refuses overset source; inspect form_publication preflight and add capacity first, or explicitly set allow_overset for a reviewed partial output. outline_text creates vector glyph paths. Optional per-page ICC profiles must have the same SHA on every page; conversion is applied to actual PDF content while editable source stays sRGB. Does not print or contact any device.",
        ["ink_output":["type":"string","enum":["preview","composite","plates","preflight"],"description":"Explicit ink mode when declarations are used: RGB appearance preview, opaque ICCBased/Separation composite, positive unscreened ink-map pages, or read-only preflight. Unsupported paints are rejected for production modes."],"publication_id":string,"path":["type":"string","description":"Absolute local PDF path; omitted writes the project's Exports folder."],"dpi":number,"outline_text":["type":"boolean"],"allow_overset":["type":"boolean"]],required:["publication_id"]),
      tool("form_text_style",
        "Manage reusable project typography styles. list is read-only. create/update accepts name, font_size in points, and a partial Typography object (fontName, kerningMode, tracking, leading, paragraph spacing/indents/alignment, features, independent featureSelections, variations, etc.). Styles preserve colors/palette links, frame behavior, and manual pair positions. update changes inherited properties across all users while retaining explicit local overrides. assign/reset/detach target text layers or text within selected groups; an optional UTF-16 location/length targets one text object's characters. Partial ranges keep a separate live paragraph-style link; whole-text assignment includes paragraph formatting. reset removes local overrides; detach/delete preserve appearance. create optionally applies to object_id/element_ids in the same undo step. Generic artwork edits record local property overrides. Shared native Undo and atomic batches.",
        ["command":["type":"string","enum":["list","create","update","assign","reset","detach","delete"]],
          "style_id":string,"name":string,"font_size":number,"typography":["type":"object"],
          "reset_selection":["type":"boolean","description":"With update, reset matching style overrides in object_id/element_ids in the same undo step (native Redefine)."],
          "object_id":objectID,"element_ids":["type":"array","items":string],
          "location":["type":"integer"],"length":["type":"integer"]],required:["command"]),
      tool(
        "form_swatch",
        "Manage the project's named palette: sRGB previews plus optional profile-pinned CMYK/spot ink declarations. list reads swatches; create/update changes a named color. assign binds artwork fill, stroke, shadow, gradient_stop, background, component_part, or a UTF-16 text_range. Changes update every reference across source documents and physical faces. detach freezes that reference's current appearance; delete freezes all references before removing the color. Instance fill binding is a component override. All mutations share native undo and atomic batches; stored consumer resources are unchanged by palette color updates. Used production inks reject detach/delete until print_ink:null explicitly converts their intent to RGB preview.",
        [
          "command": ["type": "string", "enum": ["list", "create", "update", "assign", "detach", "delete"]],
          "swatch_id": string, "name": string, "color": string,
          "print_ink":["type":["object","null"],"description":"Optional schema35 production declaration. {kind:process_cmyk|spot,components:{cyan,magenta,yellow,black} each 0..1,profile:{name,asset,sha256,model:CMYK},spotName for spot,tint 0..1(default1)}. Process uses raw components/tint 1; spot uses components as alternate appearance. Profile bytes must already exist in Assets via form_color_profile. Preview HEX is ColorSync-derived. Same spot name requires consistent alternate/profile. Null explicitly converts this swatch to RGB preview; used inks cannot otherwise be detached/deleted."], "object_id": objectID,
          "element_ids": ["type": "array", "items": string],
          "target": ["type": "string", "enum": ["fill", "stroke", "shadow", "gradient_stop", "background", "component_part", "text_range"]],
          "stop_id": string, "part_id": string, "location": ["type": "integer"], "length": ["type": "integer"],
        ], required: ["command"]),
      tool(
        "form_edit_artwork",
        "Apply a native artwork command: add/replace elements, delete, duplicate, group, ungroup, align, distribute, reorder, flip, clip, release_clip. Use complete element values for add/replace. origin sets one layer/group's normalized local transform reference {x,y}, or null resets to center; changing origin never moves artwork. transform applies positive scale_x/scale_y, relative rotation degrees, and translate_x/translate_y millimeters in that order around the selected layer's origin; multiple roots use their combined center. clip uses mask_id or the bottom selected area shape; targets and mask must be siblings. Geometry stays editable; use nested clipped groups for nested masks. release_clip preserves the mask shape. Alignment modes: left/right/top/bottom/center_x/center_y/width/height; distribution: horizontal/vertical; order: front/back/forward/backward. glyph assigns fontName/glyphID/glyphName/fontSignature discovered by form_font_features to one source UTF-16 location/length while retaining editable text; glyph:null clears the range or all selected text choices. paragraph patches paragraph typography on selected text; optional UTF-16 location/length expands to full paragraphs while retaining rich characters. Returns selected element IDs. font changes only font_name on selected text, optionally within a global source UTF-16 location/length; it preserves words/features/axes/glyph choices. All changes share native undo.",
        [
          "role": ["type":["string","null"],"enum":["print","cut","score","stitch","engrave","guide",NSNull()],"description":"With command production, assign a manufacturing role to selected roots and inherit it through descendants; null clears to inherited/default print. A non-print ancestor controls its whole subtree; edit that group first. Legacy artwork is accepted as print."],
          "object_id": objectID, "mask_id": string, "font_name":string,
          "command": ["type": "string", "enum": ArtworkCommands.names+["transfer"]],
          "language": ["type": ["string", "null"], "description": "For command language: BCP47 document default (for example en-US, de, tr), or null for automatic. Source words remain unchanged; text/rich-span Typography.language can override the document."],
          "piece": ["type":["object","null"], "description":"With pattern_piece: sewing metadata for selected sharp rectangle/regular polygon/closed convex straight path. Fields name, seamAllowance mm, edgeAllowances {edgeIndex:mm}, cutQuantity, materialID, grainAngle degrees, onFoldEdge, notches [{id,edge,position 0...1,width,depth}], notes. Shape geometry stays the physical stitch outline; null removes annotation and its seam joins."],
          "seam": ["type":["object","null"], "description":"With seam_pair: {id,name,first:{elementID,edge,copy},second:{elementID,edge,copy},reversed,tolerance mm}. Edges are zero-based local contour order; copy is1-based cut copy. Unequal lengths remain an explicit diagnostic. Null with seam_id removes a join."],
          "seam_id": string,
          "template": ["type":"string","enum":["tote","roundedPouch"],"description":"With pattern_template append editable original tote or roundedPouch source geometry to the current Canvas/frame. Curved pouch dimensions are measured stitch outlines, not calibrated fit."],
          "pattern_parameters": ["type":"object","description":"Pattern physical parameters: tote width,height,handle_length,handle_width,seam_allowance,top_hem; roundedPouch width,height,corner_radius,facing_height,seam_allowance (mm),material_id. Native creation automatically sizes a new frame; MCP can create an800×750mm frame first or use unbounded Canvas."],
          "tile_options": tileOptions.merging(["type":["object","null"],"description":"With command pattern_tiles, save complete physical sheet options, or null to clear. One Undo/autosave; source geometry and linked 3D appearance are unchanged. Preview/export overrides do not save options."]){_,new in new},
          "layout_action": ["type":"string","enum":["save","plan"],"description":"With command cut_layout, save complete cutting_layout metadata/manual poses or explicitly run the bounded planner. Saving never rearranges pieces."],
          "cutting_layout": ["type":["object","null"],"description":"With cut_layout: {id,name,materialID,stockWidth mm,surface roll/sheet,sheetLength mm,stock singleLayer/foldedPair,grain directional/bidirectional/unrestricted,margin mm,spacing mm,maximumLength mm,costPerSquareMeter,costCurrency,fabricOrigin:{x,y}mm,elementIDs,placements:[{elementID,copies:[1] or[1,2],x,y,rotation}]}. Width remains unknown until declared. Maximum200 placements/5m length; stock/fold constraints and exact outline clearance are preflighted. Null removes layout."],
          "list_action":["type":"string","enum":["set","remove","indent","outdent","restart","continue"]],
          "marker":["type":"string","enum":["bullet","decimal"]],
          "list_id":["type":"string","description":"With command list, shared list UUID for continuation across text objects in artwork layer order; raw source contains no generated marker characters."],
          "level":["type":"integer","minimum":0,"maximum":5],
          "restart":["type":"integer","minimum":1,"maximum":999999],
          "marker_font":["type":"string","description":"Optional installed list marker font. Empty string inherits the paragraph font."],
          "target_object_id":["type":"string","description":"With command transfer, move selected roots/descendants to this artwork frame or Canvas workspace. Keeps hierarchy, styles, assets and masks. The default offset preserves physical Canvas placement using saved canvasPosition. Required external masks are copied; inherited clipped/effect groups must be selected as a whole. Returns destination owner ID and selected root IDs."],
          "offset_x":["type":"number","description":"With transfer, optionally provide BOTH offset_x and offset_y in mm to override the source-local to destination-local translation."],"offset_y":number,
          "element_ids": ["type": "array", "items": string],
          "elements": ["type": "array", "items": ["type": "object"]], "mode": string,
          "axis": string,
          "origin": ["type":["object","null"],"description":"With command origin, normalized local coordinates x/y (0 top/left, 0.5 center, 1 bottom/right; −10…10 for an external pivot), or null to reset. Does not move rendered geometry."],
          "rotation": number,"scale_x":number,"scale_y":number,
          "translate_x":number,"translate_y":number,
          "typography": ["type": "object", "description": "With paragraph, patch paragraph properties: tabStops [{location in pt, alignment left/center/right/decimal, optional decimalSeparator period/comma}], defaultTabInterval in pt, leading, spacing/indents, alignment, direction natural/ltr/rtl, hyphenation 0–1, language (BCP 47 or null to inherit), hyphenationLimits {minimumWordLength 2–100, minimumPrefix 1–30, minimumSuffix 1–30} or null. Explicit language drives the installed dictionary; an unavailable dictionary disables automatic word hyphenation. A UTF-16 location/length expands to containing paragraphs, preserving source words and character formatting."],
          "location": ["type": "integer"], "length": ["type": "integer"],
          "glyph": ["type": ["object","null"], "description": "With command glyph, provide fontName, glyphID, optional glyphName and fontSignature from font glyph discovery. location/length selects source UTF-16 characters. null clears choices in that range, or all selected text when the range is omitted."],
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
        "Read installed Mac font catalog or complete document font usage. command families(default) or faces supports family/style/PostScript-name search and offset/limit paging; usage includes missing faces, rich spans, text styles, shared stories, list markers and recoverable exact glyph assignments. No installation or replacement occurs.",
        ["command":["type":"string","enum":["families","faces","usage"]],"query":string,"offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":256]],readOnly:true),
      tool("form_replace_font","Explicit project-wide replacement of one exact font face with an installed face. dry_run reports affected uses without mutation. Original words, rich ranges, features, axes, style identities, list IDs and exact glyph choices remain stored. Exact choices retain their original font/signature and require explicit review rather than glyph-ID reinterpretation. One document Undo restores the whole replacement.",
        ["from_font":string,"to_font":string,"dry_run":["type":"boolean"]],required:["from_font","to_font"]),
      tool(
        "form_font_features",
        "Read-only font discovery. command features (default) inspects an installed face's actual OpenType selectors, exclusivity, defaults and variable axes/ranges. Typography.features maps a mutually exclusive type to one selector; featureSelections maps an independent type to multiple selectors (even on, next odd off). Font defaults are retained by omitting the pair. These fields work on whole text and UTF-16 textRuns through form_edit_artwork replace. Typography.kerningMode accepts metrics (font pair spacing plus independent tracking/manual deltas) or none; omission preserves original document spacing. Explicit kerning modes require schema 13 and are inherited by text styles. Missing fonts are explicit. command glyphs pages the actual font repertoire with query (name substring, numeric/gid: ID, or U+hex), offset, and limit 1–128. command alternates shapes source text and its UTF-16 location/length (1–64 units) with optional typography and returns actual one-glyph alternatives supported by the face, with fontName/glyphID/glyphName/fontSignature metadata for form_edit_artwork command glyph. Glyph choices retain original editable text and require schema 15.",
        ["font_name": string,
         "command": ["type":"string","enum":["features","glyphs","alternates"]],
         "query": string,"offset":["type":"integer"],"limit":["type":"integer"],
         "text":string,"location":["type":"integer"],"length":["type":"integer"],
         "typography":["type":"object","description":"Optional current typography for alternate shaping, including features, variable axes and case treatment."]],
         required: ["font_name"], readOnly: true),
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
        "Export the selected artboard/product face as actual-size SVG/PDF or PNG/JPEG at a chosen DPI. Optional element_ids exports a selection. SVG text can be converted to portable outlines. Tab-aligned and hyphenated text use outlines to preserve native composition even when outline_text is false; the result reports composed_text_outlined.",
        [
          "ink_output":["type":"string","enum":["preview","composite","plates","preflight"],"description":"Explicit mode for declared production inks: appearance preview, opaque ICCBased/Separation PDF composite, positive unscreened digital ink-map PDF, or read-only preflight. Production modes require matching portable CMYK profile, flat opaque vectors, shared text outlines and geometric masks; images/gradients/alpha/effects/blends are rejected. No overprint/trapping/screening/PDF-X claim."],
          "object_id": objectID,
          "format": ["type": "string", "enum": ["svg", "pdf", "png", "jpeg", "dst", "json", "preflight"]], "path": string,
          "embroidery_format": ["type":"string", "enum":["dst","json","svg","preflight"], "description":"Export actual embroidery commands instead of artwork. dst/json/preflight format selects embroidery automatically; SVG requires embroidery_format:svg. DST emits an adjacent .threads.json ordered color sidecar. Requires saved embroidery settings on a textile decoration. Rejects mixed output selectors."],
          "show_jumps": ["type":"boolean", "description":"Include dashed non-needle travel in the actual-stitch SVG preview."],
          "roles": ["type":"array","items":["type":"string","enum":["print","cut","score","stitch","engrave","guide"]],"description":"Optional explicit output roles. Default exports printable artwork only. SVG creates separate named layers; PDF creates one physically sized page per nonempty role. Guides require explicit opt-in. Cut/score/stitch need vector geometry without images/effects; stitch paths are not digitized machine programs."],
          "dpi": number, "outline_text": ["type": "boolean"],
          "element_ids": ["type": "array", "items": string],
          "fabric_pattern_material": ["type":"string", "description":"Export this project's fabric material pattern as physical yardage instead of the object face. Uses its saved outputWidth/outputLength; object_id still identifies the project context."],
          "pattern_tiles": ["anyOf":[["type":"boolean"],tileOptions],"description":"With pattern_pieces:true: true uses saved sheet options or A4 defaults; a complete object overrides only this export. PDF preserves the entire authoritative source at100%, with repeated overlap, paper-trim/registration marks, row/column labels and one calibration cover. Maximum200 total pages. format:preflight returns coverage/boxes without files. Absent/false keeps existing large-format output. No printer operation."],
          "pattern_pieces": ["type":"boolean", "description":"True generates physical cutting templates from annotated sewing pieces. Includes per-edge seam allowances, real notches, omitted cut-on-fold edges, grainlines, cut quantities, dimensions, construction notes, seam mismatch diagnostics and a50mm calibration square. SVG retains named cut/stitch/guide layers; PDF combines them on one actual-size sheet. Optional element_ids selects pieces. Cannot combine with other output selectors."],
          "cut_layout": ["type":"boolean","description":"Export the source document's saved material cutting layout at actual working-stock width/length. Exact source contours, copy/ply counts, grain/fold/spacing preflight and declared material consumption are retained. Cannot combine with other output selectors."],
          "layout_preflight": ["type":"boolean","description":"With cut_layout true, return exact issues, copy poses and consumption/cost assumptions without writing a file."],
          "include_fabric_preview": ["type":"boolean","description":"With cut_layout true, optionally add a roll-anchored fabric reference layer clipped to cut pieces. The upper/right ply is shown for folded stock. Motif phase is physical; seam continuity and machine postprocessing are not verified."],
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
        "Set a camera preset or design surface. canvas opens the freeform 2D Canvas; split shows Canvas beside Table; canvas_window opens Canvas in a separate native window. These share one project and Undo history. artwork retains the finite-frame editor view. Optional object_id selects the target; element_ids and node_ids select artwork layers and path nodes. Named camera views always frame the whole physical project.",
        [
          "view": [
            "type": "string",
            "enum": [
              "perspective", "overhead", "front", "fit", "focus", "isolate", "show_all", "home",
              "table", "canvas", "split", "canvas_window", "artwork", "studio", "print_bed", "print_object",
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
        "Open native print preparation for the current project's selected object/component. Prepares its real millimeter mesh even if it has never been rendered. Project switches dismiss/reset this workspace and stop its active local slice. A different object cannot be selected during a live slice. Sending and starting prints are disabled.",
        ["object_id": objectID]),
      tool(
        "form_get_print_setup",
        "Read current project_id, prepared_project_id, workspace_presented, object/component, physical mesh/bed fit, printer, filament, settings, engine availability, and status. Null preparation fields indicate no object is prepared. Read-only; no credentials are returned.",
        readOnly: true),
      tool(
        "form_set_print_options",
        "Set native print options with shared Undo/Redo; settings and preview remain synchronized. Rotation is {x,y,z} in printer degrees (Z up); scalePercent never changes original dimensions. Lamp components: Shade, Stem, Base, Complete object. Active slices reject setting edits.",
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
        "Read local slicing progress, project/preparation ownership, errors, output folder, layer count, material and time estimates. Late results from an invalidated project/object cannot replace the current preview. Does not contact a printer.",
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
      tool("form_color_profile",
        "List installed local RGB/CMYK ICC profiles, get an artwork source's PDF output profile, or set/clear its portable profile with shared Undo. Editing colors and previews remain sRGB. PDF colors actually convert through ColorSync while preserving vector paths, supported embedded fonts, gradients and images. Assigning a profile never reinterprets source HEX colors. SVG/PNG/JPEG remain sRGB. Generic CMYK is a conversion study, not a printer-specific production condition. No device connection or printing occurs.",
        ["command": ["type": "string", "enum": ["list", "get", "set", "clear"]],
         "object_id": objectID,
         "profile_path": ["type": "string", "description": "For set: absolute path to a local RGB/CMYK ICC file under 16 MB; bytes are copied into the project Assets with a SHA-256 identity."]]),
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
