# Packaging design and construction specification

November 3, 2026 · Planned work

Enable a person to choose, construct, decorate, assemble, and render paper packaging entirely through LAB’s native interface. An agent should be an optional collaborator using the same capabilities.

The first complete workflow is **choose a folding carton, sleeve, or envelope; resize it; edit its structure; apply artwork and materials; inspect it; render it**. The full scope extends to assemblies of separate parts, wrapped board, fitted inserts, and curved or flexible paper structures. Completing the first workflow does not complete this broader specification.

## Product direction and existing foundation

Keep the interface approachable through contextual tools: selecting a flap reveals its shape and dimensions; selecting a crease reveals its direction and angle. Support precise fields alongside direct manipulation.

The existing [paper workflow](constructed-paper-goods.md) supplies editable artwork, construction parameters, linked panel/dieline views, fold and opening previews, stock and finishes, and bounded sheet layout/export. The [starter library](starter-object-library.md) provides starting objects. The generic construction model already represents panels, hinges, joins, cutouts, components, and declared interiors.

The principal gap is native structural authoring. Existing controls mostly adjust declared parameters or review a construction. Drawing a new window, reshaping a flap, creating a fold, or changing connections needs native tools and, where necessary, extensions to the generic model.

Provide an explicit, undoable native path from existing envelope, carton, and sleeve starters into the generic editable construction source. Preserve object identity, artwork, materials, and placement; existing projects must not remain trapped in parameter-only editing or change merely by opening them.

This specification supersedes the assumption in [Constructed goods vision](constructed-goods-vision.md) that comprehensive manual editing can be deferred in favor of agent-directed annotation. Preserve that document’s distinction between purpose and representation: **Form, Function, and Fabricate organize the work; panels, dielines, assembled objects, sections, and sheet layouts are views of it.**

## Structural scope

The [two-piece rigid box specification](two-piece-rigid-box-spec.md) details base/lid fit, board layouts, paper and fabric covering, optional lining, taped or stapled joints, and construction packets.

| Capability | Constructions it enables | Required control |
| --- | --- | --- |
| Folded sheets | Cartons, sleeves, envelopes, mailers | Panels, creases, flaps, tabs, windows, slots, notches, perforations |
| Separate assembled parts | Trays, lids, drawers, divided boxes | Connections, alignment, overlaps, clearances, removable components |
| Wrapped and lined construction | Rigid gift boxes, clamshells, presentation cases | Board pieces, covering patterns, corners, turn-ins, seams, liners |
| Packaging fitted to contents | Inserts, holders, multi-item sets | Contents placement, cavities, supports, dividers, access and clearance |
| Curved and flexible construction | Tubes, pillow packs, tapered wraps, paper bags | Curves, bend regions, gussets, seams, supported deformation |

These families are library content authored with reusable capabilities. Follow [AGENTS.md](../AGENTS.md): extend generic tools when needed, then store constructions, parameters, materials, references, and scenes as project/library data. Do not implement a separate application generator or branch for each example.

A package may contain several parts with different stocks. Each part retains its editable flat construction and artwork. Connections, fit relationships, and shared dimensions describe how the parts form an assembly.

Structural joins, opening relationships, presentation poses, and assembly instructions have separate meanings. Exploding a view or moving a lid for a render must not rewrite its construction.

## Native editing surfaces

### Structural drawing

Provide a construction-editing context on the existing Canvas, clearly distinguished from artwork editing. Support:

- Draw and reshape panel contours with vertex/edge handles, straight segments, curves, snapping, dimensions, offsets, symmetry, and repeated features.
- Add a neighboring panel from an edge; split a panel with a crease; merge or remove compatible panels with a review of affected attachments.
- Add or edit windows, holes, slots, notches, perforations, tabs, and glue regions. Boundary notches and cutouts that meet an outer contour require real structural operations.
- Select an individual fold, change direction and angle, and edit its allowance or bend region.
- Create and change joins, closure details, and groups of parts that open together.

Physical structure must drive the flat outline, assembled geometry, artwork clipping, and technical output consistently.

### Assembly and fit

Use the Table to select, position, connect, and inspect parts. Provide precise alignment and clearance controls, section views, isolated parts, exploded views, and individual opening controls alongside whole-package poses.

Support authored folding and assembly sequences. Distinguish a presentation animation from a checked assembly route. Show actionable interference or connection problems on the actual affected parts.

Contents may be existing project objects or assemblies. Derive fitted parts from their geometry and declared clearances. Distinguish interior fit, clearance through the opening, and the insertion route; checking one does not establish the others. Never scale the contents to make a fit succeed.

### Artwork

Retain ordinary editable text, vector, and image tools. Offer upright panel views and the registered flat pattern, with inside and outside surfaces available together. Selecting a face in 3D identifies its source in 2D.

Support explicit placement relationships: fixed sheet coordinates, centered on a panel, offset from an edge, or continuous artwork spanning panels. Preserve physical artwork size unless the user requests scaling. Structural guides, glue regions, safe areas, and print content remain distinguishable.

Changing structure should reveal affected placements and offer repair in context. Source artwork and finish masks must survive view changes and remain editable.

### Materials and construction layers

Allow material assignment to a part or region. Model board, covering paper or cloth, turn-ins, lining, and relevant adhesive layers with their own extents and attachment relationships. Loose liners and inserts remain separate pieces; bonded plies describe bonded material.

Expose stock color separately from printing and coating, with caliper, grain/texture direction, opacity, surface texture, and exposed-edge appearance. Share material and finishing capabilities with [book publications](book-publication-rendering-handoff.md) and [paper finishing](enhanced-paper-print-finishing-brief.md).

Finishes remain attached to editable artwork. Review foil, ink, emboss/deboss, coatings, and relief under appropriate lighting. Geometry must carry details that affect silhouette, overlap, or visible edges.

### Dimensions and relationships

Clearly distinguish usable inside dimensions, outside dimensions, and flat-pattern size. Let users promote a dimension to a named control, set its units and limits, and connect it to another part or the contents. Common relationships should be available visually without writing expressions; advanced expressions may remain available.

Examples include an insert following the tray interior, a lid following the base with clearance, or a sleeve following the assembled package. Show calculated values, authored overrides, and the changes that will propagate. Reject circular or contradictory relationships with a useful explanation.

### Output preparation

Extend the existing sheet review to all package parts, quantities, stocks, grain constraints, and permitted rotations. Keep layout at physical scale and make material usage and parts that do not fit visible.

Prepare separate artwork and technical channels, including cut, crease, perforation, glue, and finish information, with registered inside/outside output. Include dimensioned views and assembly instructions where supported. Files identify their source revision and assumptions.

Provide a native supplier-template workflow: retain the original, confirm scale and registration, map technical layers, and review the interpreted construction. Existing SVG attachment is a starting point; general PDF, Illustrator, or CAD interpretation must be specified and validated format by format. Importing visible lines alone does not establish a folding model.

Production-grade bleed, trapping, tooling, machine-specific allowances, and certified process output require separate acceptance beyond a visual rendering or prototype packet. File preparation does not authorize sending a fabrication job.

## Library and reusable details

Offer complete packages and reusable construction details: closures, tabs, thumb notches, windows, dividers, liners, and hanging features. A detail adapts through declared attachment points and dimensions and remains editable after insertion.

A saved starter contains the complete construction, parts, relationships, material choices, and artwork sources needed to continue designing. Preserve source identity and distinguish independent copies from intentionally linked instances.

Support project resources and reusable Lab resources, consistent with the [Lab library direction](lab-library-vision.md). Users can save their own constructions and materially different variants. Library previews show assembled and flat views and distinguish editable constructions from references.

## Required behavior during edits

| Edit | Required result |
| --- | --- |
| Change stock thickness | Recompute dependent dimensions, fold allowances, overlaps, wrap extents, and fit; identify unresolved assumptions. |
| Resize a package or its contents | Update declared dependent parts while preserving artwork scale and intentional placement. |
| Drag a constrained feature | Show which dimension or relationship changes; retain other applicable constraints. |
| Add, split, merge, or remove a panel | Preserve surviving identities and sources; identify attachments and artwork requiring repair. |
| Replace a closure | Preserve unaffected construction and artwork; expose incompatibilities before accepting the replacement. |
| Open, close, or explode an assembly | Change the relevant pose without rewriting source construction or other saved presentation states. |
| Change a reusable detail | Make the affected instances and overrides explicit. |
| Make an invalid edit | Retain the last accepted design, explain the failure, and support correction or cancellation. |

Native tools and MCP must share validated operations, source identities, save behavior, and Undo/Redo. A complete gesture should form a meaningful Undo step. Preserve existing projects, artwork, source links, camera controls, and saved scenes.

The current polygon and rigid-hinge representation will need generic extensions for curved contours, continuous bends, boundary cuts, regional construction, and relationships across independently stocked parts. Do not force those capabilities into presentation-only geometry disconnected from the editable source.

## Delivery sequence

1. **Native structural editing:** complete the selected carton/sleeve/envelope workflow, including per-fold controls, real contour changes, materials, artwork, and rendering.
2. **Assemblies and dependencies:** add separate parts, fitted contents, shared dimensions, reusable details, independent openings, and repair of affected artwork relationships.
3. **Wrapped and lined construction:** develop covering patterns, corners, turn-ins, layered regional construction, and distinct loose liners.
4. **Curved and flexible structures:** extend geometry and deformation for the declared families, retaining editable flat patterns where supported.
5. **Broader interchange and production:** expand supplier imports, sheet planning, instructions, and process-specific outputs through explicit acceptance.

Plan for assemblies, stable identities, material layers, and dependencies from the first stage. This is a delivery sequence, not permission to remove later capabilities from the target. Render quality and native usability are acceptance requirements throughout.

Predicting crushing, springback, adhesive strength, or closure retention is a separate simulation undertaking. Authored motion, interference checks, and plausible material response must identify what they actually establish.

## Acceptance projects and evidence

All acceptance constructions are project data. Stage 1 must prove native structural editing for all three selected starter families. Complete the following workflows at their corresponding delivery stages through native controls without agent-only construction steps:

- **Windowed carton:** start from a library construction, resize it, reshape a flap, add a window, change a fold/closure detail, place artwork across panels, and apply stock and foil.
- **Sleeve:** in stage 1, resize it, edit its seam/tab geometry, change stock, and review artwork alignment. In stage 2, fit it around an existing assembled object and exercise dependent dimensions and clearance.
- **Envelope and liner:** in stage 1, reshape the closure, add inside/outside artwork, and review open and closed states. In stage 2, add a separate liner with declared dependencies.
- **Wrapped presentation box:** assemble separate base, lid, and insert; author wrapping and lining; inspect corners, turn-ins, edges, and fit.
- **Multi-item package:** arrange differently sized contents, derive supports/dividers and an outer package, then change contents dimensions and review propagated edits.
- **Curved or flexible package:** exercise each supported bend/deformation capability and verify agreement between the editable flat construction and assembled form.

For each stage, retain original references and repeated actual-app reviews at matching whole-object and close-up views. Inspect silhouette, proportions, construction, opening, hidden faces, folds, seams, typography, materials, and finishes. Revise visible discrepancies and retain meaningful before/after evidence.

Preserve materially different configurations by varying dimensions, stock, closures, contents, and assembly composition. Exercise Undo/Redo, save/reopen, invalid edits, and source preservation. Check output scale and registration when that stage includes files.

Use focused tests for geometric and source invariants, and native interaction checks for the actual editing workflows. Assess responsiveness during real structural and artwork edits on representative assemblies. Passing tests, valid geometry, or a polished single view do not establish visual completion.

Before implementing each stage, choose its references, supported construction/process details, representative complexity, and measurable interaction/rendering targets. Record unsupported behavior explicitly rather than silently substituting a different construction.
