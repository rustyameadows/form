# Constructed goods · implementation plan

The [guiding brief](constructed-goods-vision.md) separates purpose (Form, Function, Fabricate) from representation (panels, flat pattern, assembled object). This pass develops paper construction and applies that distinction to supported textile workflows.

## Acceptance sequence

1. Preserve existing projects, artwork, camera bindings, Studio and production routes. Existing four-sided sleeves remain sleeves; new constructions have explicit identities.
2. Develop Sun studies as a top-opening glued envelope: flat back, one side seam, closed bottom, articulated top flap, white toothy uncoated paper, original 8 × 10 contents and editable graphics.
3. Develop a cosmetics straight-tuck carton: real body panels, glue tab, dust flaps and tuck closures. Retain inside/outside artwork and physical dimensions.
4. Generate folded geometry, flat pattern, panel identities, cuts, creases and glue joins from one deterministic construction definition. Preserve source artwork at physical size through dimension changes; flag review needs.
5. Make all three environments useful for the same object. Form emphasizes appearance/artwork; Function exposes construction/fold relationships; Fabricate uses stock, sheet layout, preflight and actual-size outputs. Views remain available independently of environment.
6. Use existing textile pattern, assembly, cloth and production features through task-specific contexts; do not claim new calibrated garment fit or a generalized cloth solver.
7. Run model/geometry/source/persistence/Undo/output regressions, native review loops and the appropriate complete suite. Record actual results, supported limits and revisions; commit and push verified stages.

## Research and assumptions

Established packaging workflows distinguish cut/crease lines, a base panel, explicit board thickness and fold angles. Sources: [Esko board selection](https://docs.esko.com/docs/en-us/studiotoolkitforboxes/14.1/userguide/en-us/common/stb/task/ta_select_the_board.html), [Esko box toolkit](https://docs.esko.com/docs/en-us/studiotoolkitforboxes/12.1/userguide/pdf/studiotoolkitforboxes.pdf).

Mohawk describes Superfine as a premium uncoated paper and offers Eggshell finish and folding board. The visual target is clean white, subtly textured paper rather than glossy plastic. Sources: [manufacturer product sheets](https://www.mohawkconnects.com/education/resources/fine-paper-product-sheets), [manufacturer folding-board announcement](https://www.mohawkconnects.com/press/mohawk-expands-superfine-include-new-folding-board). Local paper thickness and production settings are authored prototype assumptions until measured against the actual stock; a visual preset does not establish manufacturer certification or stocked inventory.

No fabrication is sent or started during this work.

## Implementation checkpoint · October 26, 2026

The sequence above is implemented in LAB 0.4. Sun studies has nine identified panels and eight folds; STILL has thirteen panels and twelve folds, including four dust flaps. Both have registered editable artwork, rigid caliper-aware construction, independent top opening, glued seams, preflight and physical output. Existing sleeves stay unchanged; conversion is explicit and undoable.

Form uses the native vector editor with generated construction overlays. Function uses dimensions, folds, joins and anchored notes. Fabricate uses stock, quantity, physical sheets and local packets. Existing pattern-derived fabric assemblies now expose original construction in Function and full-size/tiled cutting sheets in Fabricate. Studio, navigation bindings and saved source relationships remain available.

Native review caught and repaired a live text-drag rendering defect: recycled CPU addresses could alias retained GPU meshes. Lifetime UUIDs and content-addressed immutable paper buffers now separate geometry identity from paint. A redundant generic artwork plane was removed for paper constructions. Actual mouse drags in the user's affected project preserve the carton, camera and source dimensions; the validation drags were undone while retaining the user's own artwork placement. Narrow split-pane controls use one stable two-row layout and ordinary SwiftUI buttons after native segmented controls exposed a resize repaint defect. Actual Panels narrowing/widening and the Inside/Dieline actions pass; a separate header repaint defect can still appear when the native Dieline canvas is entered. The preview remains clipped to its scrolling viewport.

The complete optimized suite passes **1,133 tests, zero failures/skips**. Packaged checks cover both paper demos, all purpose/representation combinations, fold/opening, source preservation, Undo/Redo, invalid edits, actual PNG/SVG/PDF/packets, restart and original resources; compatibility checks retain the original sleeve, saved Studio renders and local slicing cancellation. Physical proofs are independently rendered with Poppler and reviewed. See [compact evidence](evidence/constructed-paper-native.json) and [workflow/limits](constructed-paper-goods.md).

The constructed-paper goal remains **active** for the native Dieline header repaint acceptance. The reported text-drag → corrupted 3D geometry defect is fixed, installed and verified in the user's project. General garment reconstruction, predictive cloth fit/self-contact, arbitrary packaging generators, crease mechanics, production color/bleed certification and machine execution remain broader roadmap work. No fabrication was sent or started.
