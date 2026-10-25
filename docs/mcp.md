# Create with Codex

FORM's app and MCP executable use the same editing engine. Keep the native app open, describe a product in Codex, and use the resulting native controls to explore it. There are no external model calls inside FORM.

## Connect

Build the app first, then register the bundled stdio server:

```sh
codex mcp add form -- /absolute/path/to/form/build/FORM.app/Contents/MacOS/form-mcp
```

Alternatively add this to the applicable Codex `config.toml`, replacing the path:

```toml
[mcp_servers.form]
command = "/absolute/path/to/form/build/FORM.app/Contents/MacOS/form-mcp"
```

The app's **Codex connection** panel copies the exact configuration for its current location. Codex supports local stdio servers in shared or trusted project configuration; see the [official MCP configuration documentation](https://developers.openai.com/codex/mcp/). Open a new Codex chat or reconnect the server if an existing chat has not loaded it.

## A first conversation

> Create a warm orange table lamp, about 350 mm tall. Let me adjust the shade diameter, shade height, top opening, stem diameter, and base width. Put a sage version next to it for comparison.

An agent can discover `lamp` with `form_list_recipes`, create or open a project, add the lamp, duplicate a linked variant, and frame both. Native parameters update immediately. The same operations are available without MCP framing for development:

```sh
build/FORM.app/Contents/MacOS/form-mcp --call form_status '{}'
build/FORM.app/Contents/MacOS/form-mcp --call form_create_project '{"name":"Evening light"}'
build/FORM.app/Contents/MacOS/form-mcp --call form_add_object '{"recipe_id":"lamp","material_id":"vermillion","parameters":{"height":350}}'
```

## Tools

| Tools | Use |
| --- | --- |
| `form_status`, `form_list_projects`, `form_get_project` | Inspect the app, selection, renderer diagnostics, and saved/current projects |
| `form_create_project`, `form_open_project` | Start blank, clock, cyanotype, lamps, or forms studies; continue a saved project |
| `form_list_recipes`, `form_list_materials` | Discover schemas, ranges, defaults, and material IDs |
| `form_add_object`, `form_update_object`, `form_delete_objects` | Create and edit real native objects |
| `form_create_recipe` | Define a new object category and its native inspector |
| `form_duplicate_object`, `form_group_objects` | Iterations, linked variants, and group relationships |
| `form_set_artwork`, `form_import_reference` | Editable surface graphics and persistent local references |
| `form_link_artwork`, `form_extract_artwork` | Independent source documents, physical fitting, and appearance-preserving detachment |
| `form_get_artwork`, `form_edit_artwork` | Inspect and edit artwork elements, layers, groups, and transforms |
| `form_component` | List/create reusable sources, place linked instances, override/reset appearance and text, and detach |
| `form_appearance` | Editable opacity, blend modes, group isolation, blur, and shared-color drop shadows |
| `form_swatch` | List/create/update project colors, assign or detach paint links, and delete while preserving current appearance |
| `form_edit_paint` | Gradient stops/axis, complete stroke styles, inside/outside alignment, and atomic paint patches |
| `form_import_image`, `form_edit_image`, `form_image_info` | Original image placement/replacement, editable crop/adjustments, and resolved physical DPI |
| `form_import_svg` | Review and import local SVG into native editable artwork, retaining originals and reporting fidelity differences |
| `form_edit_path` | Precise Bézier edits, cross-object endpoint joining, compound creation/release, and multi-path physical node transforms |
| `form_list_fonts`, `form_font_features` | Installed faces, supported features/axes, real glyph repertoires and alternates |
| `form_text_style` | Reusable typography, character/paragraph inheritance, persistent local overrides, reset, redefine, and detachment |
| `form_convert_to_paths`, `form_boolean_artwork` | Editable glyph/stroke/shape outlines; live vector booleans, update/release/flatten, and divided regions |
| `form_export_artwork` | Actual-size SVG/PDF and DPI-controlled PNG/JPEG frame or selection exports |
| `form_cloth` | Configure real cloth, bounded runtime controls, actual mesh snapshots and material-point attachments; open surfaces are rejected for slicing |
| `form_add_note` | Design decisions and open questions |
| `form_set_view` | Camera presets, focus, isolation, and workspace modes |
| `form_export` | PNG, PDF, SVG, and component/material JSON |
| `form_batch`, `form_undo`, `form_redo` | Atomic multi-object work and reversible edits |
| `form_open_print`, `form_get_print_setup`, `form_set_print_options` | Open the native bed workspace, inspect and save component/filament/slice settings |
| `form_slice`, `form_get_slice_status`, `form_cancel_slice` | Run and inspect local Orca jobs; no printer transmission |
| `form_list_filaments`, `form_save_filament` | Read and edit reusable Studio filament/inventory profiles |
| `form_list_printers`, `form_connect_printer` | Read metadata/status or connect using credentials already saved in Keychain |

Read-only project and recipe resources are also exposed as `form://project` and `form://recipes`. The `design_object` prompt supplies a starting workflow.

`form_boolean_artwork` defaults to live Union/Subtract/Intersect/Exclude groups; `operation: divide` creates editable regions. `mode` also accepts `update`, `flatten`, `release`, and `path` for a direct flat result with hidden source operands. These edits and `form_convert_to_paths` participate in atomic `form_batch` operations. See the [live boolean guide](live-booleans.md) for examples, compatibility constraints, and schema-5 persistence.

Tool discovery lists the current tools. Print status includes `project_id`, `prepared_project_id`, and `workspace_presented`. A successful project switch dismisses/resets preparation and stops its active local worker; late results cannot update another project. Print settings and mesh follow document Undo/Redo. Print options use the native configuration keys: `component`, `printerID`, `filamentID`, `layerHeight`, `infillPercent`, `wallLoops`, `supports`, `brimWidth`, `scalePercent`, and `rotation` (degree-valued `x`, `y`, `z` in printer coordinates). `form_slice` starts asynchronously; poll status until `busy` is false and inspect `validation_error` before consuming outputs. `form_set_view` accepts `print_bed` / `print_object`. See [printing setup](printing.md) for examples and the explicit no-print boundary.

`form_component` edits reusable vector sources and instances across project artwork frames and linked physical products. Source edits retain consumer object resources; instances support independent size, global/per-part fill, text, opacity, reset, and detach. `form_get_artwork` accepts `resolved: true` to inspect the expanded hierarchy. See [components and STRATA](reusable-components.md) for schemas, examples, and limits.

`form_swatch` shares named sRGB colors across project artwork and linked physical faces. It supports fills, strokes, shadows, gradient stops, backgrounds, component parts, and UTF-16 text ranges. Read-only `command: list` preserves native drafts; all mutations participate in atomic batches and Undo. `form_get_artwork` with `resolved: true` also bakes current palette values into the derived output. See [shared swatches and CHROMA](shared-swatches.md) for exact arguments and persistence.

`form_appearance` patches selected root layers with `opacity`, `blend_mode`, group `isolate`, `blur`, and `shadow` values; `command: reset` clears their appearance. Disabled effects retain their settings, and clipping follows effects. `form_swatch target: shadow` binds or detaches a shared shadow color. Both commands support atomic batches and Undo. See [editable appearance and UMBRA](artwork-appearance.md) for exact examples, schema-8 persistence, group semantics, and export limits.

`form_edit_paint` patches vector strokes and gradients, retaining stable stop UUIDs as they reorder. `form_edit_artwork` includes `clip` and `release_clip`; mask geometry remains editable. See [PRISM, gradients, strokes, and masks](paint-gradients-masks.md) for native gestures, command examples, schema-10 persistence, and bounded stroke expansion.

`form_font_features` reports actual per-face selector exclusivity and defaults. `Typography.featureSelections` supports several independent selectors per type on a whole text element or each UTF-16 `textRuns` span; `features` retains single/exclusive settings. Use `form_edit_artwork` with `command: "replace"` and the complete updated element, including both fields. Native controls use the same selection rules, validation, Undo, and schema-11 model. See [FOUNDRY and the selector format](font-features.md). `Typography.kerningMode` accepts `metrics` or `none`; omitted/null retains original spacing. It works on elements, rich spans, and reusable styles. Explicit modes use schema 13; see [AVENUE and spacing](kerning.md).

`form_text_style` creates and updates named project typography, assigns whole text or UTF-16 character ranges, and resets/detaches/deletes without losing current appearance. Character styles retain independent paragraph inheritance; updates preserve explicit local overrides. Create-and-assign and redefine-and-reset are single Undo edits. Read-only `list` retains native drafts. See [FOLIO and text styles](reusable-text-styles.md) for arguments and schema-12 persistence.

`form_font_features command: "glyphs"` pages the actual face repertoire using `query`, `offset`, and `limit` (1–128). `command: "alternates"` discovers supported single-glyph choices for source `text` at UTF-16 `location`/`length`, with optional current `typography`. The default `features` command retains its existing response. Pass returned `glyph` metadata directly to `form_edit_artwork command: "glyph"` with one selected text ID and a source range. `glyph: null` clears choices intersecting the range; omitting the range clears all choices in selected text descendants. Up to 256 disjoint choices per element each cover 1–64 UTF-16 units, without splitting surrogate pairs or including tabs/paragraph breaks. Choices retain original source, rich formatting, and editable styles. Variable instances share their base-face identity while keeping their axis values. Point text resizes with glyph ink; area frames retain their dimensions. Schema-15 persistence, native/MCP Undo, atomic batches, and export validation share the same command/rendering path. See [QUILL and glyphs](glyphs.md) for exact examples and font-version behavior.

`form_edit_artwork command: "paragraph"` patches selected paragraphs without replacing character formatting. Optional integer UTF-16 `location`/`length` expands to containing paragraphs and accepts a zero-length caret. Saved `tabStops` support left/center/right/decimal alignment; `defaultTabInterval` controls repeating tabs, and `hyphenation` changes actual composition. Values validate atomically and share Undo. SVG exports with `outline_text:false` still outline tabbed/hyphenated text and report `composed_text_outlined`. See [LEDGER and paragraph composition](paragraph-composition.md) for the exact patch format, native draft semantics, and schema 14.

`Typography.caseTreatment` applies `original`, `uppercase`, or `lowercase` independently to text/rich spans and reusable styles. Stored words and MCP character ranges remain in source UTF-16 coordinates when displayed case expands a character. Native source/display records are ephemeral and excluded from projects and production shaping. See [VERSO and reversible case](text-case.md).

`form_import_image` places or replaces a local file while retaining its original bytes. `form_edit_image` patches normalized crop bounds and image adjustments, with atomic batches and Undo. `form_image_info` inspects oriented pixel metadata and effective DPI at the resolved physical output size without disturbing native focus. See [image editing and LUMEN](image-editing.md) for schemas, examples, format support, and output limits.

## Custom objects

Use a built-in recipe when it fits. Otherwise, define a custom recipe with `form_create_recipe`; it persists in that project. `parameters` describe the control surface. `parts` express geometry in those parameters.

```json
{
  "recipe": {
    "id": "lowTable",
    "name": "Low table",
    "parameters": [
      {"id":"width","name":"Width","value":600,"minimum":300,"maximum":1000},
      {"id":"depth","name":"Depth","value":400,"minimum":200,"maximum":800},
      {"id":"height","name":"Height","value":300,"minimum":200,"maximum":600}
    ],
    "parts": [
      {"kind":"box","values":{"width":"width","depth":"depth","height":"20","y":"height-10","corner":"3"}},
      {"kind":"box","values":{"width":"20","depth":"depth-40","height":"height-20","x":"-width/2+30","y":"(height-20)/2"}},
      {"kind":"box","values":{"width":"20","depth":"depth-40","height":"height-20","x":"width/2-30","y":"(height-20)/2"}}
    ]
  }
}
```

Then call `form_add_object` with `recipe_id: "lowTable"` and a material such as `oak`. Supported parts are box, cylinder, cone, sphere, and torus. Supported expression fields and input schemas are described by MCP discovery. All dimensions and positions use millimeters; rotations use degrees. Arithmetic supports numbers, parameter variables, `pi`, parentheses, `+`, `-`, `*`, and `/`.

For related edits, use `form_batch` with an array of `{name, arguments}`. Project switching, file imports, and exports are kept outside batches because they have external side effects. Preserve the Codex chat URL or ID in `conversation_reference` when creating a project if continued conversation context is useful.

## Local validation

```sh
bash scripts/test.sh
python3 scripts/smoke_mcp.py
```

The smoke test uses the real stdio transport, creates a validation project in the running app's library, checks custom recipes and linked edits, and exports to `.local/validation`. For isolated development, launch the app executable with `FORM_LIBRARY_PATH="$PWD/.local/Library"` before running it. The server itself discovers the running app through its local socket; it does not read or mutate the package files behind the app.

See the [native artwork editor guide](2d-editor.md) for artwork commands, file format, and current limitations.

The [clock study and shared-artwork guide](linked-artwork.md) explains source/consumer IDs, actual-size versus proportional fitting, scoped persistence/render updates, and the distinction between physical artwork and cut-profile exports.

See [editable SVG import](svg-import.md) for read-only preflight, explicit fidelity acceptance, physical sizing, and import into shared source artwork.

`form_edit_artwork command: "production"` assigns `role` (`print`, `cut`, `score`, `stitch`, `engrave`, `guide`, or null to inherit). Group assignment clears local descendant roles so the branch inherits its purpose. A non-print ancestor gates its subtree; a conflicting child assignment names that controlling group and rejects atomically. Canonical source locks also apply through linked products. Explicit print uses schema 22; legacy artwork remains a print alias. `form_export_artwork roles:[...]` selects outputs: SVG uses separately named role layers with stable role metadata and prefixed clip/gradient IDs; PDF emits same-size pages in reported `role_pages` order. PNG/JPEG accepts one resulting role. Guides require explicit selection. Omitting roles retains the existing print-export path. See [production roles](production-roles.md) for native controls, limitations, examples, and validation.

## Actual embroidery programs

`form_update_object embroidery:{...}` stores schema-25 digitizing settings on a textile decoration; null removes them and locked decorations reject edits. Settings include 20–500 mm hoop dimensions, clearance, travel-trim threshold, thread palette, and ordered artwork-ID regions for running, constant-width satin, or scanline fill. `form_export_artwork format:dst|json|preflight` regenerates actual commands from current artwork; `format:svg, embroidery_format:svg` emits physical needle paths with command metadata. `show_jumps:false` hides non-needle travel in the SVG only. DST creates an adjacent `.threads.json` ordered-color sidecar; the response reports that path, physical bounds, counts, and source digest. It does not contact equipment. Mixing embroidery with roles, fabric yardage, sewing patterns, or ad-hoc element_ids rejects explicitly. See [regenerable embroidery](embroidery.md) for schema, precise algorithm/process limits, and independent-reader validation.

Schema-28 digitizing adds optional `process:{threadDiameter,tieIn,tieOff,tieLength,tieRepeats}` and per-region `underlay:{method,stitchLength,spacing,inset}`. Center-walk requires satin; sparseFill requires fill with underlay spacing at least 1.5 times its top spacing. All are explicit settings, not inferred machine presets. Preflight returns underlay/tie needle counts and physical thread diameter. Generated commands tag `purpose` for underlay/tie inspection; actual 3D faces use those same commands and omit travel. `form_status.renderer` exposes bounded texture size, program/texture build counters, object source digests, and cached embroidery issues. See [process and physical surfaces](embroidery-process.md).

## Studio thread stock and production jobs

`form_textile_stock` manages shared thread stock and declared embroidery equipment; `assign_thread` snapshots a Studio record into one unlocked configured decoration thread as one Undo. Studio edits/removal preserve prior snapshots and never deduct inventory. `form_production_job` captures immutable SHA-addressed needle/spec revisions, lists/reads jobs, appends user-recorded samples/quality/status, and exports local ZIP/folder packets. Captured source/equipment/material/stock/assumptions remain portable; old exports never regenerate from a changed or deleted live source. Needle meters are measured from stitch commands, while consumption/cost require explicit assumptions and known prices. Unknowns and mixed currencies remain explicit. Packets contain file digests, selected real outputs/sidecars, specifications/BOM, and a review PDF with an actual-size hoop page. No equipment is contacted. See [production jobs](textile-production-jobs.md) for inputs, state semantics, limits, and evidence.

### Text stories and publications

`form_story`, `form_publication`, and `form_export_publication` expose the shared rich source, physical page order, frame capacity, grid composition, preflight, and actual multipage PDF. Paragraph/list/glyph commands on linked frames use global UTF-16 source ranges. See [publications](publications.md) for schemas, safe native handoff behavior and output limits.

### Font library and replacement

`form_list_fonts` supports paged family/face search and complete read-only document `usage`. `form_edit_artwork` command `font` edits only font_name on selected text, optionally within one source UTF-16 range. `form_replace_font` provides an explicit exact-face replacement/dry-run with one document Undo; words, axes, features, rich ranges and exact glyph metadata remain stored. Exact glyph mismatches stay explicit. See [font library](font-library.md).

`form_swatch` now accepts optional `print_ink` declarations (`process_cmyk` or `spot`, 0–1 components/tint and portable CMYK profile); omission preserves intent and null explicitly converts to its RGB preview. Used production inks require explicit conversion before structural detach/deletion. `form_export_artwork` and `form_export_publication` accept `ink_output: preview|composite|plates|preflight`; default source-art PDF refuses used ink declarations. Composite writes real ICCBased/Separation resources; maps are positive unscreened digital colorants with normal knockout. Raster/SVG remain labeled RGB previews. No additional tool is registered. See [production inks](production-inks.md) for physical output limits, atomic failure/Undo, unsupported paints and examples.


`form_production_job kind:decoration` adds read-only preflight, native-aligned HTV/DTF capture, immutable get/list/remove and local ZIP/folder export. The omitted/embroidery kind retains its existing behavior. Actual-size knockout cut SVGs, transparent RGBA or explicit profile-pinned process delivery, mirror/white/background/material declarations and separately labeled underbase references share schema-38 Undo/reopen. Archived read/export does not end live text or regenerate files. No new tool or equipment action is added. See [decoration preparation](decoration-preparation.md).
