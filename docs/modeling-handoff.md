# Modeling branch handoff

October 28, 2026. Branch: `codex/project-solid-modeling`. PR base: `main`.

## Committed application work

- Generic project-owned constructive recipes, scoped expressions, repeated groups, sampled unions and analytic profiled sweeps. User models are project data; no project-specific generator is in application code.
- Shared full-detail geometry for Table, Studio, inspection and STL export, with bounded construction and cache limits.
- Thread-safe bounded expression compilation cache. It retains syntax, never parameter values, and preserves grammar/error behavior.
- Optional validated `previewNodes` source (schema 57), cancellation-aware CPU surface builder, prepared display buffers and separate preview/full cache identities.
- Permanent generic-modeling and actual visual-review requirements in `AGENTS.md`.

## Important incomplete integration

**Native parameter dragging is not fixed.** The editing-preview source and worker are foundations. The native slider path still commits synchronously through `ParameterControl` → `StudioStore.update` → `form_update_object`, and Table still requests geometry synchronously. No native Fast/Detail switch, latest-result publication or drag draft/coalescing controller has been integrated. Do not describe these foundations or expression microbenchmarks as smooth UI acceptance.

Next implementation: lightweight project-authored preview geometry; immediate native draft values; background validation/build; cancellation and stale-result rejection; one Undo per gesture; explicit detail selection; full-detail-only production/export. Measure real mouse-drag latency/frame behavior and record the result. Preserve camera controls and user parameters.

## Private reference-led model study

The ordinary project retains the original source sheet on Canvas, the additional supplied photograph and an actual model comparison. Multiple bark/crown and whole-master review rounds are retained privately. A detailed 609.6 mm master has editable height, branching, seed and composition controls. Real photographic research includes 24 whole-tree references plus six details with attribution.

**Visual acceptance remains incomplete.** The latest model is an improvement over the rejected baseline, but the crown needs more rounded central leaf volume, branch junction coverage needs review, and the user requested a longer/slimmer trunk with upper growth. Physical height currently scales the construction; a stronger anatomical growth control remains to be implemented. Preserve the original cute sculpted reference as the visual source of truth.

The 24 distinct generated growth configurations and contact sheet were not completed. Smooth configurator footage was not achieved. A separate robust four-inch fabrication adaptation was not completed. The detailed master is an assembly of closed intersecting shells, not a certified Boolean-unioned manufacturing solid. The user reported that slicing eventually worked; no printer commands were sent.

## Handoff assets and boundaries

Private authoring definitions, actual renders, source comparisons, research metadata, performance/resource audits and recording parts are retained locally and in the user project where already saved. They are excluded from Git. Session recordings include actual delays and failures; they are not evidence of a responsive configurator. Existing project data and the user's last parameter choices must be preserved.

The full remaining checklist is in [generic-solid-modeling-work.md](generic-solid-modeling-work.md). Historical engineering results are in [validation.md](validation.md); passing tests do not complete the model or interaction requirements. No completion claim is made for the paused modeling goal.
