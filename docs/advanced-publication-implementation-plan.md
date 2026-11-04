# Advanced publication implementation and acceptance plan

This implements [the November 3 handoff](book-publication-rendering-handoff.md). The physical authority remains the existing sheet assembly. Covers, jackets, cases, artwork, references and scenes are authored project data; there is no built-in book recipe or parallel renderer.

## Decisions and references

- Keep the 200-page publication limit. Review a 128-page sewn hardcover, a 96-page adhesive softcover with flaps, and an ordered 64/128/192-page three-volume set. Exercise sewn softcover and different stocks as variants.
- Use [TALAS's casing-in reference](https://blog.talasonline.com/post/how-to-case-in-a-text-block) for board, cloth, mitered turn-in, hinge and endpaper relationships; [Blurb's cover construction guide](https://support.blurb.com/hc/en-us/articles/47180049530637-Cover-types-for-Blurb-Photo-books) for the separate flexible, wrapped and jacketed cover constructions; and [Folio Society's three-volume Foundation set](https://www.foliosociety.com/uk/the-foundation-trilogy) for case/volume relationships. Reference construction and proportions, not copyrighted cover designs or prose.
- Page-edge art registers over the closed block. [Chetham's fore-edge collection](https://library.chethams.com/collections/101-treasures-of-chethams/fore-edge-painting/) supplies a visual reference for individual leaf-edge detail; hidden fanned-edge painting is a different registration convention.
- All board gaps, swell, adhesive, wrap, turn-in and case fit allowances are editable rendering assumptions. These are not verified manufacturing tolerances.

## Delivery sequence

1. **Shared dependencies and materials.** Add bounded, cycle-checked cross-object dimension expressions; resolve dependent parameters and source extents atomically in the existing Undo transaction. Add nonprinting named construction regions with explicit artwork anchors that translate, never scale, original artwork. Retain mixed stock, grain, texture, ply, finish and canonical source ownership.
2. **Physical construction, developed together.** Add gathered signatures, adhesive and sewn bindings, optional endpaper/auxiliary leaves, and crop-independent closed-envelope measurements. Extend generic panels with real wrap/turn-in, outline/cutouts, caliper expressions, flexible hinges and stepped recesses/inserts. Keep old nil-field rendering unchanged. Reuse paper texture, relief, foil and sampling infrastructure.
3. **Complete the workflows.** Expose structure, panel, source and stock edits through the existing native publication inspector and typed MCP. Add registered head/tail/fore-edge sources. Author editable jackets and cases through enclosure panels plus the shared dimension graph. Case width derives from the ordered list of closed volumes and fit allowances; cover artwork crops remain at physical scale.
4. **Review and integration.** Run focused model/dependency/schema/Undo/persistence/renderer tests. Build one ordinary LAB update and review real native examples. Retain each meaningful visual round and discrepancies. Correct construction and material defects before PR review and merge.

## Acceptance matrix

| Requirement | Evidence required |
| --- | --- |
| Editable front/spine/back/flaps/wrap | Canonical Canvas sources, named construction guides, finishes and dimension changes retaining layer IDs, type size and anchored placement |
| Hardcover | Closed/partial/180° views, board overhang, hinge, underside, mitered corner, endpaper attachment, foil/relief and recessed photo close-ups |
| Softcover | Separate closed/partial/180° views, flexible crease/flaps, adhesive and sewn variants; no rigid-board substitution |
| Stock distinct from ink | Pale yellow unprinted stock, white/full-color and mixed interior stocks; cover/endpaper/edge consistency |
| Signatures/spines | Several independent gathered signatures, stitching, caliper-derived body thickness plus explicit binding/endpaper allowances |
| Edge artwork | Image/type/pattern on three block edges; closed registration and corresponding open/fanned leaf edges |
| Jacket/case | Editable physical-size jacket; one- and three-volume wrapped cases; dimensions/order/fit changes propagate without consuming the book objects |
| Durability | Page-count, trim, stock-caliper and construction variants; native controls and MCP agree; save/reopen and Undo retain sources and dependencies |

Production dielines, press imposition/creep compensation, tooling and verified manufacturing tolerances remain the expressly deferred phase. The generic features and authored acceptance project are implemented. Native closed/open/detail comparisons, source-preserving parameter variants, exact Undo/Redo, save/reopen and original-project preservation are recorded in [the validation report](advanced-publication-validation.md). The checked-in project and retained evidence are in [the example handoff](../examples/advanced-publications/README.md). Opening is a controlled rendering pose, including an explicitly idealized active gather; it is not a mechanical bindery simulation.

## Completion record

- Shared dimension/material dependencies, physical panels, native controls and public MCP: implemented.
- Separate hardcover/adhesive and sewn softcover, gathers, auxiliary sheets, edge registration, jackets and ordered cases: implemented and authored through public tools.
- Nine native review rounds include rejected first constructions, corrected covers, material refinement and final installed-build reviews.
- The final native package has 505 objects, four publications and 23 saved scenes. All 496 original files in nine existing user projects remain byte-identical.
- Integration includes the current main documentation commits. The final PR carries the implementation, regression tests, native project, plan, API contract and evidence.
