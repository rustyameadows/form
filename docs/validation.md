# Validation record

Validated October 24, 2026 on the local Apple silicon Mac, macOS 26, Xcode 27 / Swift 6.4. The package deployment target is macOS 14; older supported OS versions have not been exercised on hardware. Build artifacts, downloaded engines, test libraries, exports, and detailed reports are kept under ignored `.local` / `build` directories.

This is a tested foundation, **not completion of the expanded professional 2D specification**. Remaining requirements are recorded in the [active goal](implementation-goal.md).

## Build and domain tests

- Debug and optimized app builds succeeded; the app bundle contains the native executable, custom icon, Info.plist, and stdio MCP executable and is ad hoc signed.
- `bash scripts/test.sh`: **21 tests passed, zero failures**. Coverage includes arithmetic parsing, parameter constraints, invalid-edit immutability, linked variants versus independent iterations, atomic batch rollback, undo/redo, modular package round trips, recipe validation, imported assets, artwork validation, JSON-RPC behavior, Unix-socket transport, hundreds of objects, binary STL records, physical bed/exclusion checks, relative extrusion/layers/arcs, fragmented MQTT frames, library migration, filament limits, and absence of hardware command tools.
- No model/API credentials or third-party Swift packages are required.

## Real MCP and persistence

`python3 scripts/smoke_mcp.py` passed against the running optimized app over its actual stdio MCP executable and local Unix socket. It verified protocol initialization, discovery of 31 unique tools, project creation, invalid input, linked variants, independent iterations, editable artwork, a custom recipe with native parameters, atomic batch rollback, every current export format, and saved-project reopen.

The Mac app was also saved, quit, and reopened. Native text edits, the agent-defined lamp recipe, artwork, project identity, and edited dimensions survived. Codex's host configuration was registered with the built `form-mcp` executable and inspected successfully. This chat's tool catalog need not refresh immediately; a new Codex chat can load the registered server.

## Native visual and interaction checks

The running application was inspected through native accessibility and screenshots. Home cards show saved scene images; the Table uses soft studio lighting, a continuous canvas, and floating inspectors. Selection/focus/isolation, native dimensional editing, artwork editing with adjacent 3D preview, Studio settings, and export dialogs were exercised. Text-field typing no longer triggers unmodified canvas camera shortcuts.

The Print sheet was inspected with a real sliced lamp shade. Bed and object camera framing worked; layer navigation changed the displayed layer and Z height. Filament and printer settings were inspected. No actual printer was connected.

## Physical exports

- PNG scene export: **3000 × 2000** pixels, verified from the binary header and visually inspected.
- Artwork PDF: page dimensions match the selected object in millimeters plus bleed and crop marks. Rendered with Poppler and visually inspected for text, imagery, clipping, orientation, and layout.
- Sleeve SVG: millimeter dimensions verified, with **one cut boundary and four distinct score lines**. No duplicated fabrication passes.
- Component JSON: valid structured output with millimeter units and materials.

These checks apply to the current focused artwork model. Full professional typography, editable SVG interchange, color-managed production PDF, and advanced vector fidelity still require implementation and their own demonstrations.

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
| Saved parameter edit latency, median | 16.8 ms |
| Saved parameter edit latency, p95 | 24.99 ms |
| Renderer synchronization after edits | 0.387 ms |
| Geometry rebuilds for 30 parameter edits | 30; unaffected objects reused |
| Geometry rebuilt for a transform-only edit | None |
| Idle CPU over a 3-second sample | 0.0% |
| Resident memory | Approximately 272 MB |

The view is demand-driven with a 60 Hz interaction target. Actual sustained frame rate was not instrumented, and these measurements are one local sample rather than a cross-device guarantee. Text/vector-heavy documents and very large toolpaths need separate performance tests as those features mature.

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
python3 scripts/smoke_print.py
python3 scripts/benchmark.py
```

These scripts create named validation projects in the running app's library. Use the isolated development library to keep ordinary projects tidy. Reports and outputs are written to `.local/validation`.
