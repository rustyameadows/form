# Validation record

Validated October 24–25, 2026 on the local Apple silicon Mac, macOS 26, Xcode 27 / Swift 6.4. The package deployment target is macOS 14; older supported OS versions have not been exercised on hardware. Build artifacts, downloaded engines, test libraries, exports, and detailed reports are kept under ignored `.local` / `build` directories.

This is a tested foundation, **not completion of the expanded professional 2D specification**. Remaining requirements are recorded in the [active goal](implementation-goal.md).

## Build and domain tests

- Debug and optimized app builds succeeded; the app bundle contains the native executable, custom icon, Info.plist, and stdio MCP executable and is ad hoc signed.
- `bash scripts/test.sh`: **284 tests passed, zero failures**. Coverage includes arithmetic parsing, parameter constraints, invalid-edit immutability, linked variants versus independent iterations, shared artwork source graphs, atomic batch rollback, undo/redo, immutable package round trips, typography/outline alignment, actual SceneKit camera projections, recipe validation, imported assets, artwork validation, JSON-RPC behavior, Unix-socket transport, hundreds of objects, binary STL records, physical bed/exclusion checks, relative extrusion/layers/arcs, fragmented MQTT frames, library migration, filament limits, live boolean geometry/persistence, shared palette resolution, and absence of hardware command tools.
- No model/API credentials or third-party Swift packages are required.

## Real MCP and persistence

`python3 scripts/smoke_mcp.py` passed against the running optimized app over its actual stdio MCP executable and local Unix socket. It verified protocol initialization, discovery of 42 unique tools, project creation, invalid input, linked variants, independent iterations, editable artwork, a custom recipe with native parameters, atomic batch rollback, every current export format, and saved-project reopen.

The Mac app was also saved, quit, and reopened. Native text edits, the agent-defined lamp recipe, artwork, project identity, and edited dimensions survived. Codex's host configuration was registered with the built `form-mcp` executable and inspected successfully. This chat's tool catalog need not refresh immediately; a new Codex chat can load the registered server.

## Native visual and interaction checks

The running application was inspected through native accessibility and screenshots. Home cards show saved scene images; the Table uses soft studio lighting, a continuous canvas, and floating inspectors. Selection/focus/isolation, native dimensional editing, artwork editing with adjacent 3D preview, Studio settings, and export dialogs were exercised. Text-field typing no longer triggers unmodified canvas camera shortcuts.

The Print sheet was inspected with a real sliced lamp shade. Bed and object camera framing worked; layer navigation changed the displayed layer and Z height. Filament and printer settings were inspected. No actual printer was connected.

## Physical exports

- PNG scene export: **3000 × 2000** pixels, verified from the binary header and visually inspected.
- Artwork PDF: page dimensions match the selected object in millimeters plus bleed and crop marks. Rendered with Poppler and visually inspected for text, imagery, clipping, orientation, and layout.
- Sleeve SVG: millimeter dimensions verified, with **one cut boundary and four distinct score lines**. No duplicated fabrication passes.
- Component JSON: valid structured output with millimeter units and materials.

The new artwork checks below extend these export guarantees. The complete professional typography specification, full SVG interchange fidelity, color-managed production PDF, and advanced vector fidelity still require implementation and their own demonstrations. Editable SVG import is validated in its dedicated record below.

## Native typography and vector milestone

`python3 scripts/smoke_artwork.py` passed through the real stdio MCP bridge in an isolated library. It created an exact **203.2 × 254 mm (8 × 10 inch)** composition, discovered installed Georgia faces/features, combined editable shapes into a compound path with a hole, converted shaped text to editable glyph paths while retaining hidden source text, rejected invalid edits atomically, exported every artwork format, and reopened the saved project intact.

The exported PNG is **1200 × 1500 pixels at 150 DPI**. The PDF MediaBox is **576 × 720 points**, independently confirmed with Poppler; its rendered page was visually reviewed. SVG uses the exact millimeter viewport and ordinary paths for outlined text. JPEG was generated successfully. These are actual outputs, rather than format-picker checks.

Additional automated coverage verifies unit conversion, legacy/partial decoding, nested transforms and ungrouping, duplicate masks/parents, invalid hierarchies, UTF-16 rich text, preserved missing-font metadata, font-layout cache invalidation, schema-2 persistence, selection exports retaining ancestor opacity/clipping, locked layers, and interaction undo/project switching. A raster comparison verifies text-to-outline appearance including underline/strikethrough, with mean absolute pixel error below 0.008.

Native UI checks verified automatic fit at usable scale, two adjacent artwork frames and live 3D preview, accessible element selection, double-click text entry without replacing the physical rulers, granular native text undo/redo and subsequent document undo, and selected-word sizing. The first four characters retained 60 pt while the remainder stayed 54 pt after leaving the inspector field; persisted rich-text ranges were inspected through MCP. Frame width changed from 8 to 9 inches and back, guide locking disabled its numeric field, and dragging from the ruler created a numeric horizontal guide. The installed-font browser filtered to Skia and exposed its real Weight/Width axes and supported OpenType controls; setting Weight to 1.6 updated its axis state.

Unsubmitted native frame-name and `9 in` numeric drafts both survived creating another project and reopening the original through MCP. These checks exercise the actual native field boundary, in addition to the domain-level callback test. Entering and leaving uppercase-displayed text without editing also preserved its original mixed-case source and artwork exactly.

The [editor guide](2d-editor.md) records limitations. Separate-path combination, full SVG fidelity, advanced typography, publication, color-managed production, and the full required demonstration suite remain unfinished. The later SVG import milestone extends this record.

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
python3 scripts/smoke_svg.py
python3 scripts/smoke_clock.py --slice
python3 scripts/benchmark_artwork.py
python3 scripts/smoke_print.py
python3 scripts/benchmark.py
```

These scripts create named validation projects in the running app's library. Use the isolated development library to keep ordinary projects tidy. Reports and outputs are written to `.local/validation`.


## Native camera control pass — October 24, 2026

Camera navigation was tested through computer use with actual mouse drags and wheel input in the native app. Local MCP only observed state; it did not generate these camera movements. Testing used an isolated `CameraLibrary`, then restored the ordinary library and verified that Sun studies' six objects, artwork, recipes, materials, notes, and history were unchanged.

The original wheel-up gesture zoomed out, vertical orbit and pan were inconsistent, and sequential look-at updates accumulated roll. A small SceneKit reproduction measured a camera right-vector Y component of 0.188 after two orbit changes; fixed world-up reduced it to 0.00000154. The new repeated-update test checks 1,200 orbit/pan updates without horizon drift.

Native checks covered:

- Dragging right and up directly across a lamp in Orbit mode changed azimuth from 0.55 to 0.17865 and elevation from 0.70 to 0.32865, preserving every object definition.
- Selecting Pan and dragging diagonally moved the displayed scene right and up with the pointer. Projection tests independently verify exact screen-space displacement on the focus plane across angles and projections.
- Wheel-up reduced distance from 12 to 10.78878; wheel-down recovered the wider view. Overhead orbit retained orthographic projection.
- Click selection, keyboard Focus, isolation, recovery presets, Fit, and orbiting below the Table worked. The underside remained visible with an upright view.
- Explicit Move changed only the selected lamp's placement; native Undo restored all original object definitions.
- The Print sheet accepted mouse orbit and wheel zoom over a lamp shade, and Fit print bed recovered the bed framing. No slice or printer action was invoked during this pass.
- Save, quit, relaunch, and reopen preserved the camera state exactly. The default tool returned to Orbit.

Geometry build count remained three throughout the lamp navigation and placement checks, and `renders_continuously` stayed false. This verifies that camera movement does not regenerate meshes; it is not a sustained gesture frame-rate measurement. Local observations are retained in `.local/validation/camera-mouse-observations.json`, with the normal-library preservation check in `user-project-restored-camera.json`. The full suite passes **74 tests** and the optimized native app builds successfully. See [camera navigation](camera-navigation.md) for the updated controls.

### Focus and floating controls follow-up

A second native computer-use pass used actual drags over a linked-artwork box, mouse-wheel zoom, Pan, Focus, isolation, overhead view, and recovery to perspective with Fit. Orbit and pan followed the pointer, wheel-up moved closer, and every object definition stayed unchanged. The test exposed a framing problem: Focus could place the right edge of the object behind its floating inspector.

Focus, isolation, and Fit now reserve the inspector width and space for the camera controls. The subject remains the orbit pivot; the actual viewport aspect remains unchanged. On the same box and angle, Focus distance changed from 3.12959 to 5.40347, making the complete object visible beside the inspector. Mouse orbit afterward retained the target and distance. Isolated overhead Focus and perspective Fit also kept their subjects clear of the controls. The renderer retained five geometry builds throughout these checks and remained on demand.

All 11 camera tests pass. New SceneKit projection checks cover both projections, three viewport ratios, three azimuths, and five elevations, including views below the Table and near both poles. They verify every fitted corner stays outside the reserved control areas without shifting the orbit pivot. Invalid inset values remain bounded. The optimized native build completed successfully without warnings.

Observations are retained in `.local/validation/camera-current-mouse-check.json`. Testing ran in a separate local library. The regular **Soft light** project was restored exactly, including camera, objects, artwork, notes, and history, and the app was left at Home; comparison is retained in `user-project-restored-camera-followup.json`. No printer action was invoked.

## Editable SVG import — October 24, 2026

The suite now passes **90 tests**, including 16 SVG tests. Coverage exercises physical units and viewport mapping, complete path command families, reflected controls and elliptical arcs, nested transforms, CSS inheritance, rich/positioned text, reference expansion and cycles, gradient alpha/transforms, clipping holes, unsupported-feature reporting, XML/entity/depth limits, embedded image bytes/crops/type validation, boundary dimensions, and one-edit import/undo/persistence. Direct import onto a bare oak face retains its material and transparent artwork background. A trusted fixture rendered through macOS's SVG implementation stays within 3.5% mean RGB error of the native conversion.

`python3 scripts/smoke_svg.py` passed against the optimized app's actual stdio MCP server with **42 tools**, using an isolated `SVGLibrary`. It verified:

- Read-only preflight changes neither the project nor its assets. A warning-bearing import requires explicit acceptance; rejected imports preserve both.
- The original ORBIT SVG is retained byte for byte, alongside its embedded PNG. The 120 × 80 mm source contains 34 native elements, including 15 paths, four text objects, and one image.
- Oak and graphite product editions reference one source. Editing a source node leaves the consumer object files unchanged. Importing through a linked consumer adds to its canonical source; Undo restores the exact prior artwork.
- Actual SVG, optional live-text SVG, PDF, PNG, and JPEG files are produced. The PDF is **340.158 × 226.772 points**, matching 120 × 80 mm; PNG is **709 × 472 pixels at 150 DPI**. Poppler rendered the final PDF and the result was visually reviewed. Schema-4 save/reopen retains artwork, original provenance, and consumer links.
- Six read-only preflights of 600 paths plus 100 text objects measured **14.74 ms median / 16.21 ms maximum** locally. The first ORBIT preflight in that run took 4.42 ms. These are local conversion/transport samples, not sustained native gesture FPS or responsiveness at input limits.

The native file chooser, Go to Folder, review preview, and Import button were exercised through computer use. The chooser now uses an asynchronous Mac sheet. A filter-bearing SVG showed its explicit warning and disabled Import until the acceptance checkbox was selected. Cancel preserved the exact project. A supported ORBIT import created a second artwork frame; native Undo and Redo removed and restored it.

Native text entry edited the imported wordmark while a read-only MCP preflight ran; the text editor retained focus. In the final build, direct selection and a real mouse drag moved one imported planet node and both handles by approximately **2.996 × 2.244 mm**. Both product editions resolved the changed source, and native Undo restored the exact original artwork. The live 3D preview was visually inspected. A further Table mouse pass checked selection, Focus, orbit directly over the oak product, pointer-following pan, wheel zoom, and Fit.

The ordinary library was restored to Home with **Soft light** active. Its entire saved project, including all objects, artwork, camera, materials, notes, and history, matched the pre-validation snapshot exactly. The final build also passed the existing `smoke_mcp.py`, `smoke_artwork.py`, and `smoke_paths.py` flows. No printer connection or print command was attempted.

Reports are retained under `.local/validation`, including `svg-import-report.json`, `svg-native-node-observation.json`, and `user-project-restored-svg.json`. The [SVG guide](svg-import.md) records the supported subset and remaining fidelity limits. Full publication, color-managed production, advanced vector features, physical integrations, and the full demonstration suite remain active requirements.

## Compound paths and cross-object node editing — October 24, 2026

The suite now passes **100 tests**, including ten compound-path tests. Geometry checks retain anchors and cubic handles under nested rotation, shear, scale, and reflection. They exercise all four cross-path endpoint orientations, coincident endpoint merging, distinct endpoint joining, multi-path physical transforms/deletion, fresh duplicate node IDs, locked/masked/invalid atomic rejection, linked-source undo/reopen, and affine gradient-field preservation through combine/release. Native pixel comparisons verify compound holes and shape-to-path appearance, including implicit line strokes.

`python3 scripts/smoke_compound.py` passed through the packaged app's real MCP server in an isolated `CompoundLibrary`. **Contour atelier** converts two parametric ellipses to paths, combines a gradient ring with a true hole, releases/undoes its contours, and joins two separate cubic paths through a physical consumer. Clay and chalk product editions share the same source; only the source's object resource changes. Rejected edits leave the project unchanged, and saved-project reopen retains the exact artwork and relationships. The existing single-path and SVG smoke flows also pass.

The actual exported PDF measures **566.929 × 396.850 points**, matching its **200 × 140 mm** document. PNG is **1181 × 827 pixels at 150 DPI**. SVG contains ordinary editable paths. Poppler rendered the PDF, and its text, gradient, compound opening, joined curves, and physical composition were visually reviewed.

Twenty saved MCP transforms across **300 paths / 600 selected nodes** measured **29.01 ms median / 29.50 ms p95** locally. This includes the actual transport and document save; it is not a sustained native gesture frame-rate measurement or a guarantee at the model limits.

Native computer-use checks covered:

- Direct selection and Shift-click of endpoints on different paths; selection alone preserved the exact artwork.
- A real mouse drag moved both selected anchors and their handles by approximately **4.839 × 2.419 mm**. Unselected anchors stayed fixed and both physical consumers resolved the updated source.
- **Join**, `⌘J`, `⌥⌘8` release, and `⌘8` compound creation worked. Releasing filled the former hole; recombining restored it. A stale shortcut-enablement issue was corrected, and Undo now removes node selections that no longer belong to the selected path.
- A real affine-gradient start-handle drag moved it approximately **4.779 × 2.369 mm**, preserving path geometry, stops, transform, and the opposite handle.
- Native Undo restored the exact source definition after all these edits. The live 3D preview updated during the operations.

Detailed observations are in `.local/validation/compound-native-observations.json` and `compound-report.json`. The ordinary library is restored and checked against `user-project-before-compound.json`. No printer connection or print command is part of this workflow. See [path editing](path-editing.md) for commands, frontmost-appearance behavior, clipping constraints, and remaining vector work.


## Live boolean groups and editable regions — October 24, 2026

The suite passes **115 tests**, including fifteen live-boolean tests. Coverage includes all four operation truth tables and operand order, recoverable empty results, nested live updates, geometry-cache invalidation, affine gradients/strokes, compound holes, shared and internal clips, operand selection exports, Divide coverage/ownership, dynamic bounds, locked/invalid atomic rejection, stack order, and linked schema-5 undo/save/reopen. Native raster comparisons verify flattened geometry and paint.

`python3 scripts/smoke_boolean.py` passes through the real packaged MCP bridge in an isolated `BooleanLibrary`. **Aperture · Live boolean study** has a live crescent, a live trefoil, and separate Divide regions on an independent **200 × 140 mm** document. Clay and graphite products reference that source. Graphics operations work in atomic batches; an invalid later operation rolls the whole batch back. A changed operand rebuilds one affected cached boolean definition, changes the actual output, and leaves both consumer object files unchanged. Operation switching, flatten/release/undo, physical exports, and schema-5 reopen retain the source hierarchy. Creation, flattening, release, direct flat mode, and Divide are checked below unrelated foreground artwork; release also respects a reordered group's position.

The exported PDF is **566.929 × 396.850 points**, matching the physical document. PNG is **1181 × 827 pixels at 150 DPI**. SVG contains ordinary paths; the FORM project retains editable live operands. Poppler rendered the PDF, and its typography, crescent opening, gradient, trefoil, region boundaries, and layout were visually reviewed.

Twenty saved operand edits in a document with **100 live groups / 200 operands** measured **42.95 ms median / 43.93 ms p95** locally in the final packaged run. This includes real MCP transport and document saves; it is not sustained native gesture FPS or a guarantee at the input limits. The first cold workflow rebuilt one affected boolean definition; warm repetitions can reuse that identical geometry. Idle rendering remains demand-driven.

Native computer-use checks covered the operation picker, **Edit operands**, selecting the cutter through the empty opening, mouse-driven operand movement of approximately **7.500 × 3.023 mm**, and a numeric width change from **65 to 55 mm**. Only the cutter definition changed; the canvas and linked 3D preview updated. **Flatten result to path** produced seven ordinary nodes while retaining a hidden live source. **Release operands** restored the individual ellipses. The native **Divide into editable regions** menu produced three paths with seventeen nodes; a mouse drag moved only one region by approximately **−4.355 × 3.000 mm**. Native Undo restored the exact source artwork after every operation.

The existing artwork, precise-path, compound-path, and SVG smoke workflows also pass. Detailed reports and native observations are retained under `.local/validation/boolean-*.json` and `.log`. The ordinary library was restored to Home; the entire **Soft light** project, including its three objects, camera, artwork, materials, notes, and history, matches `user-project-before-boolean.json` exactly. The comparison is retained in `user-project-restored-boolean.json`.

This milestone does not complete advanced typography, reusable components, publication/color management, all SVG fidelity, or the full physical demonstration suite. No printer connection or print command is part of this workflow. See [live booleans](live-booleans.md) for supported geometry and bounded complexity.


## Reusable components and shared identity — October 24, 2026

The suite passes **129 tests**, including thirteen component tests. Checks cover world geometry and stack order, affine gradients/parent opacity/clipping, source edits across frames, per-part and global override precedence, text overrides, pixel-preserving detachment, stable independent element/node identities, nested live booleans, visible paint targets, atomic invalid edits, cycle/depth rejection, override-aware expansion limits, reachable-source cache invalidation, schema-6 reopen/undo, and source deletion that preserves consumer appearance.

`python3 scripts/smoke_components.py` exercises the packaged stdio MCP server with **43 tools** in an isolated `ComponentLibrary`. **STRATA · Shared identity system** shares one editable emblem between a **200 × 140 mm** field-kit layout and a **120 × 80 mm** instrument card. Clay and sage physical products reference those layouts. The card's smaller placement has a navy fill, copper accent, and independent edition text. Source edits update both layouts and physical consumers while only the source object resource changes. Detachment produces byte-identical PNG output and subsequent source edits leave that detached output unchanged. Invalid reference cycles and failed batches leave the complete project unchanged; schema-6 reopen preserves the source graph and overrides.

The actual PDFs measure **566.929 × 396.850 points** and **340.158 × 226.772 points**, matching their physical frames. Field-kit PNG is **1181 × 827 pixels at 150 DPI**. Both PDFs were rendered with Poppler and visually reviewed for typography, gradients, openings, independent text/color treatments, alignment, and physical composition. SVG contains ordinary groups/paths and outlined typography; the FORM package retains component links.

Native computer-use checks covered **Edit source** and **Back to instance**, a real source-geometry drag of approximately **1.996 × 1.023 mm**, per-instance fill and numeric sizing, and native text override input. Only the source object changed during the geometry drag, and both physical products resolved the update. Changing one label to **FIELD / 03** left source text at **FIELD / 01** and the other layout at **FIELD / 02**. A native width edit changed only that placement to **50 mm**. Native detachment retained identical exported pixels. `⌥⌘K` created a nested component with identical appearance; the native Insert Component menu placed another linked instance. Native Undo restored all original object definitions after these checks.

Twenty distinct saved source edits affecting **200 component placements** measured **128.09 ms median / 137.51 ms p95** locally in the final optimized run. The last measured canvas draw was **9.30 ms**, and idle rendering remained demand-driven. Profiling identified repeated full-hierarchy indexing inside boolean materialization; the renderer now builds one shared index per pass, with a 200-group regression check. The component resolver separately uses its reachable-source cache. These measurements include real MCP transport and document saves; they are not sustained native gesture FPS or a cross-device guarantee.

Native checks also verified the visible-paint part picker, physical preview after returning from source editing and making a further edit, and pending text drafts. Read-only component inspection preserved a draft; the next MCP mutation committed it before proceeding.

The final native canvas had **zero redraws and approximately 0% CPU over a three-second idle sample**. The existing project/parametric-object, live-boolean, and editable SVG packaged smoke workflows also pass.

The ordinary library was restored to Home. The entire **Soft light** project, including its three objects, camera, artwork, materials, notes, and history, matches `user-project-before-components.json` exactly; the readback is retained in `user-project-restored-components.json`.

Detailed reports are retained in `.local/validation/components-report.json`, `components-native-observations.json`, and corresponding logs. See [reusable components](reusable-components.md) for source-frame semantics, overrides, persistence, and limits. Shared swatches are covered by the next milestone below. Effects/blending, advanced publication/color management, complete SVG fidelity, and further physical demonstrations remain active requirements. No printer connection or print command is part of this workflow.

## Shared sRGB palettes and CHROMA — October 24, 2026

The suite passes **145 tests**, including fourteen palette tests. Coverage includes unique names and invalid-edit immutability; all paint locations; UTF-16 range boundaries; mixed typography; native attributed-text identity and shaped glyph outlines; component and physical-artwork detachment; appearance-preserving deletion including locked layers; group masks/hidden leaves; source-only immutable persistence; schema-7 reopen; batch rollback; and cache invalidation limited to reachable colors.

`python3 scripts/smoke_swatches.py` exercises **44 tools** through the packaged stdio server. **CHROMA · A shared palette** uses six named colors across a **200 × 140 mm** collection sheet, a **120 × 80 mm** edition card, a reusable seal, and clay/chalk physical products. Checks cover fills, strokes, gradient stops, text spans, backgrounds, component overrides, and outlined glyph paint. Changing Accent updates both layout exports while leaving every stored object and object-resource filename unchanged. Deleting Accent produces byte-identical PNGs for both layouts; Undo restores the links. Failed batches preserve the complete project, and reopening preserves schema 7 and all object definitions.

Native computer-use checks cover:

- Editing Accent HEX from `#D45A37` to `#849381`, with both layouts and the linked 3D inset visibly updating. No stored object definition changes, and native Undo restores the entire project exactly.
- Deleting a used swatch with byte-identical exports, followed by native Undo restoring the palette and references.
- Selecting only `003` in the title, applying Accent, and increasing those characters to **32 pt** while retaining the **2.5 pt** tracking and shared-color identity. Document Undo restores the entire native text session exactly.
- Assigning named colors through the stroke and gradient-stop menus, adding a new Mineral swatch, applying a shared frame background, and linking a component part override to Sage. Native Undo restores each sequence exactly.
- Leaving a palette-name draft focused during `form_get_project` and `form_swatch list`. An agent mutation then commits that draft before applying its own note; two native Undo steps restore the complete baseline.
- Selecting a group containing Ink-linked text and a line. The Group fills menu reports Ink; native detachment removes both links with byte-identical PNG output. Two native Undo steps restore the exact pre-group project. Group inspection uses the same visible paint leaves as assignment and detachment.

Twenty distinct palette edits in a **600-element document**—300 text elements and 300 ellipses, with 200 uses of Accent—measured **43.78 ms median / 46.75 ms p95** for saved MCP edits on this Mac. Object resources stayed unchanged throughout. The sampled canvas draw was **1.33 ms**. After native inspection, a settled three-second interval produced **zero canvas redraws**. These are local saved-edit/draw samples, not sustained gesture-FPS measurements.

PDFs were rendered with Poppler and visually reviewed. Page sizes are **566.929 × 396.850 pt** and **340.158 × 226.772 pt**, corresponding to the two physical layouts; the collection PNG is **1181 × 827 px at 150 DPI**. SVG/PDF/PNG/JPEG output uses current resolved palette values. The existing component, live-boolean, SVG, artwork/typography, and general MCP smoke workflows pass with the updated discovery count.

Reports and native observations are retained in `.local/validation/swatches-report.json`, `swatches-native-observations.json`, and the `swatches-*.log` files. See [shared swatches and CHROMA](shared-swatches.md) for controls, MCP arguments, persistence, and the explicit production-color boundary. ICC conversions, CMYK/spot separations, physical color catalogs, effects/blending, and the broader professional editing requirements remain open. No printer connection or command is part of this milestone.

The regular library was restored to Home with **Soft light** active. Its complete saved project, including its three objects, artwork, camera, materials, notes, and history, exactly matches `user-project-before-swatches-native.json`; the readback is retained in `user-project-restored-swatches.json`. The final optimized native app builds successfully without warnings.

## Editable appearance and UMBRA — October 24, 2026

The suite passes **166 tests**, including **21 appearance tests**. They cover strict patch validation and rollback; disabled-setting persistence; shadow swatch assignment/deletion; single-application layer/group opacity; pass-through and isolated groups; analytic blend colors and Gaussian coverage; blur/shadow bounds, direction, alpha, clipping, and color preservation; placement-independent cache reuse; preserved component appearance; missing-paint detachment as a no-op; schema-8 compatibility; SVG filters/isolation; selection margins; and explicit output-resolution limits.

`python3 scripts/smoke_appearance.py` exercises **45 tools** through the actual packaged stdio MCP executable and Unix bridge. **UMBRA · Light & matter** shares one layered mark across a **200 × 140 mm** sheet, a **120 × 80 mm** card, and two physical products. Editing the source shadow changes only its immutable source resource while both layout exports update. Undo restores the full pre-edit project, and a failed batch leaves it unchanged. Multi-color shaped text retains its complete opacity/shadow through editable outline conversion, with a hidden text source. Schema-8 reopen retains the definitions and links.

Native computer use checks the actual inspector: shadow offset **2 → 5.5 mm**, blur enable/radius **1.8 mm**/disable with settings retained, Multiply → Screen, shared-shadow-color detachment, explicit isolation, Reset appearance, source editing, and return to the original product context. Linked outputs and the live 3D preview update. Shadow-color detachment produces byte-identical PNGs for both layouts. Undo restores each sequence, including the complete project baseline. A numeric-field commit-order correction also ensures Undo visibly returns Offset X to **2**, with the model and field in agreement.

Twenty distinct saved source edits affecting **100 effect-bearing component placements** measured **70.49 ms median / 72.77 ms p95** on this Mac. The sampled canvas draw was **11.58 ms**, and the last effect build was **0.82 ms**. The run recorded **114 effect builds / 4,488 cache hits**, no preview density reductions, and no rendering error. A final settled three-second sample produced **zero canvas redraws**. These are saved-edit/draw samples, not sustained native gesture FPS. The isolated project's only later baseline difference was the live preview recording its viewport aspect; all other project fields remained equal.

SVG/PDF/PNG/JPEG exports retain physical dimensions and current appearance. Both PDFs were rendered with Poppler and visually reviewed; page sizes are **566.929 × 396.850 pt** and **340.158 × 226.772 pt**. The collection PNG is **1181 × 827 px at 150 DPI**. Native text and outlined output were visually compared. A real browser rendered the SVG beside the native PNG with blur, shadow, and Multiply intact: sampled blue, overlap, and paper RGB values matched exactly; orange and shadow samples differed by one 8-bit channel step. Mean normalized channel error over foreground pixels was **0.00935**. Edge/text rasterization differences remain; this is not byte-identical cross-format output. macOS's NSImage SVG decoder omitted these filters and was therefore unsuitable as an effect reference.

The existing component, palette, live-boolean, SVG, typography/artwork, and general MCP smoke workflows also pass on the updated optimized build. Reports remain in `.local/validation/appearance-report.json`, `appearance-native-observations.json`, `appearance-final-verification.json`, and the corresponding logs. See [appearance and UMBRA](artwork-appearance.md) for native/MCP controls, the 64 MB effect cache, per-layer preview/export allocation limits, and schema details.

The component/swatch/basic-effects checkpoint is complete. The expanded goal remains active for advanced typography/publication, production color, broader SVG/image workflows, further physical demonstrations, and unavailable live P1S verification. No printer connection or command is part of this milestone; textiles remain queued.

The final optimized app was reopened with the ordinary library and left at Home. The entire **Soft light** project, including its three objects, camera, artwork, materials, notes, and history, exactly matches `user-project-before-appearance.json`; readback is retained in `user-project-restored-appearance.json`. The final MCP executable exposes all 45 tools with the updated help descriptions.

## Image editing and LUMEN — October 24, 2026

The suite passes **185 tests**, including **19 image tests**. Coverage includes strict atomic crop/adjustment patches; locked layers/ancestors/sources; optional defaults and identity signatures; aspect-preserving fill/zoom limits; top-left crop orientation and frame clipping; brightness/contrast/saturation pixels; alpha and unpremultiplied color; vector masks; EXIF orientation applied once; transformed/cropped/sheared physical DPI; source-cache invalidation and reuse; original bytes and live SVG matrices; PNG/JPEG/TIFF/GIF/HEIC/BMP and WebP decoding on this Mac; animated GIF first-frame/count behavior; explicit output limits; schema-9 round trips; and batch rollback.

`python3 scripts/smoke_images.py` exercises **48 tools** over the packaged stdio server and local Unix bridge. **LUMEN · From scene to surface** uses an original **3000 × 2000 px** render from FORM's three-lamp study in a **200 × 240 mm** sheet and a **120 × 80 mm** card. The sheet has a cropped/color-adjusted image with a rounded vector clip and group shadow; the card uses an independent circular crop and monochrome treatment. Clay and graphite products reference the layouts. All source bytes match their copied assets exactly. Crop edits change only the source object's immutable resource, leaving consumers unchanged; physical DPI includes the product's fitting scale. Replacement preserves frame geometry, hierarchy, transforms, masks, opacity and adjustments, retains old originals, and is undoable. Owned-asset placement reuses its file, accepts centered placement, and supplies a descriptive copy name. Invalid imports and failed edit batches leave the complete project unchanged. Physical SVG/PDF/PNG/JPEG and schema-9 reopen pass.

Native computer use verifies:

- Dragging photo contents within a fixed crop frame, wheel zoom, and full-project Undo. Testing found an excessive individual wheel delta; bounded wheel events now produce a **0.8253 crop factor**, updating physical DPI **318 → 262** while retaining aspect. Both the below-300-DPI and severe low-resolution warnings were observed.
- Numeric saturation **82% → 0%**, visible grayscale on the canvas, with Undo returning the field to **82%**.
- Native **Replace…** file selection, with copied bytes matching the replacement and layout/mask/adjustment fields preserved; Undo restores the complete baseline.
- **Fill frame** at **397 DPI**, then fitting the frame to the source aspect at **114.6667 mm** high and **409 DPI**. Native Undo restores the original crop, dimensions, and project.
- A real drag from the preserved-original thumbnail into a second frame. The native destination records one source start, one destination update, and one completed drop. The **84 × 56 mm** copy is centered at the pointer, has a descriptive name, and reuses the existing original asset. Other object definitions stay unchanged; Undo restores the complete project.
- Read-only image metadata inspection preserving a focused native name field and the complete project state.

The final optimized run measured twenty saved crop edits across **100 images** at **78.08 ms median / 100.30 ms p95**, with a **2.43 ms** sampled canvas draw. Image decoding recorded **30 builds / 4,354 cache hits**, a **27.67 ms** last cold build, and no preview density reductions. These include real MCP transport and saves and are local samples, not sustained native gesture FPS. The earlier run measured **28.72 / 33.02 ms** before the native inspection pass; results vary with application/accessibility state and system load.

Both physical PDFs were rendered with Poppler and visually reviewed. Page sizes are **566.929 × 680.315 pt** and **340.158 × 226.772 pt**. PDF's filtered sheet image is embedded at approximately **152 DPI** for the requested 150-DPI output. Native PNG and browser SVG were compared with the crop, matrix, clip, and shadow intact. Mean normalized foreground channel error was **0.002885**; yellow, sage and paper samples matched exactly, while orange and shadow differed by one 8-bit channel step. Edge/text rasterization still differs; this is not byte-identical cross-format output.

The complete final image smoke and existing component, palette, appearance, live-boolean, SVG, typography/artwork, and general MCP smoke workflows pass on the final optimized build. Detailed records remain in `.local/validation/images-report.json`, `images-native-baseline.json`, `images-native-observations.json`, `images-final-smoke/images-report.json`, and corresponding logs. See [image editing and LUMEN](image-editing.md) for controls, schemas, format behavior, original preservation, and allocation limits. Production color, publication, broader interchange, remaining physical workflows, and unavailable live P1S verification remain active scope. No printer connection or command is part of this milestone; textiles remain queued.

After the native checks, the final isolated project retained all fields except viewport-aspect metadata recorded by window layout (**1.702128 → 1.700118**). Each individual native Undo sequence restored the full baseline exactly. A settled three-second interval produced **zero canvas redraws**. Final status is retained in `images-final-verification.json`.

The ordinary library was restored and the final optimized app left at Home. The entire **Soft light** project, including its three objects, camera, artwork, materials, notes, and history, matches `user-project-before-images.json` exactly **after returning to Home**. The final readback is retained in `user-project-restored-images.json`. The regular library contains only its original three projects.


## Vector paint and PRISM — October 24, 2026

The full suite passes **206 tests**, including **21 new paint tests**. They cover strict atomic stroke patches; disabled settings and implicit lines; unit-aware, zero-length and odd dash patterns; stop identity across reordering; stable hard edges; resolved swatch interpolation and alpha; reverse/reset transforms; native gradient pixels; degenerate gradients; inside/center/outside geometry including compound holes; fill-preserving stroke expansion with opacity/effects/clipping/affine transforms and stack order; live boolean expansion; identity-independent stroke caching; bounded dash expansion; portable SVG; mask reference redirection; nested clips/release; selection overflow bounds; schema-10 persistence; Undo and atomic batches.

The optimized native app builds without warnings. `smoke_paint.py` exercises **49 tools** through the actual packaged stdio server and local bridge. **PRISM · Color in motion** includes a 200 × 160 mm field sheet, a 120 × 80 mm radial-gradient card, and linked oak/graphite products. Five-stop paint, dotted rules, aligned borders, and nested clipping masks remain source definitions. Stop reorder/Undo, complete stroke patches, invalid paint rollback, reference-preserving mask conversion, and save/reopen pass. Expanding a filled gradient stroke produces an identical PNG while retaining editable fill geometry and hidden recovery sources.

Actual native computer use verified:

- Dragging a stop across its neighbor changed its offset from **0.53 to 0.84655**, retaining the same UUID and color. Native Undo restored the source exactly.
- Double-clicking the gradient axis inserts an interpolated stop without selecting an overlying contour. Keyboard Delete removes the selected stop; Undo recovers it. Dragging the whole axis changed start/end X by **0.06484** and Y by **−0.04490**, preserving the endpoint vector.
- The inspector committed **1.2 mm** stroke width, inside alignment, **60%** opacity, a `1 mm, .2 cm, 0, 4` pattern resolving to **[1, 2, 0, 4] mm**, round caps, and **−1 mm** phase. Native Undo restored the entire isolated project exactly.
- Edit mask, primitive-to-path conversion, real Bézier-node dragging, Back to contents, Release mask, and Undo preserve clipping relationships and original geometry. The first node pass increased the outer mask's height from **92 to 98.3039 mm**. A second pass confirmed that hidden SVG-style mask sources expose their outline and support actual node drags while staying hidden as paint.

Twenty saved paint edits on **200 stroked radial-gradient elements** initially measured **55.47 ms median / 57.70 ms maximum**, including bridge round trips and persistence. A final run after the full regression collection measured **96.36 ms median / 105.30 ms maximum**; both reports are retained. The final sampled stroke cache recorded **35 cumulative builds / 15,588 cumulative hits** across the isolated session, with a **5.47 ms** sampled canvas draw. A three-second settled native interval left process CPU time unchanged at 0:07.79; scene geometry remained at five builds and continuous rendering stayed disabled. These are local samples, not sustained gesture-FPS or whole-process memory guarantees. Stroke expansion has a 32 MB cache cost limit and rejects estimates above 20,000 dash segments before allocation.

All four SVG/PDF outputs retain their expected physical dimensions (200 × 160, 120 × 80, 220 × 180, and 140 × 100 mm). At 150 DPI their PNGs measure 1181 × 945, 709 × 472, 1299 × 1063, and 827 × 591 pixels. The field PDF was rendered with Poppler and visually reviewed. The browser SVG comparison measured **0.0065845 foreground mean channel error**; cobalt/rose/amber samples differ by at most one 8-bit step per channel. Differences concentrate at antialiased edges. Gradients, nested clips, expanded borders, and dotted rules agree visually.

The final build also passes the existing MCP, path, compound, SVG, boolean, component, swatch, appearance, image, and clock smoke workflows. Reports and native observations are retained under `.local/validation/paint-*`. The complete active 2D/3D goal remains open; this completes its basic gradient/full-stroke/editable-mask checkpoint. Variable-width strokes remain staged for later in the specification. No printer connection or print command was attempted.

Native regression review also exposed an existing integration gap: switching projects through MCP can leave an already-open Print sheet showing the previous mesh with an empty object choice. Closing the sheet recovers the current project. The project-scoped Print follow-up below resolves this presentation gap; the original smoke workflows alone did not cover it.

The final optimized app was restored to the ordinary library and left at Home. The entire **Soft light** project, including all three objects, artwork, camera, materials, notes, and history, matches `user-project-before-paint.json` exactly after returning to Home. The readback is retained in `user-project-restored-paint.json`.


## Project-scoped Print preparation — October 25, 2026

`bash scripts/test.sh` passes **224 tests**: the existing **206 core/graphics tests** and **18 direct app tests**. App-level coverage includes successful native/MCP opens and new projects; failed-open/template preservation; cleared object/mesh/toolpath/job/output/error/camera state; late success and failure arriving after a project switch while another job is busy; imported objects sharing UUIDs; owned local process termination; geometry changes and deletion; placement/color/name changes that preserve preparation; invalid settings; explicit cancellation and retry; saved lamp component choices; scale-setting Undo/Redo; and read-only status that does not rebuild or mutate history. Four mesh tests cover unrendered boxes/chamfers, cylinders, custom cones/spheres/tori, transformed recipe parts, print scale/rotation applied once, and hollow lamp shades.

The tests exposed parametric primitives returning unit placeholder vertices before resource preparation. `PrintMeshBuilder` now prepares material-free geometry copies explicitly before extracting triangles. A cold **20 × 30 × 25 mm** rounded box exports an exact-size binary STL with **1,452 triangles**, then official Orca 2.4.2 produces **125 layers**, G-code, sliced 3MF, and estimates. Physical dimensions are checked from actual STL vertex records, rather than the inspector's parameter labels.

`smoke_print_lifecycle.py` runs through the packaged stdio server and native bridge in a separate library. It verifies completed/running project switches, ownership metadata, cleared preparation, failed-open preservation, geometry edit/Undo, print-scale Undo/Redo, original project output paths, and shutdown of the owned real Orca worker. A subsequent current-project preparation remains unchanged when the old task finishes. No printer connection or hardware command is used.

Native computer-use checks verify the actual presentation and controls:

- An open Print sheet for the first project closes when MCP opens the second project. Clicking Print again shows the second object's **55 × 35 × 16 mm** mesh and correct settings.
- Real mouse orbit and wheel zoom respond in the Print bed, and Fit recovers the bed framing.
- Entering **150%** scale on the **20 × 30 × 25 mm** object and pressing Return keeps Print open and produces a **30 × 45 × 37.5 mm** mesh. Native Undo returns to **100% / 20 × 30 × 25 mm**, removing the document history entry; native Redo restores the scaled state. Programmatic synchronization does not create a replacement edit.
- A live **120 × 120 × 220 mm** cylinder slice with **0.04 mm** layers shows disabled settings and Cancel. Switching projects closes that busy sheet, clears its job/mesh/results, and stops the owned worker. A separate actual click on Cancel stops another local worker and displays **Slicing cancelled**.
- Creating an empty project clears the old results. Print shows **Choose an object**, no dimensions or files link, and disabled STL/slice actions. Escape also closes Print when its 3D bed has keyboard focus; the Table's normal Escape behavior is retained.

The final optimized app builds without warnings and retains **49 tools**. The final MCP, official Orca cube/shade, clock, and PRISM regression workflows also pass. A Print sheet left by a previous workflow no longer obscures the next artwork project. Detailed reports and native observations live under `.local/validation/print-lifecycle-*`. This completes the previously recorded project-switch Print gap; the complete professional 2D/3D goal remains active. **No printer connection or print job was sent.**

The final optimized app was reopened with the ordinary library and left at Home with its original three projects. The entire **Soft light** project, including all three objects, artwork, camera, materials, notes, and history, exactly matches `user-project-before-print-lifecycle.json` after returning to Home. The readback is retained in `user-project-restored-print-lifecycle.json`. Read-only MCP inspection confirms no prepared object, active slice, or printer connection remains.

## Independent typography features — October 25, 2026

`bash scripts/test.sh` passes **233 tests**, including nine new font-feature regressions. Real Core Text glyph checks prove common ligatures can be explicitly separated into two glyphs or combined into one, alongside additional/historical settings. Coverage includes legacy assignment migration, pair replacement/reset, invalid/conflicting/oversized input, exact native metadata retention when AppKit normalizes defaults, native font replacement/reset, missing-font assignment preservation, mixed-character sizes/colors/features, variable-axis coexistence, identical outline paths after native round-trip, layout invalidation/reuse, and schema-11 persistence with settings present only in rich spans.

The real packaged `smoke_font_features.py` workflow creates **FOUNDRY · The character of type**, an **8 × 10 inch** specimen and linked oak/graphite faces. Editing through a consumer rewrites only the source resource. A conflicting on/off pair rolls back a preceding valid edit in a batch. Editable glyph conversion retains the hidden text; Undo restores the original object definitions. SVG/PDF/PNG/JPEG exports retain physical dimensions; PNG is **1200 × 1500 pixels** at 150 DPI and PDF is **576 × 720 points**. Poppler-rendered PDF and the native raster specimen were visually reviewed. Reopening retains schema 11 and all definitions.

Native computer-use checks exercise the actual controls: Common Off while Additional/Historical stay On; Additional Default; Historical Off; Reset font features; exclusive lower-case figures alongside three independent ligature assignments; selected-character Off affecting only UTF-16 range **0–2**; and Skia weight **1.8 → 2.2** while width **1.12** and independent feature pairs remain intact. Native Undo restores the full isolated project exactly after every sequence, including the completed text session. Read-only MCP observations retain the native character selection and input focus. The live physical preview visibly retains the linked specimen.

Twenty saved edits across **200 text objects** measured **35.24 ms median / 40.07 ms p95** locally, with a **7.15 ms** sampled draw. Continuous drawing remains disabled. A later actual Table mouse drag and wheel input changes camera azimuth/elevation/distance while retaining all object definitions and **19 geometry builds**. These are local samples, not sustained gesture FPS. Font capability discovery is bounded at 256 faces and typography at 256 explicit feature settings.

The optimized app builds without warnings and still exposes **49 tools**. Existing artwork, clock, and PRISM workflows pass against the isolated library. Reports and observations are in `.local/validation/font-features-*`; repository previews and the model format are in the [FOUNDRY guide](font-features.md). **No printer connection or print job was sent.** The complete typography/publication and physical-design requirements remain active.

The final optimized app was reopened with the ordinary library and left at Home with its original three projects. The entire **Soft light** project, including all objects, artwork, camera, materials, notes, and history, exactly matches `user-project-before-font-features.json` after returning to Home; the readback is retained in `user-project-restored-font-features.json`. The packaged tool help includes the new selector format, and local status reports no busy slice or connected printer.

## Reusable typography, independent paragraphs, and FOLIO

`bash scripts/test.sh` passes **250 tests**: **232 core/graphics tests** and **18 direct app tests**. Seventeen new style regressions cover formatting boundaries, persistent explicit overrides, UTF-16/surrogate validation, palette coexistence, linked resource ownership, invalid-input atomicity, batch/Undo/Redo, schema-12 reopen, identical rendered detach/delete output, native font aliases/axes, word/tracking/manual-pair round trips, canonical native Undo metadata, create-and-apply, independent paragraph inheritance and reset filters, one-step redefinition, deletion, and styled component sources without rewriting instances. Successful project switches dismiss both resource panels; failed opens retain them.

The optimized native app builds without warnings and exposes **50 tools**. `smoke_text_styles.py` creates **FOLIO · A guide to light** with independent **160 × 210 mm** cover/instruction frames, three shared styles, a deliberate cover-size override, and linked oak/graphite faces. Formatting rewrites only affected artwork sources; metadata-only rename retains object resources. Detach/delete produce byte-identical PNGs. Reset, batch rollback, recoverable outlines, physical SVG/PDF/PNG/JPEG output, and schema-12 reopen pass. This demonstrates independent frames; sequential documents and multi-page publication remain open.

Real native computer use verifies the Text styles sheet's keyboard focus and numeric/name fields, inherited changes with retained local overrides, mixed selection indicators, reset, redefine, create from the selected word in one Undo step, and appearance-preserving deletion. A Caption assignment to “curtain” at UTF-16 `[14, 7]` retains an independent Body paragraph link; later Body leading changes flow through while Caption remains 8 pt. Native paragraph edits affect the containing paragraph, and manual pair edits retain tracking. Reset clears independent character/paragraph overrides and records the entire paragraph for native Undo while retaining the selected word. The final native reset/Undo/Finish text sequence restores the complete project exactly, retained in `text-styles-native-reset-undo.json`. Native text Undo plus Finish text restores the entire baseline project. Read-only style discovery preserves a focused pending name draft; an agent mutation commits it before its own edit, and Undo restores both. A native sheet open during a successful MCP project switch is dismissed when returning to Artwork.

Twenty saved style edits across **200 text objects** measured **99.50 ms median / 118.26 ms p95**, including local bridge round trips and persistence, with a **2.33 ms** sampled canvas draw. Continuous rendering remains disabled. These are local samples, not sustained gesture-FPS guarantees. Native sheet/project handoff and the packaged project/artwork/font-feature/swatch/paint/clock regression workflows pass in the isolated library.

Actual computer-use mouse drags verify Table orbit and pan. A right/up drag changes azimuth **0.55 → 0.21618** and elevation **0.70 → 0.51455**; the subject follows the dragged surface with an upright horizon. A **160 × 80 pixel** pan moves the scene with the pointer. Mouse-wheel up changes distance **12 → 9.97525**. Fit restores the collection; selecting the oak face and pressing Focus keeps it clear of the floating inspector. All four object definitions remain identical and geometry builds remain **160** throughout these camera checks. Readbacks are retained in `text-styles-camera-*.json`.

Both PDFs measure **453.543 × 595.276 points**. Native 150 DPI PNGs measure **945 × 1240 pixels**; Poppler uses a ceiling of 1241 pixels for the page height. Both Poppler renders were visually reviewed for text, spacing, rules, and margins. Repository previews and the manually framed 3D collection are linked in the [FOLIO guide](reusable-text-styles.md).

The full professional 2D/physical goal remains active. Advanced composition/publication, cross-project named-resource/asset clipboard transfer, and explicit automatic font-pair kerning control remain open. The existing default kerning behavior is preserved to avoid silently changing saved layouts. No printer connection or print job is part of this milestone; textiles remains queued.

The final optimized app was reopened with the ordinary library and left at Home with its original three projects. The entire **Soft light** project, including all three objects, artwork, camera, materials, notes, and history, matches `user-project-before-text-styles.json` exactly after returning to Home. The final readback is retained in `user-project-restored-text-styles.json`; the packaged server exposes all 50 tools.


## Font kerning, independent spacing, and AVENUE

The final suite passes **258 tests**: **240 core/graphics tests** and **18 direct app tests**. Eight new regressions verify actual Core Text glyph positions in metrics/disabled modes, tracking increments in point/mm units, independent manual/word spacing, a zero manual delta retaining metrics, mixed character modes/features, repeated native round trips and identical outlines, exact legacy decoding/spacing, style override/reset and batch rollback, schema-13 detection in rich spans and unused styles, inherited SVG kerning/live export, and layout-cache reuse. The optimized app builds without warnings. Native graphics tests require normal macOS graphics access; a restricted run could not prepare SceneKit/Core Image resources, and the complete graphics-enabled run passes.

A direct Baskerville 60 pt probe places the second glyph in “AVATAR” at **33.427734 pt** with font metrics and **40.634766 pt** with kerning disabled. Adding 2 pt tracking moves glyph index i by exactly i × 2 pt in either mode. Explicit modes use independent tracking attributes; missing modes retain the prior renderer and saved appearance. New native point text and new SVG text use metrics. Named styles retain explicit mode overrides and reset them deliberately. In explicit modes, word spacing and manual pair deltas compose; legacy precedence is unchanged.

`smoke_kerning.py` creates **AVENUE · The space between**, a **200 × 160 mm** wordmark/spacing study with one shared source and two physical faces. Font-metrics and disabled PNGs differ visibly. Formatting edits rewrite only the source resource, leaving both consumer files intact. Local override/reset, failed atomic-batch rollback, recoverable outlines, live/outlined SVG, PDF/PNG/JPEG, and schema-13 reopen pass through the packaged local MCP transport. The updated SVG, independent-feature, reusable-style, and artwork regression scripts also pass.

Actual native computer use verifies whole-object Font metrics → None → Undo; selected “AV” tracking of 2 pt; a -3 pt manual pair that retains metrics; and None applied only to “AV” while “ENUE” retains metrics/tracking 0. Pair positions remain local and do not invent style overrides. Three native Undos plus Finish text restore the entire baseline project exactly, including history. New native point text stores Font metrics/point mode, and creation Undo also restores the full baseline. Evidence is retained in `kerning-native-*.json`.

Twenty saved mode changes on **200 text objects** measured **43.52 ms median / 56.75 ms p95**, including bridge and persistence. The sampled canvas draw was **16.63 ms**; continuous rendering remains disabled. These are local samples rather than sustained gesture-FPS or whole-process memory guarantees. Actual computer-use Table orbit and wheel input changes the camera while retaining all three object definitions and **137 geometry builds**. Fit and the manually framed linked collection were visually reviewed.

The native 150 DPI PNG measures **1181 × 945 px**; PDF measures **566.929 × 453.543 pt**, and its Poppler render uses a ceiling of 1182 pixels in width. PNG, PDF, native character editing, and the linked physical collection were visually reviewed. A real browser comparison of default outlined SVG against native PNG measured **0.018620 foreground mean channel error**; glyph geometry and composition agree visually, with antialiasing differences. The optional live-text comparison measured **0.107819**, with receiving-engine font/shaping differences. Live SVG retains explicit kerning/spacing but still needs font/shaping review; default outlines remain the portable output. Measurements are retained in `kerning-browser-comparison.json` and previews in the [AVENUE guide](kerning.md).

The full goal remains active for alternate glyphs, advanced composition/publication, production color, named-resource/asset clipboard transfer, broader interchange, and remaining physical workflows. No printer connection or print job is part of this checkpoint; textiles remains queued.

The final optimized app was restored to the ordinary library and left at Home with its original three projects. The complete **Soft light** project, including objects, typography, artwork, camera, notes, materials, and history, matches `user-project-before-kerning.json` exactly after returning Home. Readback is retained in `user-project-restored-kerning.json`. The final packaged server exposes 50 tools and the updated kerning help. The temporary loopback comparison server and browser tab were closed.


## Paragraph tabs, real hyphenation, and LEDGER

The final suite passes **266 tests**: **248 core/graphics tests** and **18 direct app tests**. Eight new paragraph regressions exercise actual left/center/right/decimal glyph positions (period and comma), repeating intervals, rich selected-paragraph changes with emoji, invalid-range/surrogate/locked-target atomicity, independent style links and resets, exact native tab/default preservation, schema-14 detection in rich spans and unused styles, actual generated hyphen glyphs, unchanged raw words, overflow/clipping, placement cache reuse, and native drawing versus editable outlines. The final optimized build has no warnings. The hyphenated native/outline foreground comparison measures **0.014377 mean channel error**.

Core Text frame layout ignores the paragraph hyphenation factor in the direct probe. The implementation therefore uses a shared cached TextKit glyph layout for positive hyphenation; its generated glyphs drive measurement, overflow, native drawing, linked product textures, raster/PDF output, and outlines. Ordinary text retains the existing Core Text path. This is demonstrated output, not only a saved inspector value. Hyphenation remains dependent on system dictionaries/language; explicit document language and advanced limits remain open.

`smoke_paragraphs.py` creates **LEDGER · Material matters**, a **180 × 220 mm** inventory sheet and two linked oak/graphite faces. Quantity tabs center at **300 pt**; prices align their decimal separators at **400 pt**. A hyphenated Observation paragraph retains its original source words. Selected-paragraph edits rewrite only the shared source resource. Style update/reset, invalid atomic-batch rollback, recoverable outlines, physical SVG/PDF/PNG/JPEG output, and schema-14 reopen pass. Optional live SVG reports **three composed text elements outlined**, while ordinary text remains live. The server retains **50 tools**; `form_edit_artwork` adds a paragraph patch with optional containing-paragraph UTF-16 ranges.

Actual native computer use verifies unchanged Apply with no history/metadata drift; a duplicate-position validation error with no document mutation; one-step tab edits/Undo; and a selected-word change expanding only to the first paragraph at UTF-16 **[0, 22]**, retaining 13 pt character formatting and the remaining rows. Read-only calls retain the sheet/draft. A failed agent project open retains its captured paragraph range, correct scope label, and pending value; Apply still edits only that paragraph, and native Undo restores the entire baseline project exactly. A successful agent mutation closes the unapplied sheet without applying its values. Evidence is retained in `paragraph-native-*` and `paragraph-final-draft-handoff.json`.

Changing native Hyphenation from **100 to 0** visibly causes the Observation frame to overflow. Native Undo restores 100 and removes the overflow. Entering and leaving the actual native text editor visibly retains the generated line-break hyphens while MCP readback confirms the unmodified raw words and exact full baseline. The final suite covers successful project-sheet dismissal and failed-open retention directly.

Twenty saved paragraph changes across **200 text objects** measured **119.03 ms median / 120.44 ms p95**, including bridge/persistence. The sampled canvas draw was **1.19 ms** with continuous rendering disabled. Viewport culling may exclude objects from that draw; it is not a sustained all-visible gesture-FPS or process-memory guarantee. Paragraph cache limits are **256 entries / 16 MB estimated cost**, with placement reuse and font-change invalidation.

Actual computer-use mouse gestures verify Table navigation on the linked collection. A right/up drag changes azimuth **0.55 → 0.216183** and elevation **0.70 → 0.514546**. A **160 × 80 pixel** right/down pan visibly moves the scene with the pointer. Wheel-up changes distance **12 → 10.788779**. Native Fit restores the collection, and selecting the oak product followed by Focus keeps it clear of the floating inspector. All three object definitions stay identical and geometry builds stay **140** across these checks. The saved collection preview was framed with real mouse orbit/pan/zoom and native Fit, with MCP used only for readback and export. Evidence is retained in `paragraph-camera-*`.

Native PNG is **1063 × 1299 pixels** at 150 DPI. PDF is **510.236 × 623.622 points**, confirmed by Poppler and visually reviewed. Browser rendering of the default outlined SVG matches the decimal columns and hyphenated line breaks; the foreground mean channel error against the native PNG is **0.054602**, with antialiasing differences. The native/outlined hyphenation unit test separately compares the actual glyph geometry. The temporary loopback server and comparison tab were closed. Previews and exact command behavior are in the [LEDGER guide](paragraph-composition.md).

The existing kerning, reusable-style, independent-font-feature, artwork, and SVG packaged regression workflows pass in the isolated library. No printer connection or print job is part of this milestone; textiles remains queued. The full goal remains active for lists, advanced composition/publication, alternate glyphs, complete mixed-character case/source mapping, production color, broader interchange, and remaining physical workflows.

The final optimized app was restored to the ordinary library and left at Home with its original three projects. The complete **Soft light** project, including all object definitions, typography, camera, notes, materials, and history, matches `user-project-before-tabs.json` exactly after returning Home. The readback is retained in `user-project-restored-tabs.json`; final packaged discovery confirms 50 tools and the paragraph/export help.


## Reversible Unicode case, native input, and VERSO

The final suite passes **284 tests**: **258 core/graphics tests** and **26 direct app tests**. Ten new graphics regressions cover independent rich case, source/display UTF-16 ranges, contextual Greek final sigma across font boundaries, dotted I, combining/supplementary characters, source-preserving manual pairs, partial expansion deletion, Original restoration, externally split formatting, unchanged glyph counts/positions with native provenance, and malformed ephemeral records. Eight native tests cover real NSTextView insertion/replacement, case-formatting Undo/Redo, independently typed words with identical displays, marked-text commit and replacement after expansion, caret-arrow interaction/history cancellation, and growing multiline layout. The optimized app builds without warnings and retains **50 MCP tools**.

The previous renderer applied only the base case setting, ignoring rich-span treatments. The native editor could also persist displayed uppercase letters over source words. The shared case composer now preserves source words and each span's typography. One ephemeral provenance record across the entire native buffer preserves font ligatures/kerning; a character-by-character prototype failed the glyph regression and was replaced. AppKit's actual storage edit ranges preserve the correct original when identical displayed words have different sources. Marked input retains its pre-composition replacement range through commit. Production shaping skips native-record creation, with a uniform-formatting fast path. No extra document field/schema is introduced, and no provenance enters project JSON.

`smoke_case.py` creates **VERSO · The shape of a word**, a **200 × 180 mm** specimen and two linked oak/graphite faces. A case-treated “Straße” exports byte-identically to its explicit “STRASSE” equivalent. Mixed source “Straße / İSTANBUL” displays independent uppercase/lowercase while retaining raw source, font, size, and colors. Editing through a linked consumer rewrites only the source resource. Recoverable outlines, optional live SVG text, physical SVG/PDF/PNG/JPEG output, and saved-project reopen pass. The script verifies ephemeral records are absent from the saved package.

Actual native computer use verifies whole-object Uppercase → Original → Undo, with the full project restored exactly. Selecting displayed “SS” and choosing Lowercase produces **STRAßE** while raw source remains **Straße**; only source UTF-16 **[4, 1]** changes case. Selecting a single displayed S and setting **52 pt** formats the complete source ß at [4,1]. Formatting the following E at **50 pt** correctly targets source **[5,1]**, leaving preceding text at 46 pt. Native Undo retains the original words and formatting.

The final native flow types **“ ßa”** after caret navigation: the editor displays **STRASSE SSA**, while MCP reads **Straße ßa**. Native typing Undo plus Finish restores the entire project, including history and timestamps, exactly to `case-native-baseline.json`. The caret key-up previously ended the domain interaction; an integrated canvas regression and the corrected computer-use sequence prove the fix. Read-only MCP inspection preserves the active editing session. The rich specimen displays **Mixed**; selecting displayed “i̇stanbul” and choosing Original restores **İSTANBUL** at source **[9,8]**, preserving the first word, size, and color. Undo plus Finish again restores the exact full baseline. Final evidence is retained in `case-native-final-*`; earlier whole/range/size checks and their baseline remain under `case-native-*`.

Twenty saved style changes across **200 text objects** measured **59.27 ms median / 70.58 ms p95**, including bridge and persistence. The sampled canvas draw was **0.61 ms** and continuous rendering remains disabled. Culling and viewport state affect that sample; it is not an all-visible gesture-FPS or process-memory guarantee. The paragraph, reusable-style, kerning, independent-feature, artwork, and SVG packaged regressions pass against the final isolated app.

Native PNG measures **1181 × 1063 px** at 150 DPI. PDF measures **566.929 × 510.236 pt**; the final Poppler render was visually reviewed for casing, column positions, glyphs, and physical margins. Default outlined SVG preserves composed glyph geometry. Optional live text still needs receiving-font/shaping review. Previews and source semantics are in the [VERSO guide](text-case.md).

Real computer-use camera gestures on the final collection change azimuth **0.55 → 0.327455**, elevation **0.70 → 0.607273**, and wheel-up distance **9.052442 → 8.138733**. An **80 × 40 pixel** native pan follows the pointer. Fit restores the collection. All three object definitions remain identical, geometry builds stay **197**, and continuous rendering stays disabled. The collection export uses this manually controlled camera; MCP supplies readback/export only. Evidence is retained in `case-camera-*`.

The final optimized app was reopened with the ordinary library and left at Home with its original three projects. The entire **Soft light** project, including objects, artwork, camera, notes, materials, and history, matches `user-project-before-case.json` exactly after returning Home; readback is retained in `user-project-restored-case.json`. Final discovery confirms 50 tools and no external model calls. No printer connection or print job is part of this milestone; textiles remains queued.

## Camera direction and local navigation preferences

The camera now defaults to **Move camera**: dragging right moves the viewpoint right, and dragging up raises it. The camera bar's sliders button offers **Turn object** for the previous grab-and-turn convention, 25–200% orbit speed, reverse scroll zoom, Reset, and Done/Escape. The starting speed is 75%. Preferences survive relaunch, stay outside project files and Undo, and apply to the Table, Studio, artwork object inset, and print-bed preview. Navigation hints accommodate either scroll preference.

`bash scripts/test.sh` passes **288 tests**: **260 core/graphics** and **28 app tests**. New coverage checks both real SceneKit camera directions, bounded sensitivity, wheel reversal, local preference persistence and malformed-data recovery, and live preview preferences without document-camera ownership. Existing projection, framing, horizon, text, artwork, and print lifecycle checks pass. The optimized app builds without warnings.

Actual computer-use drags and wheel input were tested on a disposable copy of the three-project library. MCP supplied readback only. A right/up drag in Move camera changes azimuth **0.55 → 0.744727** and elevation **0.70 → 0.783454**. Repeating the same drag in Turn object returns exactly to **0.55 / 0.70**. At 50% speed, the same movement produces exactly two-thirds of the 75% angular change. A **160 × 80 pixel** pan visibly follows the pointer; the inverse pan restores the target exactly and preserves orientation. Wheel-up changes distance **12.125250 → 10.901387**; enabling reverse scroll and repeating that wheel input returns it to **12.125250**. Native Focus frames the oak box clear of its inspector, and the next actual mouse orbit preserves its pivot and distance.

Object definitions and document history stay identical throughout these checks, geometry builds remain **3**, and continuous rendering stays disabled. Native relaunch retains the selected 50% speed and reversed wheel; Reset restores Move camera / 75% / ordinary scroll. Done and Escape both dismiss the final panel, and a further real mouse drag confirms the restored behavior. Evidence is retained in `.local/validation/camera-usability-*.json` and `camera-usability-report.json`. These interaction samples do not claim sustained gesture FPS.

The final optimized app is running at Home with the ordinary library and its original three projects. The complete **Soft light** project exactly matches its pre-test snapshot, including objects, artwork, camera, materials, notes, and history; readback is retained in `user-project-restored-camera-usability.json`. Final packaged discovery confirms **50 MCP tools**. No printer connection or print job was performed.

The expanded goal stays active for small caps/alternate glyphs, explicit document-language/locale controls, lists, linked frames/publication, production color, broader interchange, and remaining physical workflows.
