# Validation record

Validated October 24, 2026 on the local Apple silicon Mac, macOS 26, Xcode 27 / Swift 6.4. The package deployment target is macOS 14; older supported OS versions have not been exercised on hardware. Build artifacts, downloaded engines, test libraries, exports, and detailed reports are kept under ignored `.local` / `build` directories.

This is a tested foundation, **not completion of the expanded professional 2D specification**. Remaining requirements are recorded in the [active goal](implementation-goal.md).

## Build and domain tests

- Debug and optimized app builds succeeded; the app bundle contains the native executable, custom icon, Info.plist, and stdio MCP executable and is ad hoc signed.
- `bash scripts/test.sh`: **69 tests passed, zero failures**. Coverage includes arithmetic parsing, parameter constraints, invalid-edit immutability, linked variants versus independent iterations, shared artwork source graphs, atomic batch rollback, undo/redo, immutable package round trips, typography/outline alignment, actual SceneKit camera projections, recipe validation, imported assets, artwork validation, JSON-RPC behavior, Unix-socket transport, hundreds of objects, binary STL records, physical bed/exclusion checks, relative extrusion/layers/arcs, fragmented MQTT frames, library migration, filament limits, and absence of hardware command tools.
- No model/API credentials or third-party Swift packages are required.

## Real MCP and persistence

`python3 scripts/smoke_mcp.py` passed against the running optimized app over its actual stdio MCP executable and local Unix socket. It verified protocol initialization, discovery of 41 unique tools, project creation, invalid input, linked variants, independent iterations, editable artwork, a custom recipe with native parameters, atomic batch rollback, every current export format, and saved-project reopen.

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

`python3 scripts/smoke_paths.py` passed against the real packaged app with 41 tools. It created the linked **Curve atelier** study, inserted/split/joined/reversed a cubic path, rejected invalid edits without mutation, checked undo/redo and linked variant equality, generated physical SVG/PDF/PNG outputs, and reopened the saved artwork intact.

Native testing edited text in a group with rotation and shear, including clicking a visible word to select its correct characters. Replacement and undo restored the exact stored artwork. A reflected parent group was tested the same way; screenshots confirmed the native selection, text, and static artwork stayed aligned. Automated coordinate checks exercise 48 successive affine maps with changing frame origins/sizes and forward/inverse conversions.

Native path controls inserted a midpoint, split and rejoined endpoints, moved a selected node to **74.5657 mm**, double-clicked a visible curve to insert another node, nudged it **0.1 mm**, and undid/redid that nudge independently. A marquee selected all six nodes; numeric span editing resized them to **150 mm**. MCP inspection confirmed the physical coordinate and exact linked-variant artwork equality. Actual SVG/PDF/PNG outputs from these native edits were generated; Poppler rendered the PDF and its page was visually reviewed.

Further native checks confirmed focused numeric fields update after undo and a pending 25 mm coordinate converts to 0.9843 inches when units change. Transformed text and selection were visually checked at the physical frame boundary; an untransformed clipping container prevents overflow. On a folding sleeve, entering dieline view ended inline text editing and choosing Edit text returned to the artwork surface.

Curve tests sample shape-preserving operations under nested affine transforms, confirm exact cubic extrema and unselected-node stability, verify smooth/symmetric/independent handles, check endpoint orientation, release masks on final-path deletion, and roll back failed path batches. These checks extend the existing acceptance evidence; they do not complete publication, interchange, production color handling, or all physical design demonstrations.

## Real official Orca slicing

The [shared-artwork clock study](linked-artwork.md) adds a third real local slicing case, detailed below.

Official OrcaSlicer **2.4.2** was downloaded from its GitHub release, SHA-256 verified, extracted unmodified, and run locally. `python3 scripts/smoke_print.py` passed through FORM's real MCP workflow:

| Object | Mesh size | Layers | Orca estimate | Filament estimate |
| --- | --- | --- | --- | --- |
| Test cube | 20 × 20 × 20 mm | 100 | 21m 17s | 3.64 g |
| Hollow lamp shade | 100 × 100 × 60 mm | 300 | 50m 44s | 29.20 g |
| Clock dial with 8 mm bore | 240 × 240 × 6 mm | 30 | 2h 57m 4s | 130.11 g |

Both jobs produced valid binary STL records, actual G-code, a sliced 3MF ZIP containing G-code, parsed extrusion-layer previews, configuration snapshots, and logs. Invalid layer settings were rejected without changing the existing setup. A new filament was saved and rediscovered. Per-object component settings persisted. The helper's idempotent checksum-verification path also passed.

**Printer connections attempted: 0. Print jobs sent: 0.** Estimates are slicer predictions, not observed physical print results. Only the 0.4 mm P1S profile has been exercised end to end. A live P1S test awaits its local IP/serial and code entered directly in FORM. TLS certificate behavior, firmware-specific telemetry, and real network recovery remain unverified on that printer.

## Independent artwork and the clock study

`python3 scripts/smoke_clock.py --slice` passed through the real packaged MCP server in an isolated library. Two physical clock variants reference one independent source. An edit made through a consumer updates the source and both physical faces; only the source object file changes in the manifest. The script checks rollback, detachment on independent iteration, source-context glyph outlining and node edits, shared undo, schema-3 save/reopen, and all artwork export formats. Unit tests additionally check appearance-preserving source deletion/detachment, proportional versus actual-size placement, and immutable consumer revisions.

Native Home **Start Clock dial study** created the complete project. **Edit source** opened the independent sheet while keeping the physical clock in the live preview. Native centered numeral input changed **12 → XII** on both consumers, and Undo restored the original. The native outline shortcut converted 12 into an ordinary editable path with 55 nodes, retained its hidden text source, and native Undo restored the text. Changing the physical dial to 280 mm preserved the 240 mm source; the native Fit control showed **116.7%**. Detach changed both physical variants to owned artwork and native Undo restored their links. A sleeve's inline artwork was extracted to a source sheet; native artwork/dieline views and the live physical preview retained the source.

The clock artwork PNG is **1417 × 1417 pixels at 150 DPI**. Its PDF is **680.315 × 680.315 points**, confirmed with Poppler and visually reviewed. The circular boundary and shaft opening agree across PDF, PNG, and outlined SVG. The separate cut SVG has exactly two circles with radii 120 and 4 mm. JPEG has a white matte. The clock mesh measures 240.00001 × 240.00001 × 6.00000 mm. Its **4,096 triangles** have two incident triangles per welded edge, and its signed volume is approximately **271,074 mm³**, within 1% of the analytic annulus. The sliced files retain the opening and exclude artwork rendering geometry.

Twenty saved hand-position edits measured approximately **12 ms median**, with **zero dial geometry rebuilds**. Source layouts remain editable and do not change when time changes. A bounded radial mesh replaced unnecessary shape/chamfer tessellation, and the face-image cache reuses serialized artwork definitions rather than encoding them twice.

Camera framing tests project actual SceneKit camera matrices across portrait/wide viewports, near-horizontal/near-overhead views, and different azimuths, proving bounds stay within the intended margin in both perspective and orthographic projection. Stored viewport aspect lets scene output preserve the complete source view at a different output ratio. Native inset and study framing use the same fitting rules. Scene initialization and project switching preserve saved camera angles; a scene writes camera state only to its matching project.

This is a prototype clock dial with illustrative hand blanks, not a completed working mechanism or a verified mounting/shaft system. Curved surface mapping, cross-project assets, panel continuity, the remaining demonstrations, and the full professional 2D requirements remain open.

## Performance sample

`python3 scripts/benchmark.py` measured the optimized app with **300 parametric objects**, using saved MCP edits over the real bridge:

| Metric | Observed |
| --- | --- |
| Saved parameter edit latency, median | 33.31 ms |
| Saved parameter edit latency, p95 | 33.94 ms |
| Renderer synchronization after edits | 3.455 ms |
| Geometry rebuilds for 30 parameter edits | 30; unaffected objects reused |
| Geometry rebuilt for a transform-only edit | None |
| Idle CPU over a 3-second sample | 0.0% |
| Resident memory | Approximately 348 MB |

The view is demand-driven with a 60 Hz interaction target. Actual sustained frame rate was not instrumented, and these measurements are one local sample rather than a cross-device guarantee. The separate 600-element text/vector sample follows. Documents beyond that size and very large toolpaths need additional measurements.

## Artwork performance sample

`python3 scripts/benchmark_artwork.py` measured the optimized app with **600 elements, including 300 text objects**, and the live 3D preview enabled:

| Metric | Observed |
| --- | --- |
| Saved MCP edit latency, median | 31.22 ms |
| Saved MCP edit latency, p95 | 34.21 ms |
| Last measured native canvas draw | 0.918 ms |
| Text layouts rebuilt for 20 placement edits | 0 |
| Accessibility items updated for 20 placement edits | 19 |
| Saved edit latency after native accessibility inspection, median / p95 | 53.23 / 66.77 ms |
| Settled canvas redraws over 3 seconds | 0 |
| Idle CPU over 3 seconds | 0.33% |
| Resident memory | Approximately 361 MB |

Table textures retain their 2048-edge limit, the small 3D inset uses a 1024-edge texture, and physical exports retain their requested resolution. Bitmap/GPU cache accounting is bounded; a face reuses its serialized definition rather than encoding it again. The canvas reuses accessible items and only writes changed attributes. Forty warm edits after native accessibility inspection updated 39 items and rebuilt no text layouts. Repeated inset fitting skips identical camera states. The text cache is limited to 800 layouts. These are local samples, not sustained gesture-FPS measurements or a cross-device guarantee.

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
python3 scripts/smoke_clock.py --slice
python3 scripts/benchmark_artwork.py
python3 scripts/smoke_print.py
python3 scripts/benchmark.py
```

These scripts create named validation projects in the running app's library. Use the isolated development library to keep ordinary projects tidy. Reports and outputs are written to `.local/validation`.
