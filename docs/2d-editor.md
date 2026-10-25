# Native artwork editor

The editor is a working part of the expanded [2D specification](2d-design-typography-vector-spec.md), not completion of it. The [implementation goal](implementation-goal.md) retains its full acceptance requirements.

## Working now

- Multiple physically sized sheets on one canvas: presets/custom dimensions, editable names and dimensions, independent placement, mm/cm/in/pt, pan, pinch zoom, fit, rulers, grid, numeric and ruler-dragged guides, guide locks, snapping, and nudges.
- Selection/marquee, exact transforms, resize/rotation handles, flips, alignment/distribution, matching size, nested groups/scoped editing, layer naming/order/visibility/locks, duplication, and clipboard operations.
- Rounded rectangles, ellipses, lines, polygons, stars, pen-created Bézier paths, direct anchor/handle editing, corner/smooth/symmetric modes, shape-preserving subdivision/split/join across separate paths, compound creation/release, reversal, node marquee selection, exact multi-node transforms, open/closed contours, and deletion.
- Live Union/Subtract/Intersect/Exclude groups with editable operands, operation switching, release, and appearance-preserving flattening. Divide produces individually editable regions with retained hidden sources. Nested geometry, affine paint, clips, linked faces, and undo use the same resolver. See [live booleans](live-booleans.md).
- Solid fills; direct linear/radial gradient stops and axis controls; complete stroke width/color/opacity/cap/join/miter/dash/phase and center/inside/outside alignment; fill-preserving stroke expansion; explicit editable nested masks ([PRISM](paint-gradients-masks.md)); images with original assets preserved, crop panning/zoom and numeric bounds, brightness/contrast/saturation, layout-preserving replacement, drag/drop, and transform-aware physical DPI. See [image editing and LUMEN](image-editing.md). Image settings use schema 9; schemas 1–8 still load.
- Installed-font search and previews, families/styles, favorites/recents, explicit missing-font assignments, actual Core Text feature and variable-axis discovery, simultaneous independent feature selectors, native rich text, and selected-character formatting with UTF-16 ranges. See [FOUNDRY and font features](font-features.md).
- Core Text shaping and editable glyph outlines, including fallback fonts, ligatures, variable settings, underline, and strikethrough. Outlining retains hidden editable text. Canvas, 3D textures, PDF, and raster outputs share a renderer.
- Autosave, session undo/redo, coalesced pointer/text interactions, project-switch draft commits, and schema-2 packages. Legacy schema-1 projects still load; older foundation readers reject schema 2 rather than silently discarding extended artwork.
- Independent source sheets linked to multiple flat product faces, actual-size/proportional placement, editable source context with a physical live preview, and appearance-preserving detachment. These relationships use schema 3; readers retain schemas 1 and 2.
- Editable local SVG import into new physical frames or existing source/surface artwork, with original SVG and embedded image preservation, native geometry/text/groups, and explicit fidelity review. Import appearance fields and provenance use schema 4; schemas 1–3 still load. See the [SVG guide and ORBIT illustration](svg-import.md).
- Live boolean operations and their original operand hierarchy use schema 5. Schemas 1–4 still load; evaluated geometry stays ephemeral.
- Reusable vector sources across artwork frames and physical products, independent instance sizing/transforms, fill/text/opacity overrides, reset, native source editing/return, nested sources, and appearance-preserving detachment. Components use schema 6; schemas 1–5 still load. See [components and the STRATA demonstration](reusable-components.md).
- Named project sRGB palettes shared by vector fills, strokes, gradient stops, selected text characters, backgrounds, and component overrides. Native typography and glyph conversion retain links; detachment and swatch deletion preserve current colors. Palette data uses schema 7; schemas 1–6 still load. See [shared swatches and CHROMA](shared-swatches.md).
- Non-destructive layer/group opacity, sixteen blend modes, Gaussian blur, drop shadows, shared shadow colors, and explicit group isolation. Native controls, linked physical surfaces, text outlines, and physical exports preserve the combined appearance. These fields use schema 8; schemas 1–7 still load. See [appearance and UMBRA](artwork-appearance.md).
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
| Import SVG artwork | `⇧⌘I` |
| Join endpoints / make compound / release compound | `⌘J` / `⌘8` / `⌥⌘8` |
| Convert text to outlines | `⇧⌘O` |
| Toggle guides / grid | `⌘;` / `⌘'` |

Drag from a ruler to add a guide. Clear the selection to inspect frame dimensions, guides, grid, and nudge settings. Physical fields accept explicit suffixes such as `8 in`, `25.4 mm`, and `72 pt`.

While editing text, select characters and change typography controls to format that range. Native undo/redo remains granular during editing. After leaving text, document undo restores the complete text-editing session. Cancelling all changes preserves the previous redo branch.

## MCP

There are 49 tools. Artwork tools include `form_get_artwork`, `form_edit_artwork`, `form_component`, `form_swatch`, `form_appearance`, `form_edit_paint`, `form_import_image`, `form_edit_image`, `form_image_info`, `form_link_artwork`, `form_extract_artwork`, `form_list_fonts`, `form_font_features`, `form_convert_to_paths`, `form_boolean_artwork`, `form_export_artwork`, `form_import_svg`, and `form_edit_path`. They use the native model/editing functions. Tool discovery provides exact schemas and ranges.

```json
{"name":"form_list_fonts","arguments":{"query":"Georgia"}}
{"name":"form_font_features","arguments":{"font_name":"Skia"}}
{"name":"form_set_view","arguments":{"view":"artwork","object_id":"<frame UUID>","element_ids":["<text UUID>"]}}
{"name":"form_edit_artwork","arguments":{"object_id":"<frame UUID>","command":"group","element_ids":["<first UUID>","<second UUID>"]}}
{"name":"form_export_artwork","arguments":{"object_id":"<frame UUID>","format":"pdf","path":"/absolute/path/artwork.pdf"}}
```

`form_set_artwork` replaces a validated definition. `form_edit_artwork` supports add, replace, delete, duplicate, group, ungroup, align, distribute, reorder, flip, clip, and release_clip. `form_set_view` can select element IDs. Paths store ordinary contours/nodes; typography stores face names, features, axes, and optional rich text spans. Read-only calls preserve native editing focus; mutations commit active text and numeric drafts first.

See [precise paths and transformed native text](path-editing.md) for direct selection, native text coordinates, and MCP node editing. [Live booleans](live-booleans.md) documents the `form_boolean_artwork` modes and Divide. These graphics edits and shape/text/stroke conversion also work in atomic batches.

## Remaining work

- Configurable transform origins and the specification’s later variable-width stroke workflows.
- Full SVG interchange fidelity beyond the [supported import subset](svg-import.md), including filters, patterns, gradient strokes, advanced SVG text, and external resources. Optional live-text SVG is less portable than outlined output and requires receiving-font/shaping review.
- Alternate-glyph selection, complete case treatment within mixed-character editing, reusable text styles, tabs/lists, linked text frames, sequential multi-page documents, and publication layout.
- Color-managed production output, CMYK/spot separations, full preflight, role-specific production exports, advanced surface placement, and the complete demonstration/acceptance suite.

The current **Soft geometry** demonstration is an 8 × 10 inch composition with installed type, gradients, an editable compound shape, a matching outlined version, and physical SVG/PDF/raster exports. It does not replace the required clock dial, folding package, apparel/patch graphic, and instruction booklet demonstrations.

The [Clock dial study](linked-artwork.md) is now available directly from Home. Two clocks reference an independent typography document, with editable numerals/outlines, physical face clipping, actual-size/proportional fitting, and local dial fabrication preparation. The full demonstration suite and advanced physical integrations remain incomplete.

## Validation

Use `bash scripts/test.sh`, `python3 scripts/smoke_artwork.py`, and `python3 scripts/benchmark_artwork.py` against an isolated running library. The smoke script verifies installed fonts/features, editable geometry/outlines, invalid-edit rollback, physical output dimensions, and save/reopen through real stdio MCP. The benchmark measures 600 elements and 300 shaped text layouts. See [validation notes](validation.md) for measurements and native UI evidence.
