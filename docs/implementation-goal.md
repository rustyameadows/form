# FORM implementation goal

Status: **Active**. Expanded October 24, 2026 to include the complete [2D Design, Typography & Vector Editing specification](2d-design-typography-vector-spec.md), alongside the [original product brief](product-brief.md), the supplied interface sketches, and local 3D-print preparation.

## Objective

Deliver a capable, polished native Mac creative environment for both 3D physical design and professional 2D graphic composition. A continuous Table, editable parametric objects, independent and linked artwork, typography, vector geometry, persistent projects, production exports, Studio materials/filaments, and an Orca-powered print workspace must work together. Codex operates the same deterministic editing commands through local MCP; FORM does not call external AI models. Printer setup and status are permitted; sending or starting prints remains disabled under the user's explicit instruction.

The new specification is a governing product document, not a claim that its features already exist. Its complete requirements remain in scope. Its explicit later-stage capabilities retain their staged sequence. Completion requires working native interactions and demonstrated output, rather than controls that only expose stored values.

The goal service currently permits status changes but cannot rewrite the text of an active objective. This file records the expanded objective and completion requirements while that goal stays active.

## Delivery checkpoints

### A. Native 3D studio and fabrication foundation

- [x] Continuous Metal-backed Table; native title bar; contextual inspectors; camera, focus, isolation, selection, movement, grouping, variants, and iterations.
- [x] Home previews of saved scenes; modular packages; autosave; undo/redo; imported assets; Studio materials and equipment.
- [x] Parametric constructions and custom recipes; linked artwork; PDF/SVG/PNG/component exports; local MCP registration and shared command engine.
- [x] Dedicated Print workspace with physical P1S bed, component selection, orientation, scale, filament choice, slicing options, layer preview, and local outputs.
- [x] Persistent Studio filament library; local printer profiles; Keychain credential storage; read-only TLS/MQTT status adapter.
- [x] Real official OrcaSlicer 2.4.2 slice yielding STL, G-code, sliced 3MF, layer preview, and estimates; no printer commands sent.
- [ ] Verify the physical P1S status connection when its IP, serial, and locally entered access code are available.
- [x] Clear an open Print preview on successful project switches, cancel its active local slice, reject late results, and synchronize settings/mesh through Undo/Redo. Direct app tests, real Orca workflows, and native computer use verify the lifecycle.
- [ ] Complete the remaining original-brief physical design workflows; evaluate the 3D environment with the new linked artwork demonstrations.

### B. Credible professional 2D canvas — specification Phase 1

Current progress: the native canvas, physical frames, typography, vector operations, and shared renderer are implemented. [Editor capabilities and gaps](2d-editor.md) and [validation evidence](validation.md) distinguish working features from unfinished acceptance requirements; these broad checkpoint items remain open until their complete scope is demonstrated.

- [ ] Independent artwork documents and multiple physical artboards/pages; unit conversion for mm, cm, inches, and points; presets and exact custom dimensions.
- [ ] Smooth pan, pinch/keyboard zoom, sharp rendering, rulers, numeric/draggable guides, grid, smart snapping, and configurable nudges.
- [ ] Selection, multiple selection, resize, rotate, flip, aspect locking, transform origin, alignment, distribution, matching size, and exact transforms.
- [ ] Layer naming, visibility, locking, ordering, nested grouping, group transforms, and editing within a group.
- [ ] Select/direct-select, text, shapes, pen/Bézier, line/polygon/star, image placement, pan/zoom, eyedropper, and frame tools with conventional shortcuts.
- [ ] Solid fill, stroke controls, basic path editing, native installed font discovery, point and area text, font/style/size/leading/tracking/alignment, and live surface updates.
- [ ] Undo/redo, autosave/reopen, native text input, accessible controls, SVG/PDF/PNG output, and a typography-heavy label or dial completed directly in FORM.

### C. Deep typography — specification Phase 2

- [ ] Searchable previewing font browser with families/faces, favorites, recents, explicit missing-font handling, and preserved assignments.
- [ ] Core Text shaping; all section 4.2 text/paragraph properties; mixed rich text and selected-character editing; point/area text reflow and overflow indicators.
- [ ] Supported OpenType feature discovery, ligatures/alternates/sets, numeral treatments, fractions, caps, contextual/localized forms, and alternate glyph selection.
- [ ] Real variable-font axes/ranges and optical sizing; per-pair kerning, baseline shifts, tracking, superscript/subscript, and character-level features.
- [ ] Reusable paragraph/text styles; tabs, lists, direction, hyphenation, and advanced text frames.
- [ ] Convert shaped text to ordinary editable outlines while preserving glyph positioning, variations, ligatures, and a recoverable editable source.
- [ ] Demonstrate a refined wordmark and typographic clock dial with editable converted glyphs.

### D. Mature vector editing — specification Phase 3

Current progress: [precise compound-path operations and transformed native text](path-editing.md) are implemented and validated. The [editable SVG importer and original ORBIT illustration](svg-import.md) demonstrate native paths/text/groups, affine gradients, clipping, physical units, original assets, explicit fidelity review, and linked product faces. The [Contour atelier workflow](path-editing.md) validates compound creation/release, shape conversion, multi-path node transforms, and cross-object endpoint joining. [Aperture](live-booleans.md) adds editable live boolean groups, operation switching, release/flatten, divided regions, and shared physical previews. Broader SVG fidelity and the remaining vector-system requirements still need completion.

- [x] Complete Bézier node/handle operations, including corner/smooth, add/delete, join/split, close/open, reverse, numeric and multi-node transforms.
- [x] Union/subtract/intersect/exclude/divide where supported; non-destructive boolean groups and flattening; compound paths with holes.
- [x] Linear/radial gradients and editable stops/positions; full stroke styles and expansion; editable nested clipping masks.
- [x] Linked reusable components with overrides and detachment; shared swatches; non-destructive opacity/effects/blending.
- [x] Image crop/replace/mask/adjustments and effective DPI; original asset preservation; drag/drop and supported macOS formats.
- [ ] Editable SVG import/export with transforms, hierarchy, geometry, text, and explicit unsupported-feature reporting; SVG/PDF/PNG/JPEG selection/frame/document export options.
- [ ] Demonstrate an original illustration/logo and production-ready vector outputs.

[Reusable vector components](reusable-components.md) now share source artwork across frames and physical products, with independent placement/size, fill/text/opacity overrides, nested references, reset, and detachment. The STRATA workflow validates these features through native and MCP interactions. [Shared sRGB swatches](shared-swatches.md) now update fills, strokes, gradient stops, selected characters, backgrounds, and component overrides across the CHROMA collection, with appearance-preserving detachment/deletion and native/MCP undo. [Editable appearance and the UMBRA study](artwork-appearance.md) now validate sixteen blend modes, layer/group opacity, Gaussian blur, drop shadows, shared shadow colors, group isolation, preserved text outlines, and physical outputs. Native controls and real MCP workflows complete the component/swatch/basic-effects checkpoint; advanced effects can follow gradually as specified. Production color profiles and physical material/thread/ink mappings remain staged work.

[Image editing and the LUMEN collection](image-editing.md) now complete the basic raster-image checkpoint: original bytes, oriented ImageIO decoding, crop gestures/numeric bounds, image adjustments, layout-preserving replacement, native file drops and asset reuse, clipping, and transform-aware physical DPI. Native and real MCP workflows validate the canvas, linked products, schema-9 persistence, and physical exports. The remaining publication/color and vector requirements above stay open.

[Vector paint and PRISM](paint-gradients-masks.md) now validate on-canvas gradient stops/axes, complete stroke controls and inside/outside geometry, fill-preserving expansion, explicit nested-mask editing, stable references/Undo, schema-10 persistence, and physical outputs through native mouse and real MCP flows. The remaining SVG interchange and production demonstration requirements above stay open.

### E. Print and publication — specification Phase 4

- [ ] Linked text frames, sequential multi-page documents, baseline grids, reusable document styles, and an instruction booklet with multi-page PDF output.
- [ ] Bleed/trim/safe areas, output profiles and color-space metadata, ColorSync conversions, CMYK/spot-color workflows, and production preflight.
- [ ] Font embedding where supported/permitted and explicit outline export; selectable raster size/resolution; physically accurate outputs.
- [ ] Separate printable artwork from cut/score/stitch/engrave/guide roles in the model and exports; configurable production overlays and packaging/textile constraints.

### F. Advanced physical integration — specification Phase 5

Current progress: [independent shared artwork and the clock study](linked-artwork.md) now support same-project source sheets, flat physical faces, actual-size/proportional fitting, immutable source-only persistence, scoped rendering, native source editing, and physically clipped exports. Clock and linked-sleeve workflows are validated; the complete integration and demonstration requirements below remain open.

- [ ] Independent artwork assets referenced by 3D product surfaces with selective resource invalidation and persistent links.
- [ ] Pattern-aware placement, complex dielines, panel continuity, surface projections, and geometry-change review warnings.
- [ ] Dedicated embroidery artwork and cutting/engraving preparation, shared collection assets, material-aware previews, and production packets.
- [ ] Complete all four demonstration projects: clock dial, folding package, apparel graphic/patch, and instruction booklet.

## Acceptance and evidence

The 15-step workflow in specification section 19 is mandatory: exact 8 × 10 inch frame; installed typeface; detailed typography and supported font features; pair spacing; editable vector nodes; precise layout; nested groups; appearance and masks; variants; editable outlines; linked physical surface; live 3D updates; accurate exports; and intact save/close/reopen relationships.

Every checkpoint also requires deterministic MCP access to the same native operations, meaningful undo behavior, round-trip persistence, and appropriate validation. Measure ordinary operations on hundreds of elements, keep idle rendering demand-driven, and test demonstrations through the native UI. Do not label the expanded goal complete while these acceptance requirements remain unfinished.

See [validation notes](validation.md) for measured results and current limitations. Speculative and unavailable hardware checks must remain clearly identified.

## Queued next feature push

The [Textiles, Apparel & Merchandise brief](textiles-apparel-merchandise-spec.md) is recorded as the next feature push. Its lead demo is a **NASA-themed bomber jacket with custom patches, sewn-in tags, embroidery, and related garment details**, as directed by the user. See the [queued demo and development sequence](next-feature-push.md).

This new textile push has not started. The user requested recording it for later; it does not replace the active 2D/3D implementation work or expand the current completion checklist into the entire textile roadmap.
