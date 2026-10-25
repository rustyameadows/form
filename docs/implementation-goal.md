# FORM implementation goal

Status: **Active**. Expanded October 25, 2026 to include the freeform Canvas/Table relationship, the complete Textiles, Apparel & Merchandise brief, and the complete [2D Design, Typography & Vector Editing specification](2d-design-typography-vector-spec.md), alongside the [original product brief](product-brief.md), the supplied interface sketches, and local 3D-print preparation.

## Objective

Deliver a capable, polished native Mac creative environment for 3D physical design, professional 2D graphic composition, and textiles/apparel/soft goods. A continuous Table, editable parametric objects, independent and linked artwork, typography, vector geometry, persistent projects, production exports, Studio materials/filaments, and an Orca-powered print workspace must work together. Codex operates the same deterministic editing commands through local MCP; FORM does not call external AI models. Printer setup and status are permitted; sending or starting prints remains disabled under the user's explicit instruction.

Canvas and Table are connected peer design surfaces. The freeform 2D Canvas holds loose typography, notes, references, images, and sketches without first requiring a physical artboard. Finite artboards and object-face regions live within that canvas and map to 3D products; moving/editing artwork in those regions updates the corresponding physical surfaces. Canvas-only, Table-only, split, and separate-window arrangements share one project and Undo history. See [design surfaces](design-surfaces.md).

The [Textiles, Apparel & Merchandise brief](textiles-apparel-merchandise-spec.md) is now active implementation scope, not a queued record. The first showcase is the NASA-themed bomber with custom patches, sewn-in tags, embroidery, editable fabric/placement/colorways, and production information. All staged brief requirements remain in the completion scope; unsupported cloth physics or machine stitch output must not be presented as implemented.

The new specification is a governing product document, not a claim that its features already exist. Its complete requirements remain in scope. Its explicit later-stage capabilities retain their staged sequence. Completion requires working native interactions and demonstrated output, rather than controls that only expose stored values.

The goal service currently permits status changes but cannot rewrite the text of an active objective. This file records the expanded objective and completion requirements while that goal stays active.

## Delivery checkpoints

### A. Native 3D studio and fabrication foundation

- [x] Continuous Metal-backed Table; native title bar; contextual inspectors; camera, focus, isolation, selection, movement, grouping, variants, and iterations.
- [x] Validate researched constrained, world-up orbit: horizontal drags change yaw only, vertical drags change pitch only, no accumulated roll, immediate leveling of earlier banked views, fixed Shift-pan/zoom bindings, and reliable whole-project named views. Native mouse runs and core/AppKit tests are recorded in validation notes; CUA cannot hold Shift through its drag API, so Shift-pan uses direct AppKit event evidence.
- [x] Home previews of saved scenes; modular packages; autosave; undo/redo; imported assets; Studio materials and equipment.
- [x] Parametric constructions and custom recipes; linked artwork; PDF/SVG/PNG/component exports; local MCP registration and shared command engine.
- [x] Dedicated Print workspace with physical P1S bed, component selection, orientation, scale, filament choice, slicing options, layer preview, and local outputs.
- [x] Persistent Studio filament library; local printer profiles; Keychain credential storage; read-only TLS/MQTT status adapter.
- [x] Real official OrcaSlicer 2.4.2 slice yielding STL, G-code, sliced 3MF, layer preview, and estimates; no printer commands sent.
- [ ] Verify the physical P1S status connection when its IP, serial, and locally entered access code are available.
- [x] Clear an open Print preview on successful project switches, cancel its active local slice, reject late results, and synchronize settings/mesh through Undo/Redo. Direct app tests, real Orca workflows, and native computer use verify the lifecycle.
- [ ] Complete the remaining original-brief physical design workflows; evaluate the 3D environment with the new linked artwork demonstrations.

### B. Credible professional 2D canvas — specification Phase 1

**Credible-canvas checkpoint complete.** The seven foundation items below are demonstrated by the existing focused native/MCP workflows and the complete [AFFINITIES 15-step design workflow](design-acceptance.md), with [recorded evidence](evidence/design-acceptance.json), exact native Undo and actual app-relaunch/reopen. The 680-test integration passes. [Editor capabilities and gaps](2d-editor.md) and [validation evidence](validation.md) retain the limits; the complete typography, vector, publication and physical-integration requirements in later phases remain active.

- [x] Independent artwork documents and multiple physical artboards/pages; unit conversion for mm, cm, inches, and points; presets and exact custom dimensions.
- [x] Smooth pan, pinch/keyboard zoom, sharp rendering, rulers, numeric/draggable guides, grid, smart snapping, and configurable nudges.
- [x] Selection, multiple selection, resize, rotate, flip, aspect locking, transform origin, alignment, distribution, matching size, and exact transforms.
- [x] Layer naming, visibility, locking, ordering, nested grouping, group transforms, and editing within a group.
- [x] Select/direct-select, text, shapes, pen/Bézier, line/polygon/star, image placement, pan/zoom, eyedropper, and frame tools with conventional shortcuts.
- [x] Solid fill, stroke controls, basic path editing, native installed font discovery, point and area text, font/style/size/leading/tracking/alignment, and live surface updates.
- [x] Undo/redo, autosave/reopen, native text input, accessible controls, SVG/PDF/PNG output, and a typography-heavy label or dial completed directly in FORM.

### C. Deep typography — specification Phase 2

Current progress: [FOUNDRY and independent font features](font-features.md) now validate simultaneous Common/Additional/Historical ligatures, explicit on/off/default states, exclusive numeral choices, selected-character feature edits, variable-axis coexistence, native assignment preservation, editable outlines, and schema-11 persistence. [FOLIO and reusable text styles](reusable-text-styles.md) add shared typography, independent paragraph inheritance, explicit local overrides, and native/MCP creation, redefinition, reset, detachment, and schema-12 persistence. [AVENUE and independent spacing](kerning.md) add real font metrics, disabled kerning, independent tracking/manual pairs, native character controls, and schema-13 persistence. [LEDGER and paragraph composition](paragraph-composition.md) add saved tab stops, repeating intervals, actual TextKit hyphenation, selected-paragraph commands, and schema-14 persistence. [QUILL and alternate glyphs](glyphs.md) add a real font repertoire/palette, source-preserving choices, variable-face identity, schema-15 persistence, editable converted nodes, and a wordmark/100 mm dial demonstration. Advanced composition and the remaining typography acceptance requirements below stay in scope.

- [x] Searchable previewing font browser with families/faces, favorites, recents, explicit missing-font handling, and preserved assignments. Native/MCP replacement, exact Undo and the 620-test integration are recorded in [font library](font-library.md).
- [ ] Core Text shaping; all section 4.2 text/paragraph properties; mixed rich text and selected-character editing; point/area text reflow and overflow indicators.
- [ ] Supported OpenType feature discovery, ligatures/alternates/sets, numeral treatments, fractions, caps, contextual/localized forms, and alternate glyph selection.
- [ ] Real variable-font axes/ranges and optical sizing; baseline shifts, superscript/subscript, and character-level features.
- [x] Explicit font-metrics/None kerning with independent tracking, word spacing, and manual pairs; character-level native/MCP editing, style inheritance, portable outlines, and legacy layout preservation. See [AVENUE and spacing](kerning.md).
- [x] Reusable paragraph/text styles with persistent local overrides, independent character/paragraph relationships, creation/redefinition/reset/detachment/deletion, and shared native/MCP Undo. See [FOLIO and text styles](reusable-text-styles.md).
- [x] Saved left/center/right/decimal tab stops and repeating intervals; native selected-paragraph controls/MCP patches; real hyphenated native/physical/export composition, recoverable source, style inheritance, and exact Undo. See [LEDGER](paragraph-composition.md).
- [x] Document and character language, inherited defaults, Natural/LTR/RTL direction, actual installed language dictionaries, and minimum word/prefix/suffix hyphenation limits; locale-aware case/source preservation and matching physical outputs. See [paragraph language](paragraph-language.md).
- [x] Source-preserving structured bullets/decimal lists, stable item identities, nesting, continuation/restart, native Return/Tab and Undo, and matching physical outputs. See [paragraph lists](paragraph-lists.md).
- [ ] Advanced text frames, including linked stories and publication layouts.
- [x] Non-destructive mixed-character Original/Uppercase/Lowercase treatment, source/display UTF-16 mapping through expansions, native controls and input/Undo, rich fonts/colors/styles, and matching physical exports. See [VERSO](text-case.md).
- [x] Native alternate-glyph palette and searchable real font repertoire; source/rich-style preservation, variable-face identity, shared native/MCP edits and Undo, schema-15 persistence, and validated physical outputs. See [QUILL](glyphs.md).
- [ ] Convert shaped text to ordinary editable outlines while preserving glyph positioning, variations, ligatures, and a recoverable editable source.
- [x] Demonstrate a refined wordmark and typographic clock dial with editable converted glyphs: QUILL combines original/alternate/engraved Q forms, editable source text, ordinary converted Bézier nodes, linked oak products, and a physically sized 100 mm dial. See [the workflow](glyphs.md) and [validation](validation.md).

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
- [x] Separate print/cut/score/stitch/engrave/guide intent, inherited manufacturing groups, native/MCP assignment and Undo, local role-overlay visibility, role-filtered SVG layers and physically sized PDF pages, and explicit guide-reference output. See [production roles](production-roles.md).
- [ ] Complete the remaining bleed/trim/safe-area, registration/material/print-limit overlays, machine-specific production processing, and packaging/textile constraints.

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

### G. Freeform Canvas and Table relationship

- [x] Loose 2D typography, notes, references, images, and vectors on an expanding canvas without a required physical frame.
- [x] Movable finite artboards and mapped object-face regions; drag artwork into/out of a region with correct coordinates, live 3D updates, and one Undo.
- [x] Canvas-only, Table-only, resizable split, and a separate canvas window sharing project state, selections, focus-aware commands, and camera/editor ownership.
- [x] Preserve source links, styles/assets, project switches, save/reopen, physical exports, and large-canvas performance; validate through native UI and MCP. The 501-element packaged workflow measured 48 ms median edits; native drag, text, split, window, and origin checks are recorded in validation notes.

### H. Textiles, apparel, fabric, and merchandise — active

The [ORBITAL textile foundation](textile-foundation.md) now implements shaped parametric bomber blanks, attached decorations, shared artwork, two colorways, editable fabric specifications/inventory, and physical patch/label exports. Packaged MCP and native checks pass. The complete requirements below remain open; this foundation is not a finished clothing system.

[Physical fabric repeats](fabric-patterns.md) now add linked editable tiles, four repeat modes, millimeter scale/spacing/offset/rotation, independent colorways, native yardage controls, physical bomber mapping, and SVG/PDF/PNG/JPEG outputs. Native and packaged MCP checks pass, including source invalidation and zero geometry rebuilds for output-only changes. Engineered prints, cross-seam pattern-piece continuity, cutting, fit, and cloth behavior remain unfinished.

- [ ] Decorated garment blanks, real-scale regions, persistent fabric specifications, native material controls, linked artwork and garment-relative placement, variants, and collection editing.
- [ ] NASA bomber demonstration: convincing garment construction and fabric, custom independent patches, sewn-in labels, direct embroidery regions, shared editable source art, two colorways, and polished hero/detail views.
- [x] Bounded regenerable running/constant-width satin/scanline-fill stitch programs, editable native regions/threads, actual-command preview/playback, hoop preflight, physical SVG/JSON/DST, ordered thread sidecars, independent DST-reader verification, and shared MCP/Undo/persistence. See [embroidery](embroidery.md); this does not establish verified physical sew-out quality.
- [x] Command-derived physical 3D thread surfaces, transparent travel/holes, capped diffuse/normal maps, surface-only invalidation, opt-in center-walk/sparse-fill underlay and real backtracking tie stitches, and independent output verification. See [embroidery process and surfaces](embroidery-process.md); fabric compensation, fit, and physical sewing remain outside these bounded algorithms.
- [ ] Complete decoration production: production digitizing/compensation and machine-specific constraints, patch/label construction, DTG/DTF/HTV and separations, manufacturing specs and revision-linked packets.
- [ ] Fabric design: repeat patterns, engineered prints, colorways, pattern-piece-aware mapping, and output at physical dimensions.
- [x] Editable convex straight-sided sewing pieces, real-scale default/per-edge allowances, grain/fold guides, V-notches, cut-copy seam relationships, tote study, native preview, physical exports, shared Undo and schema-24 reopen. See [sewing patterns](sewing-patterns.md); general curved garment construction remains unfinished.
- [x] Explicit material stock, deterministic bounded cut-copy nesting, exact contour preflight, manual native placement with shared Undo, grain/fold accounting, physical fabric phase, consumption and declared-rate estimates, and actual-stock SVG/PDF/raster output. See [cutting layouts](cutting-layouts.md); optimal nesting, engineered seam registration and assembled previews remain open.
- [ ] Soft goods: parametric pattern pieces, seam relationships/allowances, cutting/nesting/consumption, assembled previews, instructions, and reusable constructions.
- [x] Supported concave/cubic sewing contours with uniform round allowances, guarded source-edge identities, physical curved notches/seams, hole-aware cutting geometry and an editable measured pouch. Native creation/PDF export/Undo and real packaged checks pass; see [curved sewing patterns](curved-sewing-patterns.md).
- [x] Actual-size A4/Letter/custom tiled sewing-template PDFs with calibration, clean assembly gutters, complete source coverage, saved native/MCP options, exact Undo and process reopen. The 697-test integration and independent physical PDF checks pass; see [tiled sewing patterns](tiled-sewing-patterns.md).
- [x] Bounded physical cloth studies with pins/seams, static analytic contacts, fixed material coordinates and attachments, transient native/MCP runtime, exact source/Undo/reopen boundaries and explicit open-surface print rejection. Predictive fit and full garment assembly remain open.
- [ ] Garment development: blocks, body measurements, sizing/grading, pattern editing, fitting and cloth behavior with clearly stated simulation limits.
- [x] Initial local embroidery production: Studio thread stock/supplier/SKU/cost records, portable assignment, declared hoop/format checks, immutable source-linked jobs, actual needle-length measurements versus explicit BOM/cost assumptions, user sample/quality records, and reviewable PDF/JSON/ZIP packets. See [production jobs](textile-production-jobs.md). No automatic stock deduction, machine telemetry, or verified sew-out claim.
- [ ] Complete integrated production: broader materials/process compatibility, fabric/ink/trim costing, collection-wide BOMs and scheduling, richer purchasing/inventory integration, and remaining full-brief job/sample/quality workflows. Hardware operation remains prohibited.
- [ ] Complete every applicable feature and acceptance requirement in the governing textile brief, not only this condensed checklist; demonstrate roundtrip, native/MCP edits, meaningful Undo, production outputs, and performance.

## Active textile feature push

The [Textiles, Apparel & Merchandise brief](textiles-apparel-merchandise-spec.md) is in active development. Its lead demo is a **NASA-themed bomber jacket with custom patches, sewn-in tags, embroidery, and related garment details**, as directed by the user. See the [demo and development sequence](next-feature-push.md).

The user activated this work on October 25, 2026. It proceeds in parallel with camera fixes and the remaining 2D/3D work. An unavailable P1S status connection does not block unrelated software delivery.

Publication checkpoint: schema26 supplies single-source rich stories, native linked-frame editing/reflow, explicit physical page sequences, optional paragraph baseline grids, overset access/preflight, and actual mixed-size multipage PDF, with the original three-page ORBITAL study. The schema-30 integrated release passes 538 tests and the real packaged publication workflow; actual computer use verifies cross-column typing, exact source/history Undo, page order and cover/reopen. Broader typography and publication requirements remain open. [Supported workflows and remaining publication requirements](publications.md) stay explicit; this does not close the full Phase4 goal.

The integrated font-library checkpoint provides: explicit actual-face search/previews, persistent face favorites/recents with legacy-family migration, document usage/missing/settings reports, intentional one-Undo replacement, and original rich/story/glyph assignment preservation. The real packaged workflow and native face/favorite/replacement controls pass, including a 35-assignment source-preserving change and exact one-Undo recovery. [Behavior and evidence](font-library.md).

The [schema31 cloth foundation](cloth-simulation-foundation.md) adds bounded XPBD distance constraints, physical area masses, pins/seams, static plane/sphere contacts with face penetration checks, actual native surface updates and fixed material coordinates. A NASA materials-lab template supplies a supported drape and two seamed panels. Native/MCP runtime controls share one transient owner and preserve text drafts, project history and camera behavior; source edits are saved/undoable, and open cloth is explicitly rejected for slicing. Predictive fit, self-collision, calibrated fabric mechanics and full garment assembly remain open. The real packaged workflow and native Run/Stop/Reset/Step, active-field settings/Undo, corrected printed UVs and four-direction mouse camera checks pass in the 620-test integration.

### Declared production colors — milestone 35 source checkpoint

[Production inks](production-inks.md) adds portable profile-pinned process CMYK and named spot/tint declarations in the existing shared palette, intentional RGB conversion, one-step native/MCP Undo, explicit production/preflight output and genuine ICCBased/Separation PDF resources. Physical positive ink maps preserve opaque normal knockout, masks and shared glyph outlines, including tint0 and white-alternate inks. Packaged/native integrated acceptance passes, including focused-field process/spot Save, invalid-input rejection, exact Undo and independently read physical PDFs. Phase4 stays open for broader image/gradient/transparency colorants, overprint, trapping, screening, physical matching, safe/registration overlays and certification requirements.
