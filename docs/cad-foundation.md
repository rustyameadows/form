# LAB 0.3 · CAD foundation

LAB now combines exact feature models, imported visual assets and existing product constructions on the same Table. Form, Function and Fabricate remain the primary environments; Studio remains available through its aperture icon and menu. The connected Canvas, typography, textiles and production tools retain their existing source and Undo behavior.

The [guiding specification](cad-foundation-upgrade-spec.md) is retained verbatim. The [starting audit](cad-foundation-audit.md), [renderer evidence](cad-renderer-spike.md), [kernel](cad-kernel.md), [operation contracts](cad-operations.md), [feature graph](cad-feature-graph.md) and [interchange limits](mesh-interchange.md) explain the implementation. This upgrade does not complete every item in the broader product, typography or apparel briefs.

## Use it

Choose **Add object → Exact CAD model…**. Select Clock enclosure, Vase, Lamp or Enclosure, adjust dimensions, and choose Preview. Inspect the actual solid, feature sequence, profile and diagnostics before applying. Changes remain a draft until **Add to project** or **Apply changes**; application creates one Undo step. Existing exact objects expose **Edit dimensions & features…** in their inspector.

Choose **Import 3D model…** for GLB/glTF/STL. The review shows actual geometry, physical bounds, parts, material slots and import notes. STL requires explicit units. Choose **Import exact STEP / BRep…** for engineering geometry, with an explicit source up-axis choice. Imported STEP retains its component tree, occurrence placements, repeated-part identities, names and source colors, including face colors. BRep files have no physical unit metadata; their review explicitly records millimeters as an unverified assumption.

Selections distinguish a **Visual mesh**, **Imported CAD body**, **Feature model**, or an existing product construction. An imported jacket remains an imported mesh; its polygons do not become sewing patterns or recovered CAD history.

Imported meshes expose independent material slots and source-preserving colorways. Textured color changes derive a recolored map while retaining weave detail, alpha, normals and roughness; clearing restores the original pixels. UV0 artwork can link to an independent Canvas frame. Its source dimensions remain intact through detachment, source deletion and independent iterations. UV placement does not establish physical print scale; physical output uses the original artwork frame.

## Model through MCP

The existing local bridge adds `form_cad` and `form_model_asset`, alongside the integrated `form_object_library`. The packaged bridge exposes 62 tools. Tool IDs retain their `form_` prefix for existing clients.

An exact modeling loop uses the same native evaluator:

```json
{"command":"create","template":"clockEnclosure","quality":"inspection"}
```

Poll `form_cad` with `{"command":"status","job_id":"…"}` until `state` is `ready`. Render the uncommitted geometry without editing the project:

```json
{"command":"render","job_id":"…","view":"front","width":1200,"height":900,"transparent":true,"path":"/absolute/new-preview.png"}
```

Poll status for the result path, inspect it, then submit `{"command":"commit","job_id":"…"}` and wait for `committed`. Parameter and feature commands create new review jobs. Invalid operations retain the accepted object; changes to design source invalidate old reviews. Moving the camera does not invalidate them.

`templates` returns complete editable definitions. `plan` validates graph structure and lists assumptions. `topology` returns revision-scoped faces/edges; ordinal selections require the exact input fingerprint. `clearance` measures selected outputs. `export` writes a ready exact output as STEP or BRep to a new local file. Imported assembly source remains preserved; regenerated STEP export carries geometry rather than the complete original assembly presentation metadata.

For visual assets, `form_model_asset` supports formats/import/status/commit/cancel/inspect/material/artwork. Both preparation and publication use background workers, with one guarded Undo transaction at the end. New imports are placed clear of existing objects. See the tool schemas and [interchange guide](mesh-interchange.md) for bounds and unsupported input.

## Demonstrated geometry

| Model | Actual construction and checks |
| --- | --- |
| Clock enclosure | 177.8 mm diameter, 50.8 mm depth; 20 exact features, recessed dial, rear movement cavity, shaft opening, bored mounting bosses and softened edges. Diameter changes regenerate dependent features. STEP round-trip bounds/volume and fabrication mesh are checked. Movement/fit dimensions remain authored placeholders. |
| Sculptural vessel | Exact cubic Bézier profile, revolution and inward shell with an open rim. Editable height, radii and wall thickness; closed/outward fabrication mesh. The local Orca workflow produces a 900-layer preview at default dimensions. |
| Lamp | Separate base, swept hollow support and offset hollow shade; booleans, openings and softened edges. Three output components remain independently selectable for fabrication. The clearance tool reports a 93.46 mm³ overlap between the base and support at the authored insertion; this is a measured intersection, not a validated joint. Electrical connections and physical fit remain design decisions. |
| Enclosure | Dimensioned profile, extrusion, normal wall and edge fillets. Native dimension editing, preview/cancel, one-step apply, Undo and persistence are exercised. |
| Imported jacket | Original Blender-authored source: 33 mesh nodes, seven materials, two textures and 174,600 triangles. Source bounds/parts, visible colorways, separate UV artwork, material reuse, clearing and save/restart are verified. This is an original synthetic design, not a supplier reconstruction or fit claim. |
| Imported receiver | Original Blender-authored hollow receiver: 41 parts, ten materials, three texture maps and 56,888 triangles, at 180 × 110 × 45 mm. Actual native import, source/material bounds and front rendering are verified. |
| STEP assembly | Generated nested engineering source with three leaves, repeated bracket instances, distinct names, local/world placements and a colored face. Original bytes and metadata survive project save/reopen; external file references reject before transfer. |

Actual native outputs: [exact clock enclosure](evidence/cad-clock-enclosure.png), [imported receiver](evidence/cad-receiver.png), and [textured jacket colorway](evidence/cad-jacket-colorway.png).

Reproducible fixture and rendering scripts are included under `scripts/`. Generated private outputs stay under `.local`; user reference photos are not republished in repository evidence.

## Rendering and fabrication

Table, insets, project/study previews, Studio, print bed and toolpaths use RealityKit through native MetalKit hosts. SceneKit is absent from shipping sources and the packaged app's direct dependencies. CPU construction and exact/asset geometry remain separate from display resources.

Navigation is unchanged: Orbit tool drag orbits; Shift-drag pans; scroll/pinch zooms; Move tool drags objects. Perspective, Top and Front frame the whole project, with space reserved for an open inspector. Focus and Isolate remain explicit selection actions. Native mouse checks cover both axes, diagonals, reversal and continuous horizontal turns.

Print opens the existing dedicated preparation workspace. New exact/imported objects use a selected named component with verified source hashes, physical dimensions and closed/outward topology. Multiple solids are not silently fused. Geometry preparation runs off the UI thread. Local slicing and export remain available; sending or starting a print remains disabled.

## Measured scope

Validation runs on Apple M5, 24 GiB RAM, macOS 26.6.2. The [acceptance record](evidence/cad-foundation-native.json) records exact suite totals, packaged checks and preservation results.

The renderer stress fixture has 64 shared detailed clock cases, 2.36 million visible triangles and one mesh upload. Offscreen 1200×800 captures measured 17.39 ms median; exact picking measured 0.105 ms p95 on a separate 64-instance fixture. The detailed jacket retains 33 mesh builds while material builds change 7→8→9→10 for two colorways and patch artwork. These are measured fixture costs, not a whole-app sustained 60-fps or total-memory guarantee.

Builds currently target Apple silicon and macOS 15+. Bounded import/cache limits are deliberate. USD/OBJ import, edited-scene GLB/USDZ export, arbitrary mesh repair, animated/skinned assets, full persistent topological naming, calibrated curved fabrication mapping and a full sketch constraint solver remain outside the supported implementation. The original STEP source preserves its full metadata; regenerated per-output STEP export is geometry-only. See the detailed guides before relying on an unsupported workflow.
