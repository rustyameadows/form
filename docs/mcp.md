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
| `form_import_svg` | Review and import local SVG into native editable artwork, retaining originals and reporting fidelity differences |
| `form_edit_path` | Precise Bézier edits, cross-object endpoint joining, compound creation/release, and multi-path physical node transforms |
| `form_list_fonts`, `form_font_features` | Installed faces, supported font features, and variable axes |
| `form_convert_to_paths`, `form_boolean_artwork` | Editable glyph/stroke/shape outlines; live vector booleans, update/release/flatten, and divided regions |
| `form_export_artwork` | Actual-size SVG/PDF and DPI-controlled PNG/JPEG frame or selection exports |
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

There are 42 tools. Print options use the native configuration keys: `component`, `printerID`, `filamentID`, `layerHeight`, `infillPercent`, `wallLoops`, `supports`, `brimWidth`, `scalePercent`, and `rotation` (degree-valued `x`, `y`, `z` in printer coordinates). `form_slice` starts asynchronously; poll status until `busy` is false and inspect `validation_error` before consuming outputs. `form_set_view` accepts `print_bed` / `print_object`. See [printing setup](printing.md) for examples and the explicit no-print boundary.

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
