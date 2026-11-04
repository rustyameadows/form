# Native 3D modeling specification

November 3, 2026 · Planned work

Make LAB a native 3D editor for artists creating toys, stylized characters, sculpture, and decor for 3D printing. A person must be able to open an empty Table and build, reshape, save, and prepare an object entirely through direct editing.

The defining requirement is a **blank-Table modeling experience**. An agent, generated image, prepared model, template, or separate Canvas document is not required. Agent assistance and reusable starters can use the same capabilities, but cannot substitute for the native workflow.

Prioritize expressive form, proportion, silhouette, soft connections, and reversible experimentation. Precision controls support that work. Integrated electronics and detailed mechanical engineering remain later product work.

## Existing foundation and actual gaps

LAB already has substantial geometry infrastructure. This work combines native interaction, editable-source infrastructure, and new geometry capabilities.

| Area | Existing foundation | Required work |
| --- | --- | --- |
| Exact solids | Open CASCADE primitives, Boolean operations, fillet/chamfer, shell, extrusion, revolution, sweep, loft, transforms and patterns | Native creation, drawing, selection, manipulation and operation authoring |
| Exact construction history | Persistent feature IDs, parameters, dependencies, revision guards and last-valid-result retention | Add/remove/reorder/rewire features through native controls; repair affected references |
| Organic forms | Sampled segments and ellipsoids with ordinary/smooth union; analytic profiled sweeps | Native part editing and persistent part identities; richer shapes, subtraction, intersection and hollowing |
| Deformation | Authored sweep paths, varying sections and roll; tapered segments | General bend, twist, taper and regional deformation of existing shapes |
| Selection and transforms | Component hits, CAD triangle-to-face mappings, exact affine transforms; object placement largely XYZ position plus yaw | Face/edge/control-point selection, highlighting, full XYZ rotation/scale, pivots and local axes |
| Sculpting and mesh operations | Mesh import/display and bounded surface generation | General mesh Booleans, conversion between representations, brush editing, localized updates and remeshing |
| Printing | Native preparation, local Orca slicing, layer preview and export | Better modeling-to-print continuity, repair, splitting and fabrication adaptations |

See [CAD operations](cad-operations.md), [CAD feature graph](cad-feature-graph.md), [parametric solids](parametric-solids.md), and [print preparation](printing.md).

The current CAD editor primarily changes parameters and scalar expressions on existing constructions; its profile preview is not a drawing editor. Organic recipe construction is primarily authored through MCP. Exposing more parameter fields alone does not meet this specification.

## Blank Table and direct interaction

An empty modeling workspace presents the Table, a compact modeling toolbar, an object/construction list, and contextual properties. Users can immediately add or draw geometry. Preserve existing orbit, pan, zoom, and camera conventions.

Provide object, body, face, edge, profile, path, and control-point selection as appropriate to the active tool. Make hover, selection, hidden operands, and affected geometry understandable. Selecting an item in the construction list locates it on the Table and vice versa.

Manipulators support translation, rotation and scaling on all three axes, local/world orientation, editable pivots, snapping, alignment, and precise numeric entry. Dimension handles edit the intended shape parameter where available; occurrence transforms retain their distinct meaning.

An active tool provides a useful preview, confirmation, cancellation, and contextual controls. Interactive dragging must remain responsive while geometry evaluates. A completed gesture produces a meaningful Undo step. Failed or cancelled work retains the accepted source and usable view.

## Native modeling tools

### Shapes and composition

Create boxes, spheres/ellipsoids, cylinders, cones, capsules, rings, and profile-based forms with editable dimensions. Provide duplicate, independent copy, linked instance, grouping, alignment and symmetry controls.

Joining bodies must remain distinguishable from grouping them for movement. Users can choose a body and its operands, change their placement, and inspect the resulting construction without losing access to the original shapes.

### Joining, cutting and finishing

Offer union, subtraction and intersection for supported bodies, plus soft blending for organic construction. Show which operand adds or removes material and provide a reversible way to edit it.

Provide edge rounding/chamfering, trimming, supported hollowing, wall-thickness controls, flat-base cuts, and splitting. Keep operation scope and affected parts visible. A general face-pull tool requires explicit modeling support; existing extrusion alone does not establish arbitrary direct face movement.

Organic cuts and hollowing require new field or mesh operations. Exact shelling cannot be presented as arbitrary mesh hollowing. Unsupported input combinations must offer a clear supported path rather than silently producing display-only geometry.

### Drawing forms on the Table

Create a workplane in space or on a supported face. Draw and edit lines, arcs, curves, closed profiles and holes directly in that context. Offer snapping, alignment and dimensions without requiring expression entry.

Extrude or revolve profiles, sweep a section along an editable path, and loft between sections. Keep profiles, path points, sections and resulting solids accessible for later edits. Drawing these inputs must not require leaving the Table for a separate Canvas document.

Basic profile editing can use existing curve geometry. A comprehensive geometric constraint solver is separate core work if later requirements include maintained tangent, coincident or equal-length relationships beyond the initial controls.

### Expressive shaping and repetition

Make soft joins, symmetry, proportion handles and editable curves prominent in the artistic workflow. Support taper, bend, twist and regional shaping with visible influence and useful handles. These are generic modifiers with stored parameters and operands.

Provide linear, circular and path-based repetition with editable count, spacing and orientation. Distinguish linked instances from independent copies. Repetition does not imply that touching parts have been fused.

Part-specific controls, such as an ear’s length or a vessel’s profile, arise from the project’s construction. They must not require application branches for individual designs.

### Surface detail and materials

Reuse LAB’s material and artwork capabilities. Permit a drawn shape or supported artwork source to become a placed graphic, raised detail, or recessed detail through explicit tools. Separate appearance from geometry that will actually be printed.

Preserve artwork scale, material assignments and finish targets through supported edits. Report lost or ambiguous surface references for repair. Existing planar artwork binding is a foundation; arbitrary curved-surface placement needs its own implementation and acceptance.

### Sculpting expansion

Plan a later sculpting layer with grab, smooth, inflate, crease, masking and symmetry, supported by an editable surface or volume representation, stroke Undo, localized updates, remeshing and detail preservation.

This is additional modeling infrastructure. The first native modeling milestone must deliver expressive shape construction and soft joins without implying that clay-style brushes already exist.

## Editable source and reliable changes

Every accepted native operation must retain editable intent, meaningful operands and stable identities. Build on the exact feature graph and extend organic definitions with persistent part/node identities. Provide native operation creation, removal, suppression, duplication and dependency-aware ordering.

Users must be able to resize an earlier shape, move a cutting operand, or change a blend while preserving valid downstream work. When a reference becomes ambiguous, identify the affected feature and support repair. Never silently attach an operation or material to an unrelated face.

Retain the last valid result while an edit evaluates or fails. Prevent stale asynchronous results from replacing a newer edit or another project. Preserve pending intent, cancellation, Undo/Redo, save/reopen, and camera state across the workflow.

Exact solids, sampled organic forms, analytic sweeps and imported meshes have different capabilities. Provide consistent user-facing operations while preserving their source meaning. Any conversion that changes editability or detail must be explicit, reversible and retain the original. Imported geometry does not acquire invented construction history.

Native tools and MCP should share validated modeling operations and persistence. Native users must be able to create and repair the complete construction without supplying JSON, scripts, formulas, or agent requests.

## Geometry and library decisions

Retain Open CASCADE for existing exact operations. No replacement kernel is indicated for the initial solid/profile editor. Build native interaction and source integration around the working geometry.

Extend the organic system for the required operand types, field operations and deformations. A swept curved part is not a general bend modifier. The current sampled union engine is not a sculptor, and appended analytic shells are not a fused manufacturing solid.

Evaluate a focused mesh or volume backend where existing representations cannot support robust combinations, hollowing or remeshing. [Manifold](https://manifoldcad.org/docs/html/) is a candidate for mesh Boolean operations on suitable solid meshes; it is not a decision to adopt it or a complete sculpting system.

Use bounded prototypes to compare capability, output quality, preservation of source/materials, macOS integration and interactive performance before adding a dependency. Keep geometry-library details behind the native editing tools.

Application code supplies reusable tools. Models, named controls, references, reusable parts and presentation scenes are project/library data, following [AGENTS.md](../AGENTS.md).

## Printing and presentation

Connect the editable object to existing Studio and print preparation. Preserve the detailed master while creating explicit fabrication adaptations for size, fragile details, fusion, wall thickness, flat bases, part splits and supported assembly connections.

Inspect actual dimensions and geometry appropriate to the selected printing process. Distinguish disconnected shells, intersections and a fused solid. Closed topology alone does not establish adequate wall thickness or a successful print.

Model changes invalidate stale fabrication results. Final renders and exports must use the accepted full-detail source or the explicitly selected fabrication adaptation; transient editing previews cannot silently replace them.

Preparing or exporting files does not send a print or authorize printer motion/heating.

## Delivery sequence

1. **Editing foundation:** establish blank-Table creation, selection, full transforms, persistent part identities, native operation authoring and reliable preview/Undo. Exercise both exact and organic sources.
2. **First complete artist workflow:** combine native shape construction, soft joins, cuts, symmetry, proportion editing and useful detail into a convincing stylized character. Add the generic geometry operations this workflow requires.
3. **Broader form making:** complete profile/path tools, repetition, general deformation, hollowing and splitting across the declared supported representations. Exercise sculpture and decor as independent uses.
4. **Mesh and sculpting expansion:** add the evaluated mesh/volume capabilities, brush editing and remeshing with explicit conversion and detail-preservation behavior.

Architectural provisions for source identity, representation changes and fabrication adaptations belong in the first stage. A primitive palette or an improved template configurator does not complete the native modeling requirement.

## Acceptance

The primary acceptance is an actual native editing session starting with an empty Table and no conversation or prepared construction:

- Create the parts of a stylized toy/character, adjust proportions, establish symmetry, make soft connections, cut a detail and create a stable base.
- Return to earlier shapes and cutting operands; change them while retaining editable downstream work.
- Produce materially different proportions and composition/pose through native edits, preserving a consistent design language.
- Save/reopen, Undo/Redo, cancel an edit, recover from an invalid operation, and prepare a separately inspectable printing adaptation.

Additional projects exercise a profile-based vessel/decor object and a repeated or deformed abstract sculpture. These are project-authored tests of reusable tools. Agent-authored definitions or parameter-only adjustments cannot substitute for demonstrating manual construction.

Review actual app views from front, sides, back, underside and close-up. Compare silhouette, proportions, connections, edge character, detail and material response against retained references. Iterate on discrepancies and keep meaningful visual evidence as required by AGENTS.md.

Test real held pointer drags, selection, curve manipulation and repeated edits on representative model sizes. Record hardware, geometry complexity, interaction conditions and measured latency/frame behavior. Set acceptance targets before implementation; command roundtrip timings alone do not establish smooth editing.

Use focused tests for source preservation, dependency handling, geometry failure, Undo, cancellation and full-detail output. Passing tests, valid meshes or polished renders do not establish a good editor. Completion requires the native creation experience and the resulting objects to pass review.
