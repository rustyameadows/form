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

Native review caught and repaired a live text-drag rendering defect: recycled CPU addresses could alias retained GPU meshes. Lifetime UUIDs and content-addressed immutable paper buffers now separate geometry identity from paint. A redundant generic artwork plane was removed for paper constructions. Actual mouse drags in the user's affected project preserve the carton, camera and source dimensions; validation drags were undone while retaining the user's own artwork placement.

The remaining Dieline header repaint defect came from native canvas/ruler drawing beyond their bounds. AppKit can supply a dirty rectangle extending outside a view; filling that rectangle erased neighboring SwiftUI labels. Explicit canvas, scroll-view and ruler clipping plus a bounds-only fill repair the cause. A bitmap regression reproduces **8,448 changed neighboring pixels** before the repair and **zero** afterward. Context transform and clipping are restored for subsequent sibling drawing. This follows [Apple's AppKit guidance](https://developer.apple.com/videos/play/wwdc2023/10054/). Actual Dieline entry, inside/outside actions, fit/scroll and split resizing from 854.5 to 440 to 855 points retain the controls and labels.

The complete optimized suite passes **1,135 tests, zero failures/skips**, including both drawing-boundary regressions. The signed final package passes both paper demos, all purpose/representation combinations, fold/opening, source preservation, Undo/Redo, invalid edits, actual PNG/SVG/PDF/packets, restart and original resources. Compatibility checks retain the original sleeve, saved Studio renders and local slicing cancellation. Physical proofs are independently rendered with Poppler and reviewed. See [compact evidence](evidence/constructed-paper-native.json) and [workflow/limits](constructed-paper-goods.md).

## Acceptance audit

| Requirement | Accepted behavior and evidence |
| --- | --- |
| Envelope revision | Nine panels/eight folds; flat back, one side seam, bonded bottom, independent top opening; white uncoated appearance and editable cyanotype graphics. Core topology/fold checks, packaged open/flat/closed renders and physical sheet proof. |
| Cosmetics demonstration | Thirteen panels/twelve folds; four body faces, glue tab, four dust flaps and two tuck closures. Separate inside message and original outside graphics. Geometry, live native artwork and physical output checks. |
| Connected source/views | Stable panel/fold/join identities drive net and assembly; Panels focuses the same Dieline source. Nine purpose/view combinations preserve source and camera; dimension edits preserve physical artwork and raise review. Undo/Redo and restart pass. |
| Distinct purposes | Form edits graphics, Function develops dimensions/folds/notes, Fabricate prepares stock/count/sheets/outputs. Actual native Apply/Undo, panel selection, opening and paper Print routing verified. |
| Existing fabric workflows | Function exposes original pieces/allowances/grain/notches/seams and assembly/cloth controls; Fabricate reviews original full-size/tiled patterns and supported production routes. Existing source remains shared. |
| Preservation and performance | 96 native drag steps/GPU captures, 64 mesh-lifetime instances, bounded immutable caches, appearance independence and current installed mouse drag pass. User objects/history/camera restored exactly; 128 original files and 35 existing Studio records remain exact. |
| Local output and handoff | Millimeter cut/crease/artwork SVGs, actual-size PDF and exclusive hashed revision packets; three-carton/one-sheet and three-envelope/two-sheet layouts reviewed independently. No hardware commands. |

The bounded constructed-paper pass is accepted. Both rendering repairs are installed in the normal LAB application and verified in the user's project. Optional simultaneous pinned 2D representations, arbitrary manual packaging construction and animated representation transitions remain future enhancements. General garment reconstruction, predictive cloth fit/self-contact, crease mechanics, production color/bleed certification and machine execution remain broader roadmap work. No fabrication was sent or started.
