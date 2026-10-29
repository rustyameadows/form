# Agent modeling engine verification

October 28, 2026. Development branch: `codex/agent-modeling-engine`.

The shared modeling, construction and artwork implementation is verified. Held-pointer latency remains unmeasured. The organic reference test produces valid nominal geometry but fails visual acceptance; its source, actual renders and limitations are retained rather than claimed as a passing model.

## Environment and reproducibility

Apple silicon, macOS 26.6.2, Swift 6.3.3 Command Line Tools, pinned OCCT 8.0.1, debug app configuration. Packaged apps are ad hoc signed and use isolated libraries and sockets. Existing user projects were not used for mutations.

This machine lacks Xcode's XCTest launcher. The existing test methods and assertions ran with the official `swiftlang/swift-corelibs-xctest` `swift-6.0-RELEASE` runtime, compiled against Apple Foundation. A source-discovered runner registers the real synchronous and asynchronous test methods and links the original SwiftPM objects. Native tests use the same light appearance as the production app. Test failures were retained and investigated; no assertions or cache policies were disabled to obtain a passing result.

The complete original registry and focused current-source reruns cover **1,227 current test methods, with no remaining failures, skips or unexercised methods**, including native parameter interaction, native loft diagnostics, Canvas fitting and shared sewing guides. The long original run includes complete cloth simulations; fresh reruns resolve host appearance, helper location, superseded fixtures and resource-pressure cache counters. Detailed method-to-run reconciliation is retained under `.local/testing` with the original logs.

Standard Xcode verification remains `bash scripts/test.sh`. `scripts/build.sh` now finds the selected SDK's C++ headers and builds on this Command Line Tools installation without the earlier local environment workaround.

The final signed native package is `build/LAB-engine-shared-canvas.app`, executable SHA-256 `0153ebb0e3b827da59e9d7dab544beb24e3a641cb466da08ca9726fef062b227`. It has no XCTest/Testing runtime linkage. A real Mac app review opens the retained paper-and-tote project and shows all 11 finite frames, the full dieline, upright artwork views, and sewn cut/stitch/notch/grain guides on one Canvas. Repeated native Fit leaves the complete saved project/history/camera JSON identical and retains one sewing-guide build. The app remains open in its disposable library. Actual native viewport/status evidence is under `.local/validation/native-canvas-final`; the independent real-host proof verifies that no ruler covers any fitted finite frame.

## Fixed-case modeling-loop benchmark

`Tests/Fixtures/AgentModeling/loop.json` freezes the source definitions. Each app runs in a fresh private library and process. Both builds use preview quality, a front view, 640×480 images and five successive dimension edits per model. Timing includes submission, asynchronous evaluation, evidence request and usable rendered image. RSS probes occur outside measured spans.

| Warm edit-to-image metric | Original | Updated |
| --- | ---: | ---: |
| Enclosure median | 241.599 ms | 171.231 ms |
| Clock enclosure median | 937.351 ms | 405.689 ms |
| Curved vessel median | 822.402 ms | 704.838 ms |
| Aggregate median, 15 samples | 822.402 ms | 405.689 ms |
| Aggregate p95 | 995.737 ms | 877.694 ms |

Aggregate median improves **2.027×** and p95 improves **11.9%**. Cold model evaluation aggregate median is 859.020→341.622 ms (three samples; each individual cold case has n=1). Maximum observed case-boundary RSS snapshots are 458.44→461.00 MB. These are sampled RSS values, not a continuous peak-memory measurement. Staged-file measurements are unavailable because Foundation did not use the requested private temporary root; empty snapshots are not reported as zero staging cost.

The benchmarked app executable SHA-256 is `aa1a50ad2a85457bdb5006fcda07e5a035ab8ccb87bc1b6b18f6c3a75a2d92fd`. Full definitions, source/binary hashes, timings, images and resource snapshots are under `.local/validation/agent-loop-performance-20261028T231633Z-aa25e19a`. Subsequent changes add native loft failure diagnostics and Canvas presentation fixes; they do not change the measured CAD success path, geometry tolerances or fixture quality.

Earlier benchmark attempts are retained, including the initial 1.03× result and cache-only 1.959× result. The final improvement follows concrete native metadata reuse and rigid-transform property reuse; quality, fixture definitions and measured commands were not changed to meet the target.

## Exact geometry and source ownership

All 18 before/after fixture BRep hashes and preview triangle counts are identical. Bounds, topology, validity, closedness and tolerances are identical. Twelve complete info dictionaries remain bitwise equal; rigid-motion mass/area reuse changes the other cases only at floating-point rounding scale (maximum relative difference about 1.4×10⁻¹⁵, maximum volume difference 1.75×10⁻¹⁰ mm³), far below the existing integration tolerance.

Full geometric validation still runs for newly created shapes. Regression checks cover analytical dimensions/mass/area, rigid motion, scaling, shear, reflection, open-profile rejection, unchanged source BRep after meshing and derived operations, and mirrored-source STEP export without input mutation. Proof and pinned OCCT source references are retained under `.local/validation/cad-info-cache-exact-proof`.

The packaged agent acceptance flow creates an unregistered five-panel construction, measures a fold-and-glue connection, repairs a failed fillet in place, runs independent evidence requests and parameter cases, and publishes once. It also supplies a fitted container/cap with measured clearance and interference, binds three upright artwork sources, preserves them through dimension edits, reports placement review, and verifies actual blue artwork pixels in a rendered image. A curved vessel boundary case fails a saved requirement, then passes the identical cases after an atomic source repair. Explicit envelope/carton conversion retains artwork, stock, annotations, identities and Undo while preserving parametric glue/flap overlap metadata.

Fold-and-glue connection checks measure declared neutral-plane anchor gaps. They do not establish interference-free folding of finite-thickness panel solids; that proof remains open.

Thirteen native Canvas regressions cover full-net artwork editing, derived structural guides, upright source transforms, region-bounded selection, clipboard/SVG/image placement, inside artwork, CAD sources, sewing sources, Undo/reopen and actual mesh/texture reuse when arranging frames.

Six additional Canvas regressions cover native fit bounds and derived sewing guides. All three strengthened fit tests fail against the prior native object and pass after correcting coordinate conversion and fitting inside the unobscured viewport. They cover shifted document origins, unchanged-zoom refits, panel focus and a tall mixed paper/sewing layout under real native rulers, including their marker thickness. Hidden or separately positioned rulers do not reduce usable space. Sewing tests preserve the original sheet-output byte hash, cache curved guides without retaining invalid geometry, preserve printed fills, and verify actual tote-guide pixels, production-role visibility, unchanged source and Undo. The complete final focused Canvas/paper/sewing run passes 99 methods. Frame labels clip within their own bounds, and navigation labels retain visible surface suffixes when shortened.

## Fabric and sewn constructions

All 16 shorter packaged workflows pass: cloth, sewing patterns, curved patterns, fabric patterns, garment blocks, sewing tiles, cutting layouts, textiles, merchandise, embroidery, embroidery surfaces, decoration preparation, production jobs, production roles, collections and production inks. Six additional independent PDF/SVG/DST/Poppler reader invocations pass. Where a fresh native window changes its derived viewport aspect, comparisons exclude only that field and retain every physical source/history/artwork field and the exact camera pose.

The complete original sewn-pouch smoke also passes end to end on the final benchmarked app: preparation, all 240 frames, independent structural strain, UV/triangle identity, source/history/camera preservation, exact pins, finite coordinates, saved snapshot bytes/SHA, reset, attachments, remesh, source-edit/Undo, broken-source rejection, reopen and the print gate. The run takes 703.641 seconds in this debug configuration.

Its saved frame-240 proof contains 872 finite vertices, four exact pins (maximum error 0 mm), all 1,514 unchanged triangles and unchanged UVs. Independent final strain ratios are minimum 0.938351, maximum 1.020864 and p95 1.001985; worst transient is 1.128043 and seam gap 0 mm. Evidence is `.local/validation/pattern-canvas-complete-1f15121e31`, including the raw checkpoint and `raw-proof-summary.json`.

An earlier attempt was interrupted by native orbit input and was recorded separately with its limitations. The complete successful replay uses a verified view-only Canvas setup to prevent 3D orbit interference. It preserves the entire saved project/history/pose and executes every original solver step and assertion; no workload, threshold or camera comparison was reduced. The earlier missing final raw-pin artifact is superseded by the successful complete replay.

Packaged paper, ordinary Canvas and portable transfer gates also pass, including real 3000×2000 renders, physical layouts, immutable packet hashes, original resource preservation, loose-frame transfer and a 501-element edit/reopen case. Their reports are under `.local/validation/paper-construction-7535f8a7ff99` and `.local/validation/canvas-release-4de98dca1447`.

## Additional native and organic gates

Native parameter measurements distinguish live fold/fabric controls from CAD draft sliders followed by explicit Preview. Three real-window regression tests pass using the production controls, native keyboard events, intermediate frame counters and actual RealityKit captures:

| Interaction | Observed result |
| --- | --- |
| Authored live fold | 56 inputs and 56 visible frames; event→source p95 47.3 ms; last input→GPU capture 77.4 ms |
| Live fabric dimension | 72 inputs and 72 visible frames; event→source p95 66.3 ms; last input→GPU capture 98.7 ms |
| Mechanical CAD draft | 72 inputs; event→draft p95 12.8 ms; explicit Preview→validated GPU capture 288.3 ms |
| Native Cancel/new Preview | Old work remains cancelled; releasing it cannot replace the latest ready width-135 model |

These are observed debug-host timings, not fixed production latency guarantees. Tests retain generous timeout guardrails and assert correctness, intermediate frames and latest-state ownership. Evidence is `.local/validation/native-control-verified`.

Held-pointer latency remains a separate measurement. CUA sends correctly positioned mouse-down/drag/up events, but the native host records no held button; standard sliders ignore that synthesized tracking. The controls were not changed to accommodate it. An optional physical-drag probe remains available in a private native window and saves its report automatically on release.

The organic design reference is independently AI-generated and frozen before modeling at `examples/agent-modeling/organic-bud-vase/ai-generated-reference.png`. The chosen `model.json`, reproducible generator, prompt/hash, actual multi-angle renders and assessment are checked in beside it. The model uses familiar curve-profile, loft and shell operations as project content, with no app code or product registration.

Nominal geometry is valid and hollow, with 32 physical flutes. Visual reference acceptance **fails**: foot and shoulder shape, body depth, neck placement and coarse/uneven relief still differ. Side lighting reveals the existing flutes and hollow neck; increasing tessellation from 441,260 inspection triangles to 792,606 fabrication triangles does not fix those differences. Broad shoulder/base undulations remain unresolved between source fairness and normal shading. Only the nominal configuration is evaluated; a parameter-range pass is not claimed.

First ready state takes 317.78 seconds; shell offset alone takes 241.86 seconds. This detailed sculptural case exposes a substantial performance and quality limit beyond the fixed three-case latency benchmark. Earlier failed lofts and source-only repairs are retained locally. The public `validation-report.json` distinguishes geometry, lighting, visual mismatches, parameter coverage and timing, while the final validator defaults to the standard packaged app and chosen source.
