# FORM

A native Mac creative environment for designing and making physical things.

**Project status:** [What works, what remains, and the current development state](docs/project-status.md) — updated October 26, 2026.

Explore typography, notes, references, and graphics on a freeform 2D Canvas, connected to a continuous 3D Table for physical objects and materials. Use either surface alone, side by side, or with Canvas in a separate window. Start with the thing you want to make, then work directly with its dimensions, construction, and appearance.

**Version 0.1 foundation:** A working native application with persistent projects, parametric objects, linked artwork, production exports, local Orca slicing, and a local MCP interface. **Codex handles the creative conversation; FORM makes no external AI model calls.**

The next governing document is the [2D Design, Typography & Vector Editing specification](docs/2d-design-typography-vector-spec.md). Its professional editing requirements expand the [implementation roadmap](docs/implementation-goal.md); the checklist distinguishes shipped foundations from remaining work.

**Textile feature scope:** [Textiles, Apparel & Merchandise](docs/textiles-apparel-merchandise-spec.md), led by a NASA-themed bomber jacket with custom patches, sewn-in tags, and embroidery. The [demo brief and sequence](docs/next-feature-push.md) guide the remaining implementation alongside the remaining 2D/3D work.

## Build and open

Requires macOS 14 or later and Xcode 16 or later with the Swift 6 toolchain. No external Swift packages or API keys are required. The app includes pinned Clipper2 geometry source under Boost 1.0 and Mapbox Earcut source under ISC; see [third-party geometry](docs/third-party-geometry.md).

```sh
bash scripts/build.sh release
open build/FORM.app
```

For a faster development build, use `bash scripts/build.sh`. The script creates an ad hoc signed app bundle and includes the MCP executable. You can also open `Package.swift` in Xcode. The app has not been notarized for public distribution.

## In the studio

- **Home:** Saved project previews, search, blank projects, and editable starting studies. Featured cards start AFFINITIES, Cloth studies, or the merchandise collection; All studies and File → New from Study expose the full set. [Technical Canvas previews](docs/home-technical-preview.md) improve thin sewing contours for display while preserving source dimensions and cached files.
- **AFFINITIES:** A complete editable 8 × 10 composition with rich typography, a masked Bézier landscape, an independent outlined alternate, and linked oak/graphite editions. It opens the source in split view. See the [15-step design workflow](docs/design-acceptance.md).
- **The Table:** A continuous Metal-backed 3D workspace with physical scale, soft shadows, image references, material swatches, selection, movement, grouping, duplication, and persistent camera state.
- **Connected Canvas:** Type, draw, or place images without an artboard, including negative coordinates. Drag artwork onto or off a physical region to update its 3D face with shared Undo. Resizable split and separate-window layouts keep one editor and shared project state. See [Canvas and Table](docs/design-surfaces.md).
- **Textile foundation:** Dimensioned flight-bomber blanks, garment-relative patches and sewn labels, shared editable artwork, two NASA-themed colorways, and editable Studio fabric specifications/inventory. The [ORBITAL study](docs/textile-foundation.md) is a concept blank and decoration workflow; the broader garment-pattern, cloth-simulation, and production-sew-out requirements remain unfinished.
- **Merchandise blanks:** Dimensioned tee, curved-front cap and canvas tote, bounded decoration regions, conforming direct artwork, back display, shared sources and variants. See [physical regions and supported processes](docs/merchandise-blanks.md).
- **Fabric repeats:** Editable artwork tiles, straight/half-drop/brick/mirror repeats, physical scale and spacing, independent colorways, native yardage preview, bomber fabric mapping, and actual-size SVG/PDF/PNG output. See [physical fabric designs](docs/fabric-patterns.md).
- **Language-aware typography:** Document and character languages, localized case treatment, actual installed hyphenation dictionaries, and minimum word/prefix/suffix limits. Native editing and production output preserve the source words. See [paragraph language](docs/paragraph-language.md).
- **Structured lists:** Source-preserving bullets and decimal lists, stable items, nesting, continuation/restart, native Return/Tab editing, and matching physical output. See [paragraph lists](docs/paragraph-lists.md).
- **Sewing patterns:** Editable straight, supported curved/concave and holed pieces; physical allowances, cut quantities, grain/fold guides, V-notches and guarded seam identities. Tote and rounded-pouch studies include actual-size preview/export. See [sewing patterns](docs/sewing-patterns.md) and [curved geometry](docs/curved-sewing-patterns.md).
- **Physical proof review:** Vector PDFKit views for sewing patterns and material layouts, direct mouse pan, sharp zoom, retained viewports and export-DPI independence. See [physical document review](docs/physical-document-review.md).
- **Publications:** Linked rich-text stories, ordered physical pages, baseline grids, overflow/preflight, and native or outlined multipage PDF. The ORBITAL field-guide study is editable across four columns. See [publications](docs/publications.md).
- **Material cutting layouts:** Explicit stock width, grain/fold rules, cut copies, deterministic nesting, manual placement, physical fabric phase, consumption and declared-rate estimates, and actual-size output. See [cutting layouts](docs/cutting-layouts.md).
- **Embroidery and production:** Regenerable running/satin/fill commands, real underlay/ties, physical 3D stitch surfaces, Studio thread stock, declared equipment checks, immutable revision-linked jobs and review packets. See [embroidery process](docs/embroidery-process.md) and [production jobs](docs/textile-production-jobs.md).
- **Color-managed PDF:** Portable ICC assignments and actual ColorSync output conversion preserve physical page boxes. Declared CMYK and named spots use explicit production PDF output for the supported opaque-vector subset. See [color management](docs/color-management.md).
- **Cloth studies:** Physical draping and seamed-panel previews with pins, contacts, fixed artwork coordinates and attached labels. Run/Stop/Step/Reset is transient; source settings share Undo. These bounded studies do not establish calibrated garment fit. See [cloth simulation](docs/cloth-simulation-foundation.md).
- **Font library:** Search and preview actual installed faces, save face favorites/recents, inspect missing assignments and intentionally replace a face throughout a document with one Undo. Original words, features, axes and exact glyph choices remain recorded. See [document fonts](docs/font-library.md).
- **Contextual controls:** Floating native parameter and material inspectors. Focus or isolate a selection without leaving the canvas.
- **Editable constructions:** Clocks, paper stacks, booklets, folding sleeves, lamps, hollow vessels, boxes, cylinders, extruded profiles, and independent artwork sheets. Custom agent-defined recipes get the same native controls.
- **Shared artwork:** Independent sheets can drive multiple physical faces. Actual-size or proportional fitting preserves the source; native source editing, detachment, iterations, and deletion have shared undo. Try the [linked clock demonstration](docs/linked-artwork.md).
- **Reusable components:** One editable emblem can drive multiple layouts and physical products. Instances retain their own size, color/text overrides, and transforms; detachment preserves ordinary editable artwork. See the [STRATA identity workflow](docs/reusable-components.md).
- **Shared colors:** Named sRGB palettes link fills, strokes, shadows, gradient stops, selected characters, frame backgrounds, and component overrides across layouts and physical products. Editing a swatch updates its uses; detachment or deletion preserves current colors. See the [CHROMA palette workflow](docs/shared-swatches.md).
- **Editable appearance:** Layer/group opacity, sixteen blend modes, Gaussian blur, drop shadows, explicit group isolation, and shared shadow colors. The canvas, linked products, and physical exports preserve their appearance. See the [UMBRA study](docs/artwork-appearance.md).
- **Native artwork canvas:** Multiple physical frames, rulers/guides/grid/snapping, nested layers, exact transforms, Bézier paths, compound holes, cross-object endpoint joining, gradients, strokes, masks, and live 3D face updates. [Live boolean groups and Divide](docs/live-booleans.md) retain editable operands, support operation changes/release/flatten, and update linked product faces. A folding sleeve exposes its unfolded cut/score dieline.
- **Vector paint:** Direct gradient-stop and axis editing, full stroke controls with inside/outside alignment, fill-preserving stroke outlines, and explicit nested-mask editing. See the [PRISM workflow](docs/paint-gradients-masks.md).
- **Production inks:** Profile-pinned CMYK and named-spot palette declarations, explicit RGB previews, genuine ICCBased/Separation composite PDF and normal-knockout digital ink maps for an opaque vector subset. Native/MCP and independent PDF checks pass; see [production inks](docs/production-inks.md).
- **Production roles:** Explicit print, cut, score, stitch, engrave, and guide intent; inherited manufacturing groups; local overlay visibility; separate SVG role layers and actual-size PDF pages from the same source. See [production roles](docs/production-roles.md).
- **Regenerable embroidery:** Actual running, constant-width satin, and clipped compound-fill needle commands from editable artwork; dedicated native stitch/travel preview and playback, actual command-derived 3D thread surfaces, opt-in underlay/backtracking locks, thread/region controls, hoop preflight, physical SVG/JSON and DST with ordered thread sidecars. Independently decoded with Pyembroidery; no hardware calls or verified sew-out claim. See [embroidery](docs/embroidery.md).
- **HTV / DTF preparation:** Actual-size knockout cut SVGs or transparent RGBA/profiled process files, explicit mirror/white/material review, and immutable source-linked packets with native Undo. See [decoration preparation](docs/decoration-preparation.md).
- **Collection BOMs:** Explicit product runs, attached details once, source-based material allocation, portable stock, declared currency subtotals and immutable technical packets. See [collection production](docs/collection-production.md).
- **Textile production records:** Studio thread inventory and declared embroidery equipment, portable thread assignment, immutable revision-linked jobs, measured needle paths versus explicit cost/usage assumptions, user sample/quality history, and local PDF/JSON/DST/SVG review packets. No stock deduction or machine operations. See [production jobs](docs/textile-production-jobs.md).
- **Image editing:** Original files, aspect-aware placement, crop panning/zoom, numeric crop bounds, brightness/contrast/saturation, replacement that retains layout, drag/drop, and effective physical DPI. See the [LUMEN collection](docs/image-editing.md).
- **Editable SVG import:** File → Import SVG Artwork (`⇧⌘I`) reviews native paths, groups, text, gradients, clips, and embedded images before creating a physical frame or adding to an existing surface. Originals stay in the project; unsupported features require explicit review. See the [SVG import guide](docs/svg-import.md).
- **Optical typography:** Explicit Automatic/Explicit/Off sizing in source points, source-preserving styles/glyphs, precise physical SVG fallback, and focused numeric Up/Down/Shift/Undo. See [optical sizing and precision](docs/optical-sizing.md).
- **Typography:** Reusable text styles with local overrides, independent character/paragraph links, installed fonts, native selected-character editing, reversible Unicode case, paragraph tabs/hyphenation, font kerning, OpenType features, variable axes, real alternate-glyph selection, Core Text shaping, and editable glyph outlines. See [FOLIO and text styles](docs/reusable-text-styles.md), [FOUNDRY and font features](docs/font-features.md), [AVENUE and kerning](docs/kerning.md), [LEDGER and paragraph composition](docs/paragraph-composition.md), [VERSO and text case](docs/text-case.md), [QUILL and alternate glyphs](docs/glyphs.md), the [character position and small-cap guide](docs/character-forms.md), and the [editor guide](docs/2d-editor.md).
- **Iterations and variants:** Independent design iterations or linked parameter/artwork variants with their own materials and placement.
- **Studio Library:** Persistent materials and equipment profiles, separate from individual projects.
- **Print preparation:** `⌘P` opens a dedicated physical print bed with object/component selection, orientation, scale, filament, layer height, walls, infill, supports, brim, and actual sliced layer previews. Project switches cancel local work and clear stale previews; settings and mesh share Undo/Redo.
- **Filaments and local printers:** Studio settings preserve spool profiles, colors, temperatures, flow, density, cost, and remaining inventory. P1S connection settings use Keychain for the LAN code and a read-only TLS/MQTT status adapter. Sending or starting prints is disabled.
- **Saved Studio shots:** Named camera compositions with exact subjects, lighting/surfaces, output pixels, reference framing and PNG + render-record folders; capture/update share Undo. See [Studio shots](docs/studio-shots.md).
- **Rendering and making:** Studio backgrounds, camera framing, 3000 × 2000 PNG, physically sized PDF artwork, millimeter SVG dielines, and component/material JSON.
- **Project knowledge:** Editable design decisions and open questions, saved activity history, optional Codex conversation references, and undo/redo across native and MCP edits.

Projects autosave to `~/Library/Application Support/FORM` as modular `.form` packages. Imported assets travel with the project. Use **Save a Copy** to take a project elsewhere.

## Create with Codex

Keep FORM open and register its bundled MCP server:

```sh
codex mcp add form -- "$PWD/build/FORM.app/Contents/MacOS/form-mcp"
```

Then describe an object in Codex:

> Create an orange table lamp, about 350 mm tall, with editable shade diameter, shade height, stem diameter, and base width. Place a sage variant beside it.

Tool discovery exposes the current native tools for project creation, recipe discovery, custom parametric recipes, object edits, artwork, fonts, reusable text styles, vector operations, components, shared palettes, variants, grouping, camera control, project notes, exports, local slicing, filament profiles, printer status, atomic batches, and undo/redo. Changes appear in the native app and remain editable without another generation request.

See [Create with Codex](docs/mcp.md) for setup, schemas, a custom object example, and direct CLI invocation.

## Optional OrcaSlicer engine

The preparation UI is native SwiftUI/AppKit. Slicing runs the official OrcaSlicer app as a local subprocess. Install the verified engine separately:

```sh
bash scripts/install-orca.sh
```

This downloads official OrcaSlicer **2.4.2**, verifies its pinned SHA-256, and extracts it under `.local/engines`. Alternatively select an installed official `OrcaSlicer.app` under **Studio Library → Filaments & 3D printing → Slicing engine**. The binary is not committed or redistributed with FORM.

See [Printing architecture, setup, and research](docs/printing.md) for profiles, license boundaries, P1S connection setup, and verified capabilities. Local slicing produces STL, G-code, and sliced 3MF files; no printer is contacted by slicing.

## Navigation

| Action | Control |
| --- | --- |
| Select / extend selection | Click / Shift-click |
| Orbit | Drag in **Orbit** mode (`O`); the scene follows the pointer |
| Pan the view | **Shift + drag** in Orbit mode |
| Move an object or group | **Move** mode (`V`), then drag the selection; Shift snaps to 10 mm |
| Zoom | Scroll up to zoom in, down to zoom out; pinch also works |
| Focus / isolate | `F` / `I`, or floating inspector buttons |
| Perspective / top / front | `1` / `2` / `3` |
| Fit all | `⌘0` |
| Duplicate iteration / linked variant | `⌘D` / `⇧⌘D` |
| Group | `⌘G` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |
| Save / save a copy | `⌘S` / `⇧⌘S` |
| Print preparation | `⌘P` |
| Return to Home | `⇧⌘H` |

The Table starts in Orbit mode. Horizontal rotation is unlimited around a fixed vertical axis; vertical movement tilts between Top and Bottom without banking or flipping. Shift-drag pans in screen space. Perspective, Top, and Front reset orientation and frame the **whole project** every time, including when an object was selected or isolated. Focus frames the selection. There are no alternate Space/Option pan bindings or navigation-direction settings. The Table, Studio, live object inset, and print preview share this behavior. See the [camera control contract and validation](docs/camera-navigation.md).

## Develop and validate

```sh
bash scripts/test.sh
python3 scripts/smoke_mcp.py  # Requires the running app; creates a validation project
python3 scripts/smoke_artwork.py # Typography/vector composition and physical exports
python3 scripts/smoke_svg.py # Editable import, source preservation, fidelity review, physical exports
python3 scripts/smoke_compound.py # Compound paths, cross-object joins, 600-node saved edits
python3 scripts/smoke_boolean.py # Live operands, Divide, linked faces, atomic batches, saved edits
python3 scripts/smoke_components.py # Shared marks, overrides, detach, 200 linked placements
python3 scripts/smoke_swatches.py # Shared colors, rich text, linked products, 600-element palette edits
python3 scripts/smoke_appearance.py # Blur, shadows, blending, linked outputs, 100 effect placements
python3 scripts/smoke_paint.py # Gradients, strokes, nested masks, physical outputs, 200-element saved edits
python3 scripts/smoke_font_features.py # Independent selectors, rich typography, linked faces, schema 11, 200-text saved edits
python3 scripts/smoke_case.py # Reversible Unicode case, source preservation, native shaping, linked faces
python3 scripts/smoke_glyphs.py # Actual font glyphs, editable QUILL wordmark/dial, recoverable paths, schema 15
python3 scripts/smoke_paragraph_language.py # Document/character languages, actual dictionaries, source preservation, schema 20
python3 scripts/smoke_fabric_patterns.py # Physical fabric repeats, colorways, linked tiles and yardage exports, schema 21
python3 scripts/smoke_production_roles.py # Separate print/cut/score/stitch/engrave outputs, shared masks, schema 22
python3 scripts/smoke_paragraph_lists.py # Structured lists, native-compositor outputs, schema 23
python3 scripts/smoke_sewing_patterns.py # Editable pieces, seams, actual-size cutting output, schema 24
.local/validation/embroidery-reader-venv/bin/python scripts/smoke_embroidery.py # Actual stitches, independent DST decoding, schema 25
.local/validation/embroidery-reader-venv/bin/python scripts/smoke_embroidery_surface.py # Actual 3D thread surface, underlay/ties, schema 28
.local/validation/embroidery-reader-venv/bin/python scripts/smoke_production_jobs.py # Stock snapshots, immutable jobs/BOM/packets, schema 29
python3 scripts/smoke_paragraphs.py # Saved tabs, real hyphenation, paragraph patches, schema 14, linked faces
python3 scripts/smoke_kerning.py # Font metrics, independent spacing, legacy preservation, schema 13, linked faces
python3 scripts/smoke_text_styles.py # Reusable styles, local overrides, character/paragraph links, schema 12, linked faces
python3 scripts/smoke_images.py # Original images, crop/adjustments, physical DPI, replacement, 100-image saved edits
python3 scripts/smoke_paths.py # Curve editing, transformed type, and linked variants
python3 scripts/smoke_clock.py --slice # Shared dial, immutable source links, physical exports, local Orca
python3 scripts/benchmark_artwork.py # 600-element native canvas performance
python3 scripts/smoke_production_inks.py # Declared CMYK/spot intents, knockout maps, guarded physical PDF, schema35
python3 scripts/smoke_optical_typography.py # Disposable library; optical modes, source/glyph/style/story Undo and physical output
python3 scripts/smoke_studio_shots.py # Disposable library; saved compositions, exact pixels, provenance and legacy output

python3 scripts/smoke_collections.py # Disposable library; explicit runs/BOM/stock, precise estimates, immutable packets and saved source deletion
python3 scripts/smoke_decoration_preparation.py # Disposable library only; HTV/DTF physical files and immutable packets
python3 scripts/smoke_print_lifecycle.py # Project scope, local-worker cancellation, unseen mesh dimensions, Undo/Redo
python3 scripts/smoke_print.py # Optional engine; local cube and hollow-shade slices
```

Use an isolated library while testing:

```sh
FORM_LIBRARY_PATH="$PWD/.local/Library" build/FORM.app/Contents/MacOS/FORM
```

`FORM_SOCKET_PATH` can isolate multiple development instances. The native view redraws on demand, geometry updates are scoped to changed objects, and geometry/texture caches are bounded.

This build has a native typography/vector editor and procedural construction system. The full professional 2D specification, general CAD booleans/import, collaboration, embedded agent UI, and photorealistic path tracing remain unfinished. The expanded goal tracks the requested 2D capabilities through their demonstration and acceptance criteria. Live P1S status still requires verification with the physical printer's connection details.

## Documentation

- [Initial product brief · Version 0.1](docs/product-brief.md)
- [2D Design, Typography & Vector Editing · guiding specification](docs/2d-design-typography-vector-spec.md)
- [Native artwork editor · controls, MCP, and remaining work](docs/2d-editor.md)
- [Production inks · CMYK, named spots and physical ink maps](docs/production-inks.md)
- [HTV / DTF decoration preparation and immutable handoff packets](docs/decoration-preparation.md)
- [Production roles · separate print and manufacturing geometry](docs/production-roles.md)
- [Physical fabric repeat designs](docs/fabric-patterns.md)
- [Paragraph language and hyphenation](docs/paragraph-language.md)
- [Paragraph tabs, hyphenation, and LEDGER](docs/paragraph-composition.md)
- [Non-destructive text case and VERSO](docs/text-case.md)
- [Alternate glyphs, the QUILL wordmark, and a 100 mm dial](docs/glyphs.md)
- [Editable SVG import and ORBIT illustration](docs/svg-import.md)
- [Precise paths and transformed native text](docs/path-editing.md)
- [Shared artwork and the clock study](docs/linked-artwork.md)
- [Shared colors and the CHROMA collection](docs/shared-swatches.md)
- [Editable appearance and the UMBRA study](docs/artwork-appearance.md)
- [Vector paint and the PRISM collection](docs/paint-gradients-masks.md)
- [Image editing and the LUMEN collection](docs/image-editing.md)
- [Textiles, Apparel & Merchandise · next feature specification](docs/textiles-apparel-merchandise-spec.md)
- [Active feature push · NASA bomber jacket demonstration](docs/next-feature-push.md)
- [Expanded implementation goal and completion checklist](docs/implementation-goal.md)
- [Implementation architecture and boundaries](docs/architecture.md)
- [MCP setup and custom object recipes](docs/mcp.md)
- [Orca slicing, filament library, and local P1S setup](docs/printing.md)
- [Validation notes](docs/validation.md)

The [publication workflow](docs/publications.md) adds one editable rich story across linked text frames, ordered physical pages, opt-in baseline grids, and a three-page ORBITAL instruction-booklet study with native and outlined multipage PDF. The broader publication specification remains active.

The [font library](docs/font-library.md) provides explicit installed-face previews/search, persistent favorites/recents, complete document font usage, and reviewed replacement that preserves original words, features, variable axes, rich ranges and exact glyph metadata.

[Cloth studies](docs/cloth-simulation-foundation.md) add real bounded drape and paired seam previews, physical material coordinates, native/MCP runtime controls and saved initial settings. The NASA materials-lab template demonstrates the foundation; calibrated fit, self-collision and full garment assembly remain future work. Open cloth is explicitly rejected for slicing.

[Tiled sewing patterns](docs/tiled-sewing-patterns.md) export A4, Letter and custom PDF sheets at actual size, with calibration and assembly marks outside the drawing. Native saved sheet options, exact Undo, packaged physical exports and actual app reopen pass in the 697-test integration. No printer is contacted.

[HTV/DTF preparation](docs/decoration-preparation.md) adds physical cut/transfer files and immutable source-linked handoff packets. The updated [Flight bomber study](docs/flight-bomber-showcase.md) starts with five real stitch definitions and underlay. Native capture/export/Undo/reopen and independent files pass in the 719-test integration. Studio retains its presentation mode and lighting while orbiting, panning and zooming; camera bindings are unchanged.

[Pattern-derived cloth assembly](docs/pattern-assembly-cloth.md) uses original curved sewing contours, guarded physical seam samples, explicit panel poses/supports and declared fabric mass. The NASA rounded-pouch study keeps construction geometry editable and maps only printable decoration at its original physical scale. Derived meshes and motion are transient; this is an uncalibrated open-surface study without self-collision, inferred construction or verified fit. New drape recipes start on the support tangent plane while saved initial meshes remain intact. The 767-test optimized integration, packaged physical audit and native Run/Stop/Reset, active-field Apply/Undo, material-label movement, camera and process-reopen checks pass.

[Garment blocks and grading](docs/garment-blocks.md) add an original gathered-skirt construction with editable measurements, size rows, stable source propagation and physical casing/hem guides. Native focused edits, one-step Undo, source-safe revisions/transfers, independently measured exports and actual app reopen pass in the 790-test integration. General garment development and verified fit remain in the active goal.
