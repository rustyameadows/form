# Paper and packaging: twelve-case implementation and validation

Software validation completed · October 30, 2026

Results and editable deliverable: [twelve-case native validation report](paper-packaging-validation-report.md). The finite coverage, inspected output and remaining manufacturing assumptions are recorded there.

This push implements and validates the [enhanced paper and print finishing brief](enhanced-paper-print-finishing-brief.md) using one editable project containing twelve use cases together on the Table. It also incorporates the supplied discussions about product fit, structural dielines, assembly review, prepress, manufacturer templates and prototype revisions. The brief remains the product direction; this document tracks the concrete implementation and evidence.

## Architecture and authoring contract

Use the existing generic parametric construction, canonical Canvas artwork and projected surfaces. Packaging categories belong in agent-authored example data, not new application-specific generators. A lid, base, insert or envelope liner must be a real independently placed component. Bonded paper plies form one stock with a single authoritative total caliper; front/back artwork is separate from bonding sheets.

MCP must be able to create, inspect, edit, validate, save, reopen and render the same models and materials available in the native app. Extend the existing command families and shared inspector controls. Preserve independent viewport selection, explicit Find navigation, fabric workflows and historical projects.

## Twelve cases on one Table

| # | Use case | Construction and artwork | Material/finish challenge | Additional acceptance |
|---|---|---|---|---|
| 01 | Shipping carton | RSC-style body, bottom/top flaps, glue seam; upright shipping graphics | Brown corrugated-board representation and finite edges | Inspect assembled and opening poses; contents-fit capability is exercised with actual referenced objects in 04/05 |
| 02 | Retail tuck carton | Body, glue tab, tuck/dust closures; upright linked panels | Smooth coated board, flat ink and reflective foil detail | Dimensions and panel labels remain aligned after parameter change |
| 03 | Locking mailer | Die-cut lid/base/flaps, structural slots/tabs and cutout | Recycled board and screen/spot ink appearance | Cuts visible in flat, assembled and technical output; supplier-template fixture retained |
| 04 | Two-piece presentation box | Coordinated lid/base plus actual product and insert | Rigid board, wrap, metallic mark | Lid/base clearance and product orientation; components independently inspectable |
| 05 | Archival clamshell box | Spine/hinged cover, tray and fitted contents | Distinct cover/lining stocks and blind impression | Multiple opening positions and declared interference/joins |
| 06 | Commercial envelope | Front/back, side/bottom bonds and closing flap | Thin uncoated stock and printed addressing | Front/back/inside orientation; dimensions update without stretching type |
| 07 | Invitation envelope and liner | Pointed flap and separate fitted liner | Laid/linen envelope and patterned or translucent liner | Open/closed views show actual separate liner caliper and artwork |
| 08 | Hang tag | Curved outline, real punch hole, double-sided artwork | Textured card, emboss and foil detail | Hole exists in rendered geometry and cut output; safe type placement |
| 09 | Duplex business card | Registered front/back artwork, bonded contrasting plies | Distinct ply colors/edges, deboss or foil | Edge close-up and ply-thickness edit update total caliper coherently |
| 10 | Postcard | Correctly oriented printed front and address back | Recycled stock, smooth contrasting print | Two sides remain independent and editable after reopen |
| 11 | Folded greeting card | Real scored fold, cover/inside/back artwork | Paper grain, flat ink and localized finish | Closed, partially open and open views retain upright reading orientation |
| 12 | Finished invitation card | Editable type and ornamental vectors | Cotton stock, letterpress, blind emboss/deboss and foil | Grazing-light/edge/detail views; wording and finish edits follow source masks |

Use cohesive but distinct editable artwork so misplaced, mirrored, missing or substituted surfaces are apparent. Example 04 includes a modeled product and insert. Cases 07 and 09 distinguish loose components from bonded stock. Case 03 exercises a controlled manufacturer-template workflow. These are acceptance examples, not a fixed catalog or a claim that twelve cases establish support for every package.

## Round 1: audit and baseline

Inventory the existing construction, artwork, material, renderer, MCP and output paths. Record failures before implementation. Build the twelve-case fixture through actual MCP calls; retain request/response evidence and model data. Identify missing capabilities using these examples, rather than adding unrelated features.

Initial code findings:

- Authored paper uses polygon panels and a single connected hinge tree; separate component roots, true interior cuts and product-fit semantics need explicit coverage.
- Paper has real beveled caliper and registered outside/inside artwork, but rendering currently uses generic tooth, fixed roughness and no artwork-driven foil or relief.
- A bounded atlas spans the full net, which can lose fine type at close range.
- Existing stock metadata, preflight and packets do not establish complete duplex/finish, bleed or supplier-template handoff.

## Round 2: implement general gaps

### Construction and fit

Support the declared multi-component, cutout/slot and closure cases using generic authored geometry. The same physical boundaries must drive flat projections, assembled meshes and production paths. Preserve the original canonical source when parameters change.

Fit checks must identify actual referenced contents, their intended orientation, declared clearance/interior volume and insertion opening. Inspect the insert and outer package together. Evaluate declared joins and relevant interference pairs at important fold/opening positions. State which relationships were checked; rigid slabs and sampled poses do not establish springback, glue strength or lock retention.

### Paper and finishes

Provide reusable physical-mm paper appearance controls with identifiable grain/tooth, roughness, color and caliper. Bonded plies have visible distinct edges and a consistent total thickness. Loose liners remain independent components. Keep old projects readable.

Finishes target editable canonical artwork and its side, not a separately painted bitmap. Implement and exercise flat ink, letterpress, blind emboss/deboss and metallic foil; use the screen-print/spot appearance where appropriate. Finish masks must follow text and vector edits. Review stock, ink, relief and metallic channels separately and under lighting that exposes their response. Distinguish shading effects from physical geometry wherever silhouette, edge, shadow or output depends on depth.

Preserve fine text through the entire source-to-atlas-to-render path. Texture resolution, per-panel detail and total memory need explicit bounds for a twelve-case Table; a larger final image cannot restore an undersampled atlas.

### Registered production and templates

Exercise actual bleed around the cut shape; type/graphics safety near cuts, folds and glue areas; and registered print/cut/crease/finish information. Inspect exported files, not merely successful export responses. Retain finish/material intent and all prototype assumptions in revision-specific packets.

For the supported manufacturer-template fixture, retain the original file bytes/hash, units/orientation, technical channels and instructions separately from LAB's editable interpretation. Record inferred fold relationships and geometry changes. Validate at least registered artwork-only and separated technical/artwork handoff modes. Preserve supplier structure only where the importer/exporter actually supports it; do not claim arbitrary PDF/Illustrator layers or spot-color round trips. Supplier instructions determine the required handoff, not a universal file convention.

## Round 3: edit, reopen, render and inspect

For every example:

1. Create it through MCP and inspect its parameters, stock, components, artwork sides and assigned finishes.
2. Produce a whole-object view and relevant front/back/inside/open/closed views. The complete twelve-case Table must remain usable.
3. Change a meaningful dimension, artwork text or shape, material/ply and finish setting as applicable. Verify the native result reflects the current source and preserves intended physical typography size.
4. Exercise native controls and MCP updates; superseded work must not replace a later result. Check Undo/Redo and rejection of malformed or unsupported data without partial mutation.
5. Save/reopen and compare canonical model, IDs, artwork, finish targets, stock and output metadata.
6. Generate and inspect relevant registered cut/crease/print/finish outputs and packet. Verify physical size, holes, inside registration and retained template identity where applicable.

Capture at least one overview, twelve case views and detail views for foil/letterpress/blind relief, paper grain, duplex edges and the liner. Inspect images personally for text readability, orientation, proportions, actual cutouts, contact, edge quality and material response. Valid geometry and nonempty image files do not establish visual quality. Repeat after fixing observed failures.

## Completion gate and evidence

Maintain a twelve-row evidence report with separate construction, artwork, material/finish, MCP, persistence, output and visual results. Each result links to real source, request/response evidence or an actual native render. Mark assumptions, unsupported operations and unrun checks explicitly. Keep attractive presentation images separate from manufacturing verification.

Deliver the editable project with all twelve examples on one Table, replayable MCP fixture data/scripts, reviewed native renders, regression results and a concise coverage/limitations report. Commit and push the implementation and plan, merge the verified change to main, and open the native app with the finished project. Physical sample feedback belongs in project annotations/revision evidence; software cannot substitute for a manufactured prototype.

## Boundaries

This pass does not claim universal packaging support, automatic interpretation of arbitrary supplier documents, press certification, real crease/adhesive simulation, costing/optimal nesting, or the brief's later 100-reference study. These do not block completing the twelve explicit cases, the generic capabilities they require, or a truthful supported supplier-template example.
