# Two-piece rigid setup box implementation plan

Completed November 4, 2026. The [acceptance record](two-piece-rigid-box-validation.md) documents native operation, final render/file review and the editable [CASK study](../examples/two-piece-rigid-boxes/README.md). Implementation is in [PR #37](https://github.com/rustyameadows/form/pull/37).

Implement [the complete separate-board specification](two-piece-rigid-box-spec.md) on the existing authored planar construction system. The source defines the box, option sets, materials, artwork, patterns, joints and scenes. Application code provides reusable part assemblies, joints, covering, layout and export operations.

## Construction and references

Use separate floor/top and wall boards, with independently stocked base and lid. The default dimensions describe finished usable base space; a visible alternative holds finished outside size. Running clearance is per side and remains separate from overlap, axial headspace and optional insert clearance. Stock, coverings, lining, tape, seams, adhesive and exposed staple buildup contribute to the finished fit.

References selected before implementation:

- [Horda rigid-box process](https://www.hordamachinery.com/machine-knowledge/how-are-rigid-boxes-made): structural shell, separate covering, turn-in and lining stages. It supplies a process reference, not a universal cut allowance.
- [NAPCO terminology](https://napcousa.com/terminology/): tray/lid/telescope and turn-in relationships; choose and record this study's allowances explicitly.
- [TALAS cloth construction](https://blog.talasonline.com/post/paper-backed-vs-starched-bookcloth): backed cloth is a real layered stock, distinct from starch-treated cloth and printed appearance.
- [Deluxe box stitchers](https://www.deluxestitcher.com/machines-box): receiving geometry and tool/clincher access matter. Supported board-joint staples will have finite leg paths through the declared parts; unsupported corner decoration must reject.

Review matching original reference/actual-app whole objects and details. Never infer strength, sliding feel or verified machine settings from a geometric fit.

## Connected implementation stages

1. **Generic part assemblies and finished dimensions.** Extend authored planar source with independently stocked cut-piece trees, stable parent transform groups, saved enabled options, actual stock envelopes and source-described native controls. Complete a resource-backed editable starter and guarded adoption of the existing study. Keep old documents unchanged when optional fields are absent.
2. **Joints and reinforcement.** Add declared bonded regions, actual tape strips and generic anchored staples. Resolve intended part engagement, entry/exit, receiving depth, edge distance, termination and access. Carry the same source into geometry, fit reports, quantities and instructions. Invalid edits retain the accepted construction.
3. **Physical covering, lining and artwork.** Author complete cut blanks and wall-band/patch alternatives through ordinary panel/hinge/component data. Retain real turn-ins, edge traversal, seam overlaps and corner reliefs. Lining can be none, floor/top only, walls only or full, independently per half. Keep saved disabled sources/options for restoration. Canonical artwork and finish masks stay at physical scale under dimensional changes.
4. **Complete construction files.** Resolve each component tree as a physical cut piece. Produce revision-linked cut lists, actual-size SVG and PDF patterns/proofs, independently packed material sheets/rolls, tape/staple schedules, assembly/section drawings, registered artwork/finish files and a hashed editable-source manifest. Guide folds are separate from cut/score/groove channels. Existing exported revisions are immutable.
5. **Native acceptance and refinement.** Perform the complete native design/edit/preview/apply/pose/export workflow. Use public MCP for the same validated operations. Inspect actual app views and revise discrepancies before handoff.

## Required editable configurations

| Configuration | What must differ materially |
| --- | --- |
| Paper, taped, unlined | Real tape and covering turn-ins; exposed interior board/joints |
| Paper, independently lined halves | Separate lining stocks/pieces, capacity and lid-opening changes |
| Fabric with paper lining | Real cloth/backing/caliper, contrasting lining, weave and corners |
| Supported board staples | Uncovered engagement/termination and then covered buildup |
| Mixed halves, partial overlap | Fabric/paper independent stocks; one unlined half; visible reveal |
| Unequal board calipers, deep lid | Independent floor/wall/base/lid calipers, changed size and fit |

Keep closed, partially lifted, removed-lid, underside, uncovered, exploded and section/detail views. A lid group carries every attached piece; presentation does not alter dimensions, source patterns or cameras.

## Validation gates

- Native choose/create/adopt, dimension reference, arrangement, independent stock, wrapping/lining, tape/staple, artwork and export controls are usable without agent-only authoring steps.
- Size, caliper, wrapping/lining thickness, seam location, tape width, staple placement, lid depth and overlap propagate to actual geometry, source patterns, fit and packet. Artwork IDs, physical type size and intentional anchors survive.
- Reject impossible dimensions, unengaged/unsupported staples, conflicting locked fits and unintended collisions atomically; expose the affected IDs and repair.
- Independently compare packet scale, contours, IDs, stocks, quantities, grain/rotation constraints, artwork/finish registration and assembly order with the native model.
- Prove Undo/Redo, lining restoration, materially distinct variants, save/reopen and stale-output invalidation. Preserve all existing user projects and camera controls.
- Run focused Core/App/export regressions, then native visual and interaction review. Retain meaningful failures and corrections. Tests and mesh validity do not establish appearance.

The separate-board workflow includes all stages above. Scored or V-grooved board constructions remain the specification's explicit follow-ons. Physical fabrication and machine commands are outside this work.
