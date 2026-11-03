# Dense Canvas and Studio performance

This pass starts from main `3e2b65f`, including the recent solid-editing and material-rendering work. The external test document contains 36 objects, 13,091 stored artwork elements, 54,119 path nodes, 216 Canvas frames and 166,717 elements across their projected views. Its eight saved Studio scenes contain 105 instances.

The document remains project data. No application behavior, recipe, cache or benchmark branches on its name or object identifiers. Opt-in benchmarks accept any external `.form` package, work in a temporary repository, and fingerprint the original package before and after the run.

## Changes

- Canvas snapshots observe an in-memory document generation, retaining exact source checks when content changes. Paper nets and registered artwork projections survive camera and frame placement changes.
- Prepared vector rendering reuses hierarchy indexes, paths and bounds, with conservative clipping. Hit-test and accessibility geometry reuse document-space data across camera changes.
- Distant finite frames use bounded display previews at the backing resolution. Close-up artwork, editor overlays and exported content retain vector rendering. Preview caches account for artwork, fonts, assets, exclusions, physical clipping and paper appearance.
- Canvas-only placement no longer rebuilds linked physical views. A successful document validation can be reused only when every non-placement dependency remains exactly equal; moved coordinates still receive their bounded validation.
- Canvas layer rows use indexed child lookup and lazy frame construction.
- Studio retains completed scene thumbnails across workspace changes, serializes native thumbnail captures, and memoizes scene keys and instance-family expansion. Selection and camera changes avoid geometry synchronization.
- Repeated paper instances share templates from the live scene during each synchronization, with independently applied fold poses. Face artwork signatures and print preprocessing are prepared once per face instead of once per panel. Output sampling and material fidelity are unchanged.
- Failed asynchronous Studio preparation remains retryable. Pending numeric scene fields commit before a scene switch, preserving the existing save/discard flow.
- Saves reuse unchanged immutable object revisions after a successful publication. Missing files are recreated, full validation still runs, and the manifest is published atomically.

## Reproduction

Use a release build on macOS with the normal native renderer available. Set `FORM_DENSE_PROJECT_PATH` to an external read-only package. These optional suites skip when the variable is absent:

```sh
FORM_DENSE_PROJECT_PATH="/absolute/path/Study.form" \
FORM_DENSE_BENCHMARK_OUTPUT="/tmp/document-stages.json" \
swift test -c release --filter DenseDocumentPerformanceTests

FORM_DENSE_PROJECT_PATH="/absolute/path/Study.form" \
FORM_DENSE_NATIVE_BENCHMARK_OUTPUT="/tmp/native-canvas.json" \
swift test -c release --filter DenseCanvasInteractionPerformanceTests

FORM_DENSE_PROJECT_PATH="/absolute/path/Study.form" \
FORM_DENSE_STUDIO_BENCHMARK_OUTPUT="/tmp/native-studio.json" \
swift test -c release --filter DenseStudioPerformanceTests
```

Measurements were taken on an Apple M5 with 24 GB of memory, macOS 26.6.2. The native Canvas suite drives the actual view's hand-pan, zoom and frame-drag handlers and draws to a bounded 1280 × 900 bitmap. It verifies that navigation does not edit the project and a frame drag remains one reversible Undo step. These measurements describe that viewport and machine, not universal frame-rate guarantees. The document-stage suite separately measures authored-artwork translation; the native drag measurement is frame-title dragging, not a dense subgroup drag.

The Studio suite loads all eight saved scenes, renders their native thumbnails, suspends and reenters the workspace, then checks image identity, render counts, scene expansion counts and unchanged document history.

## Evidence

Representative release medians (milliseconds):

| Workload | Before | After | Comparison |
| --- | ---: | ---: | --- |
| Unchanged save | 348 | 29.3 | Main baseline versus final performance pass |
| Frame placement + frame read | 3,152 | 9.1 | Main baseline versus final performance pass |
| Authored artwork translation + frame read | 345 | 75.9 | Main baseline versus final performance pass |
| Warm overview draw | 2,745 | 28.2 | Prepared-vector intermediate versus final overview/header caching |
| Overview pan redraw | — | 26.4 | Final native benchmark |
| Focused pan redraw | — | 13.5 | Final native benchmark |
| Native frame drag handler | 37.5 | 11.4 | Before versus after placement validation reuse |
| Return to 24-box scene | 11,037 | 482 | Before versus after paper template sharing |
| Return to 57-instance scene | 30,432 | 2,247 | Before versus after paper template sharing |

The first native frame-drag event took 36.9 ms before validation reuse warmed; its repeated median was 11.4 ms. The first document-stage frame-placement sample took 31.4 ms, compared with its 9.1 ms repeated median.

The overview measurement drew 159 frames at the minimum zoom; 158 finite-frame previews occupied 1.75 MiB. Initial overview preparation still took about 2.57 seconds. The twelve distinct patch scene still takes about 3.84 seconds to prepare its individual sources. Warm focused drawing and navigation should not be confused with cold loading, dense subgroup editing, a full Retina window, or an end-to-end display frame rate.

All eight Studio thumbnails rendered once; returning after suspension added zero captures and zero key builds. Cached thumbnail access took under 0.1 ms per scene. All benchmarks preserved the source package, including its saved history.

The final complete release suite passed: 2,078 tests, zero failures, three opt-in suites skipped. All three opt-in dense-document benchmark tests then passed separately against the external package. `tests.json` records the per-target results.

Baseline raw stage measurements are in `validation/dense-document-performance/baseline.json`. The source package fingerprint is `6c57bf8831e61b6d011305ebd2ef946f90c85df99892e4a9d17d51c3c9f0c832` under the document-stage benchmark's fingerprint convention.

The broader regression runs exposed intermittent unchanged-main cache-residency assertions in `PaperAppearanceRenderingTests` and `CanvasSourceAuthoringTests`. Geometry identity, physical calipers and rendered material checks passed. All 14 tests in those two suites passed together in an isolated rerun without changing either test.

The full suite also exposed stale packaging example counts after main added examples 13 and 14; the test now exercises all fourteen plus the separate liner. Its create/edit/undo/reopen checks are retained. An existing Studio shot test exposed unnecessary untextured-box rebuilds between preview and final quality. The production sampling key now omits only quality settings that an ordinary untextured box does not consume; the original strict reuse assertion remains intact.

A five-second CPU sample during the real Studio benchmark found 711 of 761 main-thread samples in scene geometry synchronization, including 610 in paper construction and 178 in repeated raster-key JSON serialization. The child carton's minimum charged texture cost was 66,929,344 bytes, above the existing 64,000,000-byte geometry cache budget. Per-sync reuse fixes repeated-instance eviction without increasing that persistent budget. The intermediate Studio measurements before this fix are preserved separately from the final measurements.

Computer-use coordinate dragging returned `windowNotFoundAtPosition` even after raising the ordinary LAB window. Native mouse-handler benchmarks provide drag coverage; accessibility actions and actual app screenshots provide the separate visible UI checks.

The signed release candidate was installed at the ordinary `build/LAB.app` path after saving and quitting the old process. Visible checks reopened the live Joshua Tree project (31 physical objects, 215 Canvas surfaces), inspected the Canvas overview and collection master close-up, exercised accessibility scrolling, opened the retail and capacity Studio scenes, and returned from Canvas to Studio. Artwork, paper surfaces and saved thumbnails displayed correctly. The live project and larger portable benchmark package are distinct snapshots; the numeric tables above describe the portable package. Initial Studio entry still required noticeable preparation, while reentry retained completed previews. Screenshots were retained locally under `.local/performance/dense-canvas/visible-*.png`; they are not benchmark timing evidence.
