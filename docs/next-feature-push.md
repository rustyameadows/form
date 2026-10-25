# Next feature push: Textiles, Apparel & Merchandise

**Status: Active implementation.** Recorded October 24 and activated October 25, 2026 by the user. This proceeds alongside the remaining 2D/3D work and camera fixes. The complete brief is part of the active completion scope.

The complete [Textiles, Apparel & Merchandise product brief](textiles-apparel-merchandise-spec.md) governs this feature push. It extends the [original product brief](product-brief.md) and depends on the [professional 2D design specification](2d-design-typography-vector-spec.md).

## Lead demonstration: NASA-themed bomber jacket

The user's explicit direction is an **awesome NASA-themed bomber jacket with custom patches, sewn-in tags, embroidery, and related details**. This is the lead textile demonstration, taking precedence over the source brief's generic five-piece collection as the first showcase. The full collection remains a later breadth demonstration.

The jacket should demonstrate an actual editable physical product with independently authored components and production information. Its visual quality should hold up in a hero render, front/back views, and close-ups of the patches, stitching, labels, fabric, lining, ribbing, and hardware.

Required demo elements:

- A bomber jacket with convincing fabric, construction details, physical scale, and selectable decoration regions.
- Custom NASA-themed patches that also exist independently on the Table, with editable artwork, dimensions, base fabric, border, backing, and attachment method.
- Sewn-in tags/labels with editable typography and graphics, physical dimensions, material, and sewing/placement definitions.
- Direct embroidery with separate artwork and stitch definitions: thread colors, stitch type/direction/density, underlay, compensation, ordering, jumps/trims, and hoop constraints as the embroidery engine supports them.
- Live linked 2D/3D editing, exact placement, focused component inspection, and variants that preserve the original jacket.
- A coordinated material/component list and production packet containing supported artwork, patch/label files, placement diagrams, assembly notes, and validated machine outputs where implemented.

The NASA theme and those component types are user requirements. Specific patch designs, mission references, jacket colorways, blank supplier, measurements, fabrics, thread palette, and equipment remain design decisions for the implementation phase; they are not settled by this record.

## Demonstration acceptance

1. Open the jacket project and inspect the assembled garment at real scale.
2. Focus a patch, sewn-in tag, or embroidered region and edit it directly in the native workspace.
3. See the corresponding 3D representation update without an export/reimport cycle.
4. Move and size decorations using physical measurements and preserve their garment-relative placement.
5. Show the patch and tag as independent manufactured components beside the jacket on the Table.
6. Create a visible colorway or decoration variant while retaining the source design and shared assets.
7. Generate polished hero/detail imagery and a production packet tied to the exact design revision.
8. Save, close, and reopen with artwork, component relationships, materials, placements, and supported stitch settings intact.

Distinguish render-only appearance, dimensional assumptions, generated stitch programs, equipment-compatible output, and physically tested production. A decorative texture alone does not demonstrate embroidery digitization or garment construction.

## Development sequence to retain

The source brief's full scope remains recorded, with its staged order:

| Phase | Scope |
| --- | --- |
| 1. Merchandise and existing blanks | Garment model import/library, real dimensions and decoration regions, linked artwork, fabrics, placement, colorways, presentation, exports, and basic specifications |
| 2. Decoration and fabrication | Embroidery engine/editing/export, independent patches and labels, DTG/DTF, spot-color separations, heat-transfer vinyl, production materials, equipment profiles, compatibility, and jobs |
| 3. Fabric design and soft goods | Repeat patterns, parametric pattern pieces, seam relationships/allowances, cutting layouts, consumption, assembled previews, instructions, and reusable constructions |
| 4. Garment construction | Parametric garment blocks, sizing/grading, body measurements, cloth behavior, fitting, pattern-aware artwork, and technical packs |
| 5. Integrated production studio | Supported device integration, scheduling, inventory, costing, suppliers, quality/sample history, shared resources, and extensions |

The bomber is the recurring demonstration across these phases: begin with a decorated blank, deepen its patches/labels/embroidery and production outputs, then add editable construction and fit as those systems mature. Do not make predictive cloth simulation a prerequisite for the first decorated-blank demonstration.

## Existing project constraints

Use FORM's native UI, modular product graph, shared Studio Library, and deterministic operations exposed through the same MCP interface. Codex remains the creative collaborator; external model calls inside FORM are not part of the current plan.

Equipment export, manufacturer handoff, and direct control are separate capabilities to implement only where supported. Recording this push does not authorize operating fabrication hardware. The existing instruction not to print remains in effect.
