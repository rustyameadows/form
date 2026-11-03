# Book publication rendering handoff

November 3, 2026 · Planned work

Extend LAB’s existing publications so a designer can create cover artwork in 2D, specify materials and construction, and render the intended physical book convincingly. Give **hardcover and softcover equal emphasis**, while preserving booklet and magazine workflows. Deliver faithful editable rendering first; production-ready manufacturing outputs follow later.

## Existing foundation

Reuse the publication pages, stories, linked artwork, physical sheet assemblies, stock and finish system, and Studio. Stock color already exists independently of printed artwork, including nonprinting Canvas previews. Assemblies calculate leaf-stack thickness and support authored enclosure planes, folded parent sheets, and staple bindings. The next work is a coherent book-design workflow and more faithful construction and rendering.

See [Publications](publications.md), [Multi-sheet publications](multi-sheet-publications.md), and [Paper and print finishing](enhanced-paper-print-finishing-brief.md). Current opening geometry is idealized; the existing folded-sheet arrangement is not a complete sewn-signature system.

## Required capabilities

- **Design covers in 2D.** Keep front, spine, back, and applicable flaps or wrap areas connected to editable artwork at physical size. Show construction guides and assign materials and finishes during design. Dimension changes update guides and surface mappings while preserving artwork scale and intentional placement.
- **Hardcover construction.** Support board cores wrapped in paper or cloth, with visible board thickness, cover overhang, hinges, wrap turn-ins, and corners. Include endpapers and their attachment, emboss/deboss and foil, and a photo inset with actual recess and edge relationships. Material texture, relief, and reflective finishes must hold up under close inspection.
- **Softcover construction.** Support flexible cover stocks, spine and hinge creases, optional flaps, and glued or sewn book constructions. Cover flex, page curvature, and opening behavior should reflect the chosen construction. Softcover receives its own visual acceptance, beyond changing a hardcover’s material.
- **Paper stock and finishes.** Make “pale yellow stock” an obvious material choice, distinct from printed yellow ink or a surface coating. Support separate cover, endpaper, and interior stocks, including mixed stocks. Color, caliper, grain, opacity, texture, and cut-edge appearance should stay consistent across the editor and rendering.
- **Spines, folds, and signatures.** Derive text-block thickness from actual leaves and stock calipers, then account for the chosen binding, endpapers, and relevant construction allowances in the finished cover/spine dimensions. Support multiple gathered signatures, believable folds and creases, visible stitching where appropriate, and binding-specific opening poses. Keep assumed allowances editable; visual plausibility does not establish manufacturing accuracy.
- **Page-edge artwork.** Support solid colors and full images, patterns, or typography on the head, tail, and fore-edge of the page block. Keep these treatments separate from stock color and page-face printing. Register artwork across the closed block and map it to the corresponding leaf edges so it remains coherent when pages open or fan.
- **Derived jackets and cases.** Generate an editable dust jacket with spine and flaps, and a fitted slipcase for one book or multiple volumes. Support chipboard with paper or fabric wrapping and the same artwork/material/finish workflow. A three-volume set should drive one enclosing case. Book dimensions, stock, page count, volume order, and fit allowances must update dependent layouts and geometry.

## Implementation order

1. Establish shared material, construction, and dimension dependencies; expose them through native controls and MCP.
2. Develop hardcover and softcover together, including cover artwork, binding, signatures, and open/closed behavior.
3. Add page-edge artwork and derived jackets/cases, then review the complete workflows.

Build reusable capabilities. Keep example books, material choices, references, and scenes in project data, following [AGENTS.md](../AGENTS.md).

## Acceptance and remaining decisions

Use reference-led hardcover and softcover projects plus a three-volume case. Review actual app renders closed, partly open, fully open, from the spine and underside, and at cover/hinge/corner/page-edge close-ups. Compare and revise silhouette, construction, typography, material response, and finish detail; retain evidence of meaningful iterations.

Vary page count, stock thickness, trim size, cover construction, and volume sizes. Verify artwork and dependent geometry update, edits remain available after save/reopen, and Undo works. Passing tests or an attractive single view do not establish visual completion.

Before implementation, select the references, initial binding styles, and target book lengths; publications currently have a 200-page limit. Reserve production dielines, press imposition and creep compensation, tooling, and verified manufacturing tolerances for a later phase.
