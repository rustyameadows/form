# Agent modeling tools

Models and constructions are saved project content. An agent supplies definitions and edits through the installed app's tools; introducing a design does not require changing app code or installing a model plugin. Start with `form_cad` or `form_construction` using `command: "capabilities"` to discover supported fields and executable examples.

## Evaluate, inspect, repair and publish

`form_cad create` accepts a model definition and returns a review job. Poll `status` using its `job_id` until it is `ready`, `failed` or `cancelled`. The status includes source revision, `draft_revision`, phase timings, feature reports and a structured diagnostic on failure. Ready previews retain evaluated geometry in memory; project assets and Undo history are published only by `commit`.

Use `patch` with the current `job_id`, `expected_revision: status.draft_revision` and a `patches` array. Actions are:

| Action | Payload |
| --- | --- |
| `parameters` | `values`: named numeric values |
| `append` | `feature`: complete feature node |
| `replace` | `feature_id`, `operation` |
| `remove` | `feature_id` |
| `suppress` | `feature_id`, `suppressed` |
| `outputs` | `outputs`: output feature UUIDs |
| `requirements` | `requirements`: parameter assertions |
| `output_requirements` | `requirements`: measured output assertions |
| `surfaces` | `surfaces`: named planar surface definitions |

The complete patch is checked before mutation and evaluated once. Stale revisions reject without changing the draft. A failed feature keeps its draft and last valid preview: inspect `diagnostic`, patch that same job and evaluate again. Commit a ready revision, then poll until `committed` or `failed`. Publication rechecks the project and source and makes one Undo edit.

## Independent evidence and parameter cases

`evidence` accepts `job_id` and `requests`, an array containing any combination of:

| Kind | Required fields |
| --- | --- |
| `summary` | none |
| `topology` | `feature_id` |
| `clearance` | `first_output_id`, `second_output_id` |
| `render` | exclusive `path`; optional `view`, `width`, `height`, `transparent` |
| `export` | `output_id`, exclusive `path`, `format` (`brep` or `step`) |

Each call returns a separate `request_id`. Poll `evidence_status` with that ID until `complete`, `failed` or `cancelled`; retain each result instead of depending on a later job status replacing it. Requests include the evaluated revision. `evidence_cancel` cancels one request. Evaluation and patch calls can also include an `evidence` array to request evidence when the preview becomes ready.

`validate` accepts a ready or repairable job, optional explicit `cases: [{name, values}]`, `include_extrema`, `maximum_cases` (1–128) and `maximum_duration_seconds`. It returns an evidence request ID. The completed result contains `results[0].report`, including `allPassed` and individual case outcomes. Cancellation, skipped cases and time limits cannot report success. Parameter validation uses independent geometry caches and leaves the accepted project, artwork, selection and Undo history unchanged.

## Physical artwork surfaces and Canvas

A version 2 CAD model can declare `surfaces` with stable `id`, `name`, `outputFeatureID`, `selection`, expression-based `origin`, orthonormal `uAxis`/`vAxis`, expression-based `width`/`height` and an optional local `boundary`. Units are millimeters. Surface selection must identify one planar exact face, and the declared region must fit entirely within it. One named artwork surface per exact face is currently supported. Reusing a face for several named surfaces rejects explicitly.

Use `form_surface inspect` on a committed object to read resolved surfaces and unresolved bindings. `bind` accepts `object_id`, `surface_id` and an independent artboard's `source_object_id`; `unbind` removes that binding. The source retains its physical size and editable vector/text/image content. Table textures and Canvas projections reference it directly. Deleting a source artboard retains a detached artwork snapshot on its consumers; Undo restores the link.

A flat construction exposes its full dieline and upright panel frames on the ordinary Canvas. Their positions are view layout. Their artwork edits map back into the same canonical flat source, preserving element IDs and physical scale; the construction geometry comes from its saved parametric definition. Sewing pieces use the same Canvas editing, source ownership, physical units and Undo conventions, with seam, allowance, grain and notch controls in their material context.

Sewn pieces display derived cut, stitch, notch, grain and construction guides directly on that Canvas. They use the same technical geometry as pattern export, in the source's physical coordinates. Guides are display only; editable contours and sewing metadata remain the original elements. Guide visibility and production-role filters apply without changing exported geometry. Unchanged sources reuse cached guides during pan and zoom; invalid source geometry clears its old guides.

Clipboard, SVG and image placement use those same physical frame transforms inside the existing single Undo transaction. Full-net artwork remains editable; cut and fold guides remain derived geometry. Moving a projected frame preserves the assembled mesh and texture caches.

`form_surface inspect` and CAD preview reports include `surface_artwork_issues` when a source frame changes size, exceeds its target, or loses its named surface. Linked variants participate in the same review and publication guard. The app preserves the artwork's millimeter size and reports the affected object and surface instead of stretching it. Detached snapshots remain consumers of shared styles, swatches, fonts and production inks. Publication text also retains its complete original composition context after deleting its live frames.

## Authored flat constructions

`form_construction capabilities` returns a small executable panel example, a measured fold-and-glue example, and the two legacy paper examples as ordinary parametric definitions. Definitions contain bounded parameters, optional acyclic `derived` expressions, polygon panels, hinge axes and angles, source joins, optional parameter requirements, and optional measured connections. `joins[].overlapMM` accepts the same numbers or scalar expressions as geometry. All geometry and relationship expressions use the existing shared math evaluator.

`create` saves a new source definition and its controls in one Undo transaction. `parameter` changes named values; `configure` replaces a definition. Both accept `expected_revision` from `inspect`. `validate_cases` checks named `cases` and optional `extrema` without editing the project. Case values may include `fold` and `opening` percentages. Results retain the source revision, requested values, folded panel matrices and measured `connection_checks`.

A connection names two panels, one local flat anchor on each, and an expression-based `maximumGapMM`. The evaluator transforms both anchors through the requested fold pose and reports their measured distance and pass/fail result. These are declared neutral-plane measurements. The model author supplies the anchor locations and tolerances.

`convert` explicitly converts an existing envelope or carton to the generic source while retaining its object identity, artwork, stock, annotations, Canvas arrangement and pose. The conversion verifies the current geometry and relationships before making one Undo edit. Its width, height, depth, stock, radius, glue and flap controls remain parametric. Existing projects retain their legacy definition until conversion is requested.

## Reproducing verification

`scripts/smoke_agent_modeling.py` launches a packaged app against a disposable library and exercises an unregistered construction, measured joints, parameter cases, repair, independent evidence, surface binding and persistence. It also checks actual artwork pixels in a GPU-rendered image; run it with a Python environment containing Pillow. `scripts/verify_fabric_workflows.py --app build/LAB.app` runs the existing fabric, sewing, cloth, decoration and production regressions in separate disposable libraries. Both retain logs and reports under `.local/validation`.

For comparable timing, launch each app version against an isolated library and run `scripts/benchmark_agent_modeling.py` using the same saved `--fixtures` file, display quality, view and image dimensions. It records cold evaluation and repeated warm edit-to-image samples, submissions, per-case median/p95 and the aggregate. Review the recorded measurements before claiming an improvement.
