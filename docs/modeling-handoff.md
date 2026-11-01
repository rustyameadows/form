# Modeling branch handoff

## Current integration checkpoint — November 1, 2026

Branch: `codex/solid-render-quality`, based on main `a3c79a5`. This is a review branch; do not merge it as part of verification. The original solid-modeling work from [PR #7](https://github.com/rustyameadows/form/pull/7) is already integrated into that main baseline.

The native solid parameter loop is now implemented. Held sliders use transient values and authored editing geometry on bounded background workers; recipes without an editing source evaluate their full geometry off the UI actor. Only a completed valid full result publishes a native edit through the existing parameter command. Supersession and project ownership guards reject late results, Escape retains the accepted source, and successive released controls preserve accumulated intent with separate Undo publication. The Table keeps its camera when a surface completes.

Cold sources are prepared before ordinary Studio captures, print preparation, isolated object views and native `form_solid` inspection/STL export. Final consumers receive full surfaces directly and never substitute the editing preview cache. Linked vector views retain a pending last-valid path until full completion; exports reject pending linked views. Full-cache reuse and actual shared-buffer accounting cover repeated instances and Undo/Redo. [The solid-source documentation](parametric-solids.md) records the implementation and resource limits.

The integrated gate passes 89 test methods with zero failures; the compatibility gate passes 43 with zero failures. Their 14 coordinator methods overlap, giving 118 unique passing methods. All 14 coordinator tests, three surface-worker tests and three native cancellation tests pass. The release build is signed and passes deep/strict signature verification; the ordinary LAB app is running as the sole instance.

Native MCP validation exercised a sampled union at 0.45 mm spacing and an analytic source with 96 path samples and 64 profile sides. The rapid-control/status exercise recorded 14 parameter updates and 15 status requests; its helper roundtrip summary was median 24.07 ms and maximum 55.41 ms. Full-source inspection/revision evidence, STL exports, Undo/Redo, reopening and camera preservation were checked, and three actual 2000 × 1600 native renders were reviewed. Native accessibility slider actions changed Height 146 → 155 and Width 90 → 96; Command-Z restored Width 90 and then Height 146 as separate Undo steps. See [the consolidated validation record](quality-consolidation-validation.md).

These measurements establish the recorded command/control, source and export behavior. They do not measure a physically held mouse drag, hardware-event-to-display latency or frame rate. The private reference-led visual goal below remains incomplete.

## Historical baseline — October 28, 2026

Branch: `codex/project-solid-modeling`, PR base: `main`. That checkpoint reported 1,188 passing tests and packaged LAB 0.5.4 (build 9), including deep/strict signature verification. Its bundle was `.local/solid-upgrade/LAB.app`; it had not been launched or installed over the ordinary running app. These are historical results, not verification of the current branch.

## Committed application work

- Generic project-owned constructive recipes, scoped expressions, repeated groups, sampled unions and analytic profiled sweeps. User models are project data; no project-specific generator is in application code.
- Shared full-detail geometry for Table, Studio, inspection and STL export, with bounded construction and cache limits.
- Thread-safe bounded expression compilation cache. It retains syntax, never parameter values, and preserves grammar/error behavior.
- Optional validated `previewNodes` source (schema 62 after integration), cancellation-aware CPU surface builder, prepared display buffers and separate preview/full cache identities.
- Permanent generic-modeling and actual visual-review requirements in `AGENTS.md`.

## Remaining interaction acceptance

The current checkpoint replaces the historical synchronous slider/Table path with the integrated lifecycle described above. The passing regressions, native MCP sequence, native accessibility slider actions, reviewed renders and full-detail exports establish their specific source, ownership and publication behavior. Physically held pointer-drag responsiveness, hardware-event-to-visible-result latency and frame rate remain unmeasured. Measure those on representative sampled and analytic sources before claiming smooth configurator acceptance. Preserve existing project data, camera controls and the user's parameter choices.

The editing source is selected automatically during a native gesture. There is no new mandatory authoring format, product registration, MCP command or manual Fast/Detail switch.

## Private reference-led model study

The ordinary project retains the original source sheet on Canvas, the additional supplied photograph and an actual model comparison. Multiple bark/crown and whole-master review rounds are retained privately. A detailed 609.6 mm master has editable height, branching, seed and composition controls. Real photographic research includes 24 whole-tree references plus six details with attribution.

**Visual acceptance remains incomplete.** The latest model is an improvement over the rejected baseline, but the crown needs more rounded central leaf volume, branch junction coverage needs review, and the user requested a longer/slimmer trunk with upper growth. Physical height currently scales the construction; a stronger anatomical growth control remains to be implemented. Preserve the original cute sculpted reference as the visual source of truth.

The 24 distinct generated growth configurations and contact sheet were not completed. Smooth configurator footage was not achieved. A separate robust four-inch fabrication adaptation was not completed. The detailed master is an assembly of closed intersecting shells, not a certified Boolean-unioned manufacturing solid. The user reported that slicing eventually worked; no printer commands were sent.

## Handoff assets and boundaries

Private authoring definitions, actual renders, source comparisons, research metadata, performance/resource audits and recording parts are retained locally and in the user project where already saved. They are excluded from Git. Session recordings include actual delays and failures; they are not evidence of a responsive configurator. Existing project data and the user's last parameter choices must be preserved.

The project's `Handoff/README.md` indexes copied authoring sources, 20 actual render-round folders and the reference research. `Exports/LAB-recorded-session-through-handoff.mov` joins all five available recording parts at their original speed: 2:29:58, 3420 × 1644, no audio. Recording interruptions remain documented; the join does not reconstruct uncaptured intervals.

The full remaining checklist is in [generic-solid-modeling-work.md](generic-solid-modeling-work.md). Historical engineering results are in [validation.md](validation.md); passing tests do not complete the model or interaction requirements. No completion claim is made for the paused modeling goal.
