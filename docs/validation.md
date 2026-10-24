# Validation record

Validated October 24, 2026 on the local Apple silicon Mac, macOS 26, Xcode 27 / Swift 6.4. The package deployment target is macOS 14; older supported OS versions have not been exercised on hardware. Build artifacts, downloaded engines, test libraries, exports, and detailed reports are kept under ignored `.local` / `build` directories.

This is a tested foundation, **not completion of the expanded professional 2D specification**. Remaining requirements are recorded in the [active goal](implementation-goal.md).

## Build and domain tests

- Debug and optimized app builds succeeded; the app bundle contains the native executable, custom icon, Info.plist, and stdio MCP executable and is ad hoc signed.
- `bash scripts/test.sh`: **54 tests passed, zero failures**. Coverage includes arithmetic parsing, parameter constraints, invalid-edit immutability, linked variants versus independent iterations, atomic batch rollback, undo/redo, modular package round trips, recipe validation, imported assets, artwork validation, JSON-RPC behavior, Unix-socket transport, hundreds of objects, binary STL records, physical bed/exclusion checks, relative extrusion/layers/arcs, fragmented MQTT frames, library migration, filament limits, and absence of hardware command tools.
- No model/API credentials or third-party Swift packages are required.

## Real MCP and persistence

`python3 scripts/smoke_mcp.py` passed against the running optimized app over its actual stdio MCP executable and local Unix socket. It verified protocol initialization, discovery of 39 unique tools, project creation, invalid input, linked variants, independent iterations, editable artwork, a custom recipe with native parameters, atomic batch rollback, every current export format, and saved-project reopen.

The Mac app was also saved, quit, and reopened. Native text edits, the agent-defined lamp recipe, artwork, project identity, and edited dimensions survived. Codex's host configuration was registered with the built `form-mcp` executable and inspected successfully. This chat's tool catalog need not refresh immediately; a new Codex chat can load the registered server.

## Native visual and interaction checks

The running application was inspected through native accessibility and screenshots. Home cards show saved scene images; the Table uses soft studio lighting, a continuous canvas, and floating inspectors. Selection/focus/isolation, native dimensional editing, artwork editing with adjacent 3D preview, Studio settings, and export dialogs were exercised. Text-field typing no longer triggers unmodified canvas camera shortcuts.

The Print sheet was inspected with a real sliced lamp shade. Bed and object camera framing worked; layer navigation changed the displayed layer and Z height. Filament and printer settings were inspected. No actual printer was connected.

## Physical exports

- PNG scene export: **3000 × 2000** pixels, verified from the binary header and visually inspected.
- Artwork PDF: page dimensions match the selected object in millimeters plus bleed and crop marks. Rendered with Poppler and visually inspected for text, imagery, clipping, orientation, and layout.
- Sleeve SVG: millimeter dimensions verified, with **one cut boundary and four distinct score lines**. No duplicated fabrication passes.
- Component JSON: valid structured output with millimeter units and materials.

The new artwork checks below extend these export guarantees. The complete professional typography specification, editable SVG interchange, color-managed production PDF, and advanced vector fidelity still require implementation and their own demonstrations.

## Native typography and vector milestone

`python3 scripts/smoke_artwork.py` passed through the real stdio MCP bridge in an isolated library. It created an exact **203.2 × 254 mm (8 × 10 inch)** composition, discovered installed Georgia faces/features, combined editable shapes into a compound path with a hole, converted shaped text to editable glyph paths while retaining hidden source text, rejected invalid edits atomically, exported every artwork format, and reopened the saved project intact.

The exported PNG is **1200 × 1500 pixels at 150 DPI**. The PDF MediaBox is **576 × 720 points**, independently confirmed with Poppler; its rendered page was visually reviewed. SVG uses the exact millimeter viewport and ordinary paths for outlined text. JPEG was generated successfully. These are actual outputs, rather than format-picker checks.

Additional automated coverage verifies unit conversion, legacy/partial decoding, nested transforms and ungrouping, duplicate masks/parents, invalid hierarchies, UTF-16 rich text, preserved missing-font metadata, font-layout cache invalidation, schema-2 persistence, selection exports retaining ancestor opacity/clipping, locked layers, and interaction undo/project switching. A raster comparison verifies text-to-outline appearance including underline/strikethrough, with mean absolute pixel error below 0.008.

Native UI checks verified automatic fit at usable scale, two adjacent artwork frames and live 3D preview, accessible element selection, double-click text entry without replacing the physical rulers, granular native text undo/redo and subsequent document undo, and selected-word sizing. The first four characters retained 60 pt while the remainder stayed 54 pt after leaving the inspector field; persisted rich-text ranges were inspected through MCP. Frame width changed from 8 to 9 inches and back, guide locking disabled its numeric field, and dragging from the ruler created a numeric horizontal guide. The installed-font browser filtered to Skia and exposed its real Weight/Width axes and supported OpenType controls; setting Weight to 1.6 updated its axis state.

Unsubmitted native frame-name and `9 in` numeric drafts both survived creating another project and reopening the original through MCP. These checks exercise the actual native field boundary, in addition to the domain-level callback test. Entering and leaving uppercase-displayed text without editing also preserved its original mixed-case source and artwork exactly.

The [editor guide](2d-editor.md) records limitations. Separate-path combination, SVG import, advanced typography, publication, color-managed production, and the full required demonstration suite remain unfinished.

## Precise paths and transformed native text

`python3 scripts/smoke_paths.py` passed against the real packaged app with 39 tools. It created the linked **Curve atelier** study, inserted/split/joined/reversed a cubic path, rejected invalid edits without mutation, checked undo/redo and linked variant equality, generated physical SVG/PDF/PNG outputs, and reopened the saved artwork intact.

Native testing edited text in a group with rotation and shear, including clicking a visible word to select its correct characters. Replacement and undo restored the exact stored artwork. A reflected parent group was tested the same way; screenshots confirmed the native selection, text, and static artwork stayed aligned. Automated coordinate checks exercise 48 successive affine maps with changing frame origins/sizes and forward/inverse conversions.

Native path controls inserted a midpoint, split and rejoined endpoints, moved a selected node to **74.5657 mm**, double-clicked a visible curve to insert another node, nudged it **0.1 mm**, and undid/redid that nudge independently. A marquee selected all six nodes; numeric span editing resized them to **150 mm**. MCP inspection confirmed the physical coordinate and exact linked-variant artwork equality. Actual SVG/PDF/PNG outputs from these native edits were generated; Poppler rendered the PDF and its page was visually reviewed.

Further native checks confirmed focused numeric fields update after undo and a pending 25 mm coordinate converts to 0.9843 inches when units change. Transformed text and selection were visually checked at the physical frame boundary; an untransformed clipping container prevents overflow. On a folding sleeve, entering dieline view ended inline text editing and choosing Edit text returned to the artwork surface.

Curve tests sample shape-preserving operations under nested affine transforms, confirm exact cubic extrema and unselected-node stability, verify smooth/symmetric/independent handles, check endpoint orientation, release masks on final-path deletion, and roll back failed path batches. These checks extend the existing acceptance evidence; they do not complete publication, interchange, production color handling, or all physical design demonstrations.

## Real official Orca slicing

Official OrcaSlicer **2.4.2** was downloaded from its GitHub release, SHA-256 verified, extracted unmodified, and run locally. `python3 scripts/smoke_print.py` passed through FORM's real MCP workflow:

| Object | Mesh size | Layers | Orca estimate | Filament estimate |
| --- | --- | --- | --- | --- |
| Test cube | 20 × 20 × 20 mm | 100 | 21m 17s | 3.64 g |
| Hollow lamp shade | 100 × 100 × 60 mm | 300 | 50m 44s | 29.20 g |

Both jobs produced valid binary STL records, actual G-code, a sliced 3MF ZIP containing G-code, parsed extrusion-layer previews, configuration snapshots, and logs. Invalid layer settings were rejected without changing the existing setup. A new filament was saved and rediscovered. Per-object component settings persisted. The helper's idempotent checksum-verification path also passed.

**Printer connections attempted: 0. Print jobs sent: 0.** Estimates are slicer predictions, not observed physical print results. Only the 0.4 mm P1S profile has been exercised end to end. A live P1S test awaits its local IP/serial and code entered directly in FORM. TLS certificate behavior, firmware-specific telemetry, and real network recovery remain unverified on that printer.

## Performance sample

`python3 scripts/benchmark.py` measured the optimized app with **300 parametric objects**, using saved MCP edits over the real bridge:

| Metric | Observed |
| --- | --- |
| Saved parameter edit latency, median | 15.27 ms |
| Saved parameter edit latency, p95 | 17.33 ms |
| Renderer synchronization after edits | 0.433 ms |
| Geometry rebuilds for 30 parameter edits | 30; unaffected objects reused |
| Geometry rebuilt for a transform-only edit | None |
| Idle CPU over a 3-second sample | 0.0% |
| Resident memory | Approximately 304 MB |

The view is demand-driven with a 60 Hz interaction target. Actual sustained frame rate was not instrumented, and these measurements are one local sample rather than a cross-device guarantee. The separate 600-element text/vector sample follows. Documents beyond that size and very large toolpaths need additional measurements.

## Artwork performance sample

`python3 scripts/benchmark_artwork.py` measured the optimized app with **600 elements, including 300 text objects**, and the live 3D preview enabled:

| Metric | Observed |
| --- | --- |
| Saved MCP edit latency, median | 39.19 ms |
| Saved MCP edit latency, p95 | 39.95 ms |
| Last measured native canvas draw | 0.918 ms |
| Text layouts rebuilt for 20 placement edits | 0 |
| Settled canvas redraws over 3 seconds | 0 |
| Idle CPU over 3 seconds | 0.0% |
| Resident memory | Approximately 356 MB |

An earlier run used roughly 760 MB and 101 ms median saved edits. Correct bitmap/GPU cache accounting and using a 1024-edge texture for the small 3D inset reduced that cost; Table textures retain their existing 2048-edge limit and physical exports retain their requested resolution. Renderer child lookup and imported-image reuse are bounded, and the text cache is limited to 800 layouts. These are local samples, not sustained gesture-FPS measurements or a cross-device guarantee.

## Reproduce

```sh
bash scripts/build.sh release
bash scripts/test.sh
bash scripts/install-orca.sh
FORM_LIBRARY_PATH="$PWD/.local/Library" build/FORM.app/Contents/MacOS/FORM
```

In another terminal:

```sh
python3 scripts/smoke_mcp.py
python3 scripts/smoke_artwork.py
python3 scripts/smoke_paths.py
python3 scripts/benchmark_artwork.py
python3 scripts/smoke_print.py
python3 scripts/benchmark.py
```

These scripts create named validation projects in the running app's library. Use the isolated development library to keep ordinary projects tidy. Reports and outputs are written to `.local/validation`.
