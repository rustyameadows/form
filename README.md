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
- **Native artwork canvas:** Multiple physical frames, rulers/guides/grid/snapping, nested layers, exact transforms, Bézier paths, compound holes, cross-object endpoint joining, gradients, strokes, masks, and live 3D face updates. [Live boolean groups and Divide](docs/live-booleans.md) retain editable operands, support operation changes/release/flatten, and update linked product faces. A folding sleeve exposes its unfolded cut/score dieline.
- **Editable SVG import:** File → Import SVG Artwork (`⇧⌘I`) reviews native paths, groups, text, gradients, clips, and embedded images before creating a physical frame or adding to an existing surface. Originals stay in the project; unsupported features require explicit review. See the [SVG import guide](docs/svg-import.md).
- **Typography:** Installed-font browser, native selected-character editing, real OpenType features and variable axes, Core Text shaping, and editable glyph outlines with retained source text. See the [editor guide and remaining scope](docs/2d-editor.md).
- **Iterations and variants:** Independent design iterations or linked parameter/artwork variants with their own materials and placement.
- **Studio Library:** Persistent materials and equipment profiles, separate from individual projects.
- **Print preparation:** `⌘P` opens a dedicated physical print bed with object/component selection, orientation, scale, filament, layer height, walls, infill, supports, brim, and actual sliced layer previews.
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

The server exposes 42 tools for project creation, recipe discovery, custom parametric recipes, object edits, artwork, fonts, vector operations, variants, grouping, camera control, project notes, exports, local slicing, filament profiles, printer status, atomic batches, and undo/redo. Changes appear in the native app and remain editable without another generation request.

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
python3 scripts/smoke_paths.py # Curve editing, transformed type, and linked variants
python3 scripts/smoke_clock.py --slice # Shared dial, immutable source links, physical exports, local Orca
python3 scripts/benchmark_artwork.py # 600-element native canvas performance
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
- [Editable SVG import and ORBIT illustration](docs/svg-import.md)
- [Precise paths and transformed native text](docs/path-editing.md)
- [Shared artwork and the clock study](docs/linked-artwork.md)
- [Textiles, Apparel & Merchandise · next feature specification](docs/textiles-apparel-merchandise-spec.md)
- [Queued feature push · NASA bomber jacket demonstration](docs/next-feature-push.md)
- [Expanded implementation goal and completion checklist](docs/implementation-goal.md)
- [Implementation architecture and boundaries](docs/architecture.md)
- [MCP setup and custom object recipes](docs/mcp.md)
- [Orca slicing, filament library, and local P1S setup](docs/printing.md)
- [Validation notes](docs/validation.md)
