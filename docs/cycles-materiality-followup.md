# Cycles and materiality follow-up

This pass starts from PR #36 at `7c377931`. The user selected **Paper and finishes** as the priority. The ordinary app at the start is the previously reviewed candidate 6; its renders are a baseline, not acceptance of this revision. Named material studies remain project data.

## This pass

- [x] Inspect actual LAB cloth and embroidery macro renders and the original material references; preserve the open user project's 11 protected fields before editing.
- [x] Correct anisotropic reflection so mesh highlights follow authored UV direction. The actual before-render checks show Cycles supplies a generated geometry direction in the baseline fixture; triangle permutation alone already passes. Preserve longitudinal curve tangents and verify triangulation, rotated/mirrored mappings, and CPU/Metal behavior.
- [x] Add independent paper cut-edge appearance with physical edge coordinates, per-stock/per-ply control, legacy decoding, strict MCP editing, and unchanged fabrication geometry.
- [x] Add a physical relief shoulder radius for letterpress, embossing and foil, separate from crisp artwork coverage and manufacturing depth/height. Preserve the legacy transition when the field is absent.
- [x] Author restrained paper edge fibers and compare materially different finish shoulders in the editable study through ordinary LAB tools. Retain previous definitions and failed trials.
- [x] Preserve the current Studio lighting when converting a preset into editable area lights or adding a light. Verify native controls, persistence, and Undo.
- [x] Show the selected texture map, its dimensions/encoding and physical repeat size in the native appearance editor; identify local versus inherited surface appearance.
- [x] Make saved paper stocks portable across projects by preserving and verifying their face, back, ply and cut-edge texture files. Preserve existing project material identities and ordinary built-in material selection.
- [x] Capture matched whole, macro, and changed-light LAB comparisons. Record discrepancies honestly; do not substitute test results for visual review.
- [x] Build, validate, and install the verified candidate in the single ordinary LAB location with a rollback. Restore the user's original project and camera.
- [x] Run focused contracts and regressions, publish reproducible evidence, commit, and push to [PR #36](https://github.com/rustyameadows/form/pull/36).

## Follow-on work to evaluate separately

- Add physically scaled, project-authored thread filament detail and restrained correlated yarn/color variation, then improve cloth folds through generic project tools.
- Round thread curves still limit contact flattening and compact sewn endpoints. Evaluate render-only cross-section/contact controls against macro evidence after the fiber-map pass.
- Material draft preview and display-only exposure changes could shorten iteration; they need explicit cancellation, Undo, and display-transform contracts.

The follow-on items are open work, not claims of completed fidelity. Manufacturer photographs stay linked/private when redistribution rights are unavailable. New derived assets must record their licenses, physical repeat size, and estimated rather than measured parameters.

Final installed implementation gate: **2,741 release tests passed, zero failed; three optional external-project performance tests skipped**. All 28 focused integration checks and 43 Python checks pass. The exact signed candidate at `20f27b83` integrates current main and passed relocated CPU/Metal checks with development paths and network denied. It is installed in the ordinary app with a rollback. Five unchanged saved controls rendered at 512 samples and passed qualitative integration review. The current 40-object Metal Table preview completed at 64 samples; native save/reopen preserved all 11 study fields. The original project's 11 protected fields and Canvas selection were restored. See [installation](validation/cycles/materiality-followup/main-installation.json), [replays](validation/cycles/materiality-followup/main-replays.json) and [native verification](validation/cycles/materiality-followup/main-native.json).

Earlier native material edits, Cancel, Undo/Redo, lighting conversion and two edited objects' save/reopen were verified on `2477730`; [that evidence](validation/cycles/materiality-followup/native-interactions.json) retains its original binary identity. The edge assets reproduced byte-for-byte. Current integration also preserves independent construction stocks/finishes, separates schema 66/67/68 requirements, excludes editor-only Canvas placement from physical render identity and compacts the complete MCP catalog within the unchanged bundle limit.

Visual review retained 27 paper renders plus one unchanged satin sanity control. Selected revisions use edge normal strength 1 and 0.16 mm relief shoulders; macro, whole-card, positive/negative and reversed-light views show the intended changes. Earlier subtle trials and clipped framing remain in the project with immutable definitions. These are artist-estimated material/construction controls, not measured manufacturer optical matches. See [actual comparisons](validation/cycles/materiality-followup/README.md).
