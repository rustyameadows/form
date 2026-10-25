# FORM

A native Mac creative environment for designing and making physical things.

One continuous Table for objects, artwork, materials, references, and the versions you want to compare. Start with the thing you want to make, then work directly with its dimensions, construction, and appearance.

**Version 0.1 foundation:** A working native application with persistent projects, parametric objects, linked artwork, production exports, local Orca slicing, and a local MCP interface. **Codex handles the creative conversation; FORM makes no external AI model calls.**

The next governing document is the [2D Design, Typography & Vector Editing specification](docs/2d-design-typography-vector-spec.md). Its professional editing requirements expand the [active implementation goal](docs/implementation-goal.md); the checklist distinguishes shipped foundations from remaining work.

**Queued next feature push:** [Textiles, Apparel & Merchandise](docs/textiles-apparel-merchandise-spec.md), led by a NASA-themed bomber jacket with custom patches, sewn-in tags, and embroidery. The [demo brief and sequence](docs/next-feature-push.md) are recorded; textile implementation has not started.

## Build and open

Requires macOS 14 or later and Xcode 16 or later with the Swift 6 toolchain. There are no third-party package dependencies or API keys.

```sh
bash scripts/build.sh release
open build/FORM.app
```

For a faster development build, use `bash scripts/build.sh`. The script creates an ad hoc signed app bundle and includes the MCP executable. You can also open `Package.swift` in Xcode. The app has not been notarized for public distribution.

## In the studio

- **Home:** Saved project previews, search, blank projects, and editable starting studies. Home cards start a clock dial, cyanotype kit, or lamp study; File → New from Study also offers material/form studies.
- **The Table:** A continuous Metal-backed 3D workspace with physical scale, soft shadows, image references, material swatches, selection, movement, grouping, duplication, and persistent camera state.
- **Contextual controls:** Floating native parameter and material inspectors. Focus or isolate a selection without leaving the canvas.
- **Editable constructions:** Clocks, paper stacks, booklets, folding sleeves, lamps, hollow vessels, boxes, cylinders, extruded profiles, and independent artwork sheets. Custom agent-defined recipes get the same native controls.
- **Shared artwork:** Independent sheets can drive multiple physical faces. Actual-size or proportional fitting preserves the source; native source editing, detachment, iterations, and deletion have shared undo. Try the [linked clock demonstration](docs/linked-artwork.md).
- **Reusable components:** One editable emblem can drive multiple layouts and physical products. Instances retain their own size, color/text overrides, and transforms; detachment preserves ordinary editable artwork. See the [STRATA identity workflow](docs/reusable-components.md).
- **Shared colors:** Named sRGB palettes link fills, strokes, shadows, gradient stops, selected characters, frame backgrounds, and component overrides across layouts and physical products. Editing a swatch updates its uses; detachment or deletion preserves current colors. See the [CHROMA palette workflow](docs/shared-swatches.md).
- **Editable appearance:** Layer/group opacity, sixteen blend modes, Gaussian blur, drop shadows, explicit group isolation, and shared shadow colors. The canvas, linked products, and physical exports preserve their appearance. See the [UMBRA study](docs/artwork-appearance.md).
- **Native artwork canvas:** Multiple physical frames, rulers/guides/grid/snapping, nested layers, exact transforms, Bézier paths, compound holes, cross-object endpoint joining, gradients, strokes, masks, and live 3D face updates. [Live boolean groups and Divide](docs/live-booleans.md) retain editable operands, support operation changes/release/flatten, and update linked product faces. A folding sleeve exposes its unfolded cut/score dieline.
- **Vector paint:** Direct gradient-stop and axis editing, full stroke controls with inside/outside alignment, fill-preserving stroke outlines, and explicit nested-mask editing. See the [PRISM workflow](docs/paint-gradients-masks.md).
- **Image editing:** Original files, aspect-aware placement, crop panning/zoom, numeric crop bounds, brightness/contrast/saturation, replacement that retains layout, drag/drop, and effective physical DPI. See the [LUMEN collection](docs/image-editing.md).
- **Editable SVG import:** File → Import SVG Artwork (`⇧⌘I`) reviews native paths, groups, text, gradients, clips, and embedded images before creating a physical frame or adding to an existing surface. Originals stay in the project; unsupported features require explicit review. See the [SVG import guide](docs/svg-import.md).
- **Typography:** Reusable text styles with local overrides, independent character/paragraph links, installed fonts, native selected-character editing, reversible Unicode case, paragraph tabs/hyphenation, font kerning, OpenType features, variable axes, Core Text shaping, and editable glyph outlines. See [FOLIO and text styles](docs/reusable-text-styles.md), [FOUNDRY and font features](docs/font-features.md), [AVENUE and kerning](docs/kerning.md), [LEDGER and paragraph composition](docs/paragraph-composition.md), [VERSO and text case](docs/text-case.md), and the [editor guide](docs/2d-editor.md).
- **Iterations and variants:** Independent design iterations or linked parameter/artwork variants with their own materials and placement.
- **Studio Library:** Persistent materials and equipment profiles, separate from individual projects.
- **Print preparation:** `⌘P` opens a dedicated physical print bed with object/component selection, orientation, scale, filament, layer height, walls, infill, supports, brim, and actual sliced layer previews. Project switches cancel local work and clear stale previews; settings and mesh share Undo/Redo.
- **Filaments and local printers:** Studio settings preserve spool profiles, colors, temperatures, flow, density, cost, and remaining inventory. P1S connection settings use Keychain for the LAN code and a read-only TLS/MQTT status adapter. Sending or starting prints is disabled.
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

The server exposes 50 tools for project creation, recipe discovery, custom parametric recipes, object edits, artwork, fonts, reusable text styles, vector operations, components, shared palettes, variants, grouping, camera control, project notes, exports, local slicing, filament profiles, printer status, atomic batches, and undo/redo. Changes appear in the native app and remain editable without another generation request.

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
| Orbit | **Orbit** tool (`O`), then drag anywhere; right-drag also orbits |
| Pan | **Pan** tool (`H`); Space-drag, Option-drag, or middle-drag |
| Move an object or group | **Move** tool (`V`), then drag the selection; Shift snaps to 10 mm |
| Zoom | Scroll up to zoom in, down to zoom out; pinch also works |
| Fine camera adjustment | Hold Shift while orbiting or panning |
| Focus / isolate | `F` / `I`, or floating inspector buttons |
| Perspective / overhead / front | `1` / `2` / `3` |
| Fit all | `⌘0` |
| Duplicate iteration / linked variant | `⌘D` / `⇧⌘D` |
| Group | `⌘G` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |
| Save / save a copy | `⌘S` / `⇧⌘S` |
| Print preparation | `⌘P` |
| Return to Home | `⇧⌘H` |

The Table starts in Orbit mode so navigation cannot accidentally move objects. Pan follows the pointer in screen space, the horizon stays upright, and orbit preserves the current perspective or orthographic projection. See [camera controls and validation](docs/camera-navigation.md).

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
python3 scripts/smoke_paragraphs.py # Saved tabs, real hyphenation, paragraph patches, schema 14, linked faces
python3 scripts/smoke_kerning.py # Font metrics, independent spacing, legacy preservation, schema 13, linked faces
python3 scripts/smoke_text_styles.py # Reusable styles, local overrides, character/paragraph links, schema 12, linked faces
python3 scripts/smoke_images.py # Original images, crop/adjustments, physical DPI, replacement, 100-image saved edits
python3 scripts/smoke_paths.py # Curve editing, transformed type, and linked variants
python3 scripts/smoke_clock.py --slice # Shared dial, immutable source links, physical exports, local Orca
python3 scripts/benchmark_artwork.py # 600-element native canvas performance
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
- [Paragraph tabs, hyphenation, and LEDGER](docs/paragraph-composition.md)
- [Non-destructive text case and VERSO](docs/text-case.md)
- [Editable SVG import and ORBIT illustration](docs/svg-import.md)
- [Precise paths and transformed native text](docs/path-editing.md)
- [Shared artwork and the clock study](docs/linked-artwork.md)
- [Shared colors and the CHROMA collection](docs/shared-swatches.md)
- [Editable appearance and the UMBRA study](docs/artwork-appearance.md)
- [Vector paint and the PRISM collection](docs/paint-gradients-masks.md)
- [Image editing and the LUMEN collection](docs/image-editing.md)
- [Textiles, Apparel & Merchandise · next feature specification](docs/textiles-apparel-merchandise-spec.md)
- [Queued feature push · NASA bomber jacket demonstration](docs/next-feature-push.md)
- [Expanded implementation goal and completion checklist](docs/implementation-goal.md)
- [Implementation architecture and boundaries](docs/architecture.md)
- [MCP setup and custom object recipes](docs/mcp.md)
- [Orca slicing, filament library, and local P1S setup](docs/printing.md)
- [Validation notes](docs/validation.md)
