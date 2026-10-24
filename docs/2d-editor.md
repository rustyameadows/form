# Native artwork editor

The editor is a working part of the expanded [2D specification](2d-design-typography-vector-spec.md), not completion of it. The [implementation goal](implementation-goal.md) retains its full acceptance requirements.

## Working now

- Multiple physically sized sheets on one canvas: presets/custom dimensions, editable names and dimensions, independent placement, mm/cm/in/pt, pan, pinch zoom, fit, rulers, grid, numeric and ruler-dragged guides, guide locks, snapping, and nudges.
- Selection/marquee, exact transforms, resize/rotation handles, flips, alignment/distribution, matching size, nested groups/scoped editing, layer naming/order/visibility/locks, duplication, and clipboard operations.
- Rounded rectangles, ellipses, lines, polygons, stars, pen-created Bézier paths, direct anchor/handle editing, corner/smooth/symmetric modes, shape-preserving subdivision/split/join, reversal, node marquee selection, exact multi-node transforms, open/closed contours, and deletion. Union/subtraction/intersection/exclusion produce editable paths and retain hidden source shapes.
- Solid fills, linear/radial gradients, stroke widths/caps/joins/dashes, opacity, vector clipping masks, images with original assets preserved, replacement, and effective-DPI inspection.
- Installed-font search and previews, families/styles, favorites/recents, explicit missing-font assignments, actual Core Text feature and variable-axis discovery, native rich text, and selected-character formatting with UTF-16 ranges.
- Core Text shaping and editable glyph outlines, including fallback fonts, ligatures, variable settings, underline, and strikethrough. Outlining retains hidden editable text. Canvas, 3D textures, PDF, and raster outputs share a renderer.
- Autosave, session undo/redo, coalesced pointer/text interactions, project-switch draft commits, and schema-2 packages. Legacy schema-1 projects still load; older foundation readers reject schema 2 rather than silently discarding extended artwork.
- Actual-size SVG/PDF and DPI-controlled PNG/JPEG frame/selection exports. SVG outlines text by default. Selection export preserves required group transforms, opacity, and masks. Printable artwork is distinct from cut/score/stitch/engrave/guide roles.

Text properties include point/area mode, font/style/size, leading, tracking, pair kerning, baseline, word spacing, alignment, paragraph spacing/indents, case, ligatures, direction, hyphenation, and vertical alignment. Shaping uses typographic points internally and millimeters at the artwork boundary. Font controls expose capabilities reported by the installed face.

## Controls

Create an artwork sheet from **Object**, or use **Artwork → New Artwork Frame**. **Frame** offers physical presets and custom sizes. Select an artwork-bearing physical object and choose **Artwork** to edit its surface with a live 3D preview.

| Action | Control |
| --- | --- |
| Select / direct select / text | `V` / `A` / `T` |
| Rectangle / ellipse / line | `R` / `O` / `L` |
| Polygon / star / pen | `P` / `S` / `B` |
| Pan / eyedropper | `H` / `I` |
| Temporary pan | Space-drag |
| Edit text / enter group | Double-click |
| Finish text / leave group | Escape |
| Extend selection | Shift-click |
| Constrain movement/rotation/shape | Shift-drag |
| Bypass snapping | Option-drag |
| Nudge / larger nudge | Arrow / Shift-arrow |
| Fit frames | `⌘0` |
| Zoom | Pinch, zoom menu, `⌘+` / `⌘−` |
| Group / ungroup | `⌘G` / `⇧⌘G` |
| Convert text to outlines | `⇧⌘O` |
| Toggle guides / grid | `⌘;` / `⌘'` |

Drag from a ruler to add a guide. Clear the selection to inspect frame dimensions, guides, grid, and nudge settings. Physical fields accept explicit suffixes such as `8 in`, `25.4 mm`, and `72 pt`.

While editing text, select characters and change typography controls to format that range. Native undo/redo remains granular during editing. After leaving text, document undo restores the complete text-editing session. Cancelling all changes preserves the previous redo branch.

## MCP

There are 39 tools. Artwork tools include `form_get_artwork`, `form_edit_artwork`, `form_list_fonts`, `form_font_features`, `form_convert_to_paths`, `form_boolean_artwork`, `form_export_artwork`, and `form_edit_path`. They use the native model/editing functions. Tool discovery provides exact schemas and ranges.

```json
{"name":"form_list_fonts","arguments":{"query":"Georgia"}}
{"name":"form_font_features","arguments":{"font_name":"Skia"}}
{"name":"form_set_view","arguments":{"view":"artwork","object_id":"<frame UUID>","element_ids":["<text UUID>"]}}
{"name":"form_edit_artwork","arguments":{"object_id":"<frame UUID>","command":"group","element_ids":["<first UUID>","<second UUID>"]}}
{"name":"form_export_artwork","arguments":{"object_id":"<frame UUID>","format":"pdf","path":"/absolute/path/artwork.pdf"}}
```

`form_set_artwork` replaces a validated definition. `form_edit_artwork` supports add, replace, delete, duplicate, group, ungroup, align, distribute, reorder, and flip. `form_set_view` can select element IDs. Paths store ordinary contours/nodes; typography stores face names, features, axes, and optional rich text spans. Read-only calls preserve native editing focus; mutations commit active text and numeric drafts first.

See [precise paths and transformed native text](path-editing.md) for direct selection, native text coordinates, and MCP node editing.

## Remaining work

- Joining separate path elements into a compound; non-destructive boolean groups/division; transform origins; reusable vector components/overrides; swatches; effects/blending; full gradient-stop workflows; image crop/adjustments and drag/drop.
- Editable SVG import/interchange and explicit unsupported-feature reporting. Optional live-text SVG is less portable than outlined output and requires receiving-font/shaping review.
- Alternate-glyph selection, multiple non-exclusive feature settings, complete case treatment within mixed-character editing, reusable text styles, tabs/lists, linked text frames, sequential multi-page documents, and publication layout.
- Color-managed production output, CMYK/spot separations, full preflight, role-specific production exports, advanced surface placement, and the complete demonstration/acceptance suite.

The current **Soft geometry** demonstration is an 8 × 10 inch composition with installed type, gradients, an editable compound shape, a matching outlined version, and physical SVG/PDF/raster exports. It does not replace the required clock dial, folding package, apparel/patch graphic, and instruction booklet demonstrations.

## Validation

Use `bash scripts/test.sh`, `python3 scripts/smoke_artwork.py`, and `python3 scripts/benchmark_artwork.py` against an isolated running library. The smoke script verifies installed fonts/features, editable geometry/outlines, invalid-edit rollback, physical output dimensions, and save/reopen through real stdio MCP. The benchmark measures 600 elements and 300 shaped text layouts. See [validation notes](validation.md) for measurements and native UI evidence.
