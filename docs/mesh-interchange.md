# Mesh interchange foundation

LAB imports preserved visual meshes as first-class project objects. Their source mesh is authoritative; material changes, UV artwork, placement and uniform physical scale remain editable. Import does not reconstruct CAD feature history, sewing patterns or a printable solid.

## Implemented formats and fidelity

| Format | Supported source data | Units and limits |
| --- | --- | --- |
| GLB / glTF 2.0 | Static scene hierarchy; independent mesh parts and instances; indexed triangles, strips and fans; positions, normals, tangents, UV0/UV1 and vertex colors; primitive material slots; PNG/JPEG embedded or local textures; base color, packed metallic/roughness, normal, emissive and occlusion maps; alpha and double-sided materials | Format-declared meters converted to canonical millimeters. An explicit unit override is recorded in provenance. Right-handed +Y up. |
| Binary / ASCII STL | Actual facet geometry and original source bytes | Explicit millimeter, centimeter, meter or inch choice required. Source XYZ is retained; STL has no verified up-axis convention. |

The native importer has no third-party parsing dependency and no SceneKit dependency. It implements bounded accessor decoding, interleaved buffers, normalized integer attributes, sparse accessors, selected scene traversal and full affine hierarchy matrices. Missing normals follow glTF's flat-shading rule, including bounded deindexing; authored normals preserve smooth surfaces. Negative-determinant transforms reverse triangle winding and transform normals/tangent handedness correctly.

`KHR_texture_transform` and `KHR_materials_unlit` are supported. Skinning, morph targets, required Draco/meshopt compression, required quantization and other unknown required extensions are rejected with export guidance. Animation source bytes remain preserved, but only the static node transforms are displayed. OBJ and USD/USDZ are deliberately not listed as supported imports. A future Apple importer must demonstrate preservation of the same source contract before it is enabled.

The parser follows the [Khronos glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html), including meter units, column-major transforms, little-endian accessors, linear material factors and packed roughness/metallic channels. No third-party model or parser source is vendored by this implementation.

## Native and MCP workflow

Native Import 3D Model opens a review sheet with a real RealityKit mesh preview, source dimensions, material slots, named parts and explicit warnings. STL waits for a unit choice before parsing. Import parses and prepares immutable display buffers on a worker. Publication rechecks the source revision and project epoch, flushes active artwork edits, stages/writes/moves immutable resources on a worker, then flushes/rechecks again before adding one object in one Undo operation. Cancellation or a stale source rolls back its own new files. Camera changes alone do not stale the review; source edits or leaving/reopening a project do.

The `form_model_asset` domain surface shares that coordinator:

1. `command: "formats"` reports implemented formats and limits.
2. `command: "import", path: "/absolute/model.glb"` starts a job; optional `name` and `source_units` are bounded. STL requires `source_units`.
3. `command: "status", job_id: "…"` reports `preparing`, `ready`, `failed`, `cancelled` or `committed`.
4. `command: "commit", job_id: "…"` starts detached resource staging (`publishing`); poll `status` until `committed` and read `object_id`. Final publication is one guarded Undo edit. `cancel` discards a pending job and cleans up only its staged resources.
5. `inspect` accepts an imported `object_id`. `material` edits one `material_index` using RGB hex `color`, unit-range `metallic`, `roughness`, `opacity`, or Boolean `clear`.
6. `artwork` maps the object's single same-project artwork source (`source_object_id`) to one `material_index`, optionally selected semantic `primitive_ids`; `clear` removes that slot mapping.

MCP import never contacts a printer. Import/status/cancel/inspection do not mutate the product graph. Commit/material/artwork use the normal project edit and Undo path.

## Persistence and representations

`ProductObject.meshAsset` contains small Codable metadata: source and normalized filenames and SHA-256 digests; original format/name; units and orientation; mm bounds; named source node/primitive identities; material/UV summaries; editability `visualMesh`; material overrides and artwork bindings. Original detailed geometry remains outside the product graph.

Two immutable resources are retained in project Assets: the exact original root file and a normalized JSON archive. The archive contains the complete root source bytes, exact referenced external buffer/image bytes with relative paths and hashes, normalized geometry, hierarchy and material/texture metadata. A loose original `.gltf` root alone is not an exported external-resource bundle; the normalized project archive retains its dependencies. Reopen verifies both resources and validates decoded geometry before display. Revisions/Undo retain source assets rather than rewriting them in place.

Local file resources must remain within the source directory after URL decoding and symlink resolution. Network URLs, absolute resource paths, traversal and symlink escapes are rejected. Project resource reads similarly reject resolved paths outside Assets. SHA-256 and typed validation catch corrupted normalized/source resources. Normalized local/world matrices must agree with their parent hierarchy, affine linear entries must remain finite in the viewport domain, transformed selected vertices must stay within canonical coordinate limits, and claimed bounds must match recomputed source bounds within 0.000001 mm.

The Table anchors each import at its source bounds' bottom center. Original source coordinates/matrices remain retained. New imports are placed to the right of existing rotated physical bounds with 25 mm clearance; this occurrence translation does not rewrite the source anchor or geometry. Placement, yaw and `scalePercent` are occurrence transforms; arbitrary width/height parameter reconstruction is unavailable. Positive orthogonal source TRS nodes reuse shared mesh buffers; shear/reflections are baked at the display adapter boundary with original matrices retained.

## Display materials and UV artwork

The renderer adapter supplies real source geometry, texture pixels, stable part identities and material slots to `LabRendering`. It uses linear color factors for glTF, packed metallic/roughness B/G channels, normal scale, emissive color/maps, alpha mode/cutoff and texture wrap modes. Slot surface colors are sRGB. Untextured slots convert the chosen color to the source factor encoding. Textured slots create a deterministic derived colorway: mean-normalized linear source luminance preserves weave contrast while the chosen RGB replaces baked texture chroma. Relative contrast is bounded to 0.35–1.8, derived display textures are capped at a 2048-pixel edge, and source alpha, normal and metallic/roughness maps remain retained. Clear restores the exact source appearance. This is a recolor, rather than multiplication of a near-black baked texture by another dark tint. Editing roughness alone preserves the source color or an existing recolor. A material override does not change geometry hashes.

The current host RealityKit procedural mesh path displays UV0. The adapter can remap a source UV1 or transformed UV set into display UV0 and regenerate tangents. Material channels using different mappings from the chosen base appearance are omitted with an explicit warning; original channel mappings remain preserved. Vertex colors are retained in source/neutral buffers with a display warning on the current RealityKit path. Texture minification/magnification preferences remain source metadata; current display uses the renderer's supported sampling. This is not a promise of pixel-identical Blender output for every material extension.

UV artwork targets original UV0 and named material/primitive groups. Transparent artwork is composited over the original base appearance rather than removing the base material. Composites are shared per slot, capped at 2048 pixels per edge, cached separately from source geometry, and rebuilt off the main thread. Material revisions depend only on the actual slot override and applied artwork, so unrelated slots reuse their materials. Mapping does not certify physical print dimensions or continuity across UV seams. Artwork has one source owner through the existing artwork link; stored source-frame dimensions support faithful detach/iteration without treating a UV layout as a calibrated garment pattern.

## Bounds and performance budgets

| Budget | Default |
| --- | ---: |
| Root source file | 256 MiB |
| glTF JSON chunk/file | 16 MiB |
| Individual external/buffer resource | 256 MiB |
| Aggregate retained resources | 512 MiB |
| Source vertices / triangles | 2,000,000 each |
| Selected scene instance vertices / triangles | 8,000,000 each |
| Nodes / hierarchy depth | 4,096 / 128 |
| Meshes / source or selected-instance primitives / material slots | 2,048 / 8,192 / 2,048 |
| Texture images / encoded bytes per image | 256 / 32 MiB |
| Texture edge / pixels per image | 8,192 / 16,777,216 |
| Aggregate texture pixels | 67,108,864 |
| Canonical coordinate magnitude | 1,000,000,000 mm |
| Interactive decoded source/display buffers | 256 MiB per asset and source cache |
| Prepared import review aggregate | 512 MiB |
| Normalized archive | 768 MiB |
| UV appearance cache | 64 MiB, at most 256 entries |

The app can reject a file below parser geometry limits when decoded display buffers exceed its interactive memory budget. These are enforced ceilings, not a responsiveness guarantee at every ceiling. Worker cancellation and generation guards prevent late reads/composites from replacing a new project or appearance. Transform updates wrap cached buffers without remeshing. Source and appearance caches are bounded and cleared on project change.

## Print preparation

Imported and exact-CAD source preparation reads the actual immutable geometry on a detached worker. Source revision hashes participate in print invalidation; paint, artwork and Table occurrence placement do not. The component picker uses retained node/component identities and labels. Multiple source outputs are not silently fused. A CAD output containing multiple solids must be separated before this print route.

A selected component is checked for closed, consistently oriented topology, non-manifold/boundary edges, degenerate triangles and positive signed volume. Inspection welds coincident vertices at 0.00001 mm and is bounded to 300,000 triangles per component. Open or inward/invalid visual meshes are rejected with counts and repair guidance. No automatic repair is claimed. Canonical source `(x,y,z)` in mm maps to printer `(x,-z,y)` in mm, then explicit print rotation and scale apply once before bed centering.

These checks do not detect self-intersections, certify minimum walls or clearances, or guarantee manufacturing suitability. The accepted stored CAD tessellation is used; future fabrication-quality remeshing must be explicit. No printer commands are sent by preparation or these tests.

## Verification and original fixtures

`Tests/FormMeshAssetsTests` contains 24 native XCTest cases for malformed accessors/chunks/indices, byte/count limits, finite coordinates, sparse/interleaved data, hierarchy/depth/instances, unit conversion, textures/PBR/UV mappings, local path and symlink containment, unsupported compression/deformation, topology, source retention, STL grammar and portable reference validation.

Original procedural fixtures are generated by `MeshAssetFixtures.swift`: a multi-part hard-surface device and a curved flight-jacket test mesh with torso, sleeves, ribbed trims, zipper and separate patch, four material slots and two original tiny textures. The jacket fixture currently has 58,703 vertices and 114,692 triangles; its GLB is approximately 3.11 MiB. These are synthetic regression assets, not supplier garment reconstructions, real sewing patterns or evidence that an arbitrary commercial jacket has been reproduced. No copyrighted external model is included. Local generated demo copies live under `.local/cad-foundation/fixtures/`.

The isolated native importer suite passed 24 tests. Native application lifecycle tests additionally exercise source-preserving one-Undo import, reopen after removing the original external file, stale revision/project epoch rejection, material/UV edits, cancellation, corrupt resource rejection, transform-only geometry reuse and transparent UV composition. Their integration result is recorded by the full application test gate, rather than inferred from the parser tests.


### Reproduce the Blender comparison source

After building the FormMeshAssets target, compile its small original fixture generator (adjust the build products path for a non-Xcode SwiftPM build):

```sh
mkdir -p .local/cad-foundation/fixtures
xcrun swiftc -I .build/out/Products/Release -L .build/out/Products/Release -lFormMeshAssets \
  Tests/FormMeshAssetsTests/MeshAssetFixtures.swift scripts/generate_mesh_test_fixtures.swift \
  -o .local/cad-foundation/fixtures/generate-mesh-fixtures
.local/cad-foundation/fixtures/generate-mesh-fixtures .local/cad-foundation/fixtures
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python scripts/generate_blender_jacket_fixture.py -- \
  --base .local/cad-foundation/fixtures/LAB-synthetic-flight-jacket.glb \
  --output .local/cad-foundation/fixtures/blender
```

The authoring script imports the original regression mesh, refines shoulder/sleeve geometry, and adds genuine bevelled zipper teeth, pull, pockets, stitched patch border, embroidered mesh lettering, curved seams and a separate neck label. It packs original woven pixels and saves a complete `.blend`, uncompressed GLB, fixed Cycles source render and JSON camera/provenance manifest. Export uses Blender's [documented glTF operator](https://docs.blender.org/api/5.0/bpy.ops.export_scene.html), static geometry, meters and Y-up conversion; skins/morphs/animation/compression are disabled.

Verified on installed Blender 5.2.1 LTS: the exported GLB has 33 mesh nodes, 7 material slots, 2 original textures, 174,600 triangles and 97,034 imported vertices, in 5,077,368 bytes. The Blender source has the same triangle count; its 90,967 authored vertices split at UV/hard-normal boundaries during export. Bounds agree after the documented meter→mm and axis conversion. Isolated debug parsing plus normalized validation took approximately 0.58–0.72 seconds on the development Mac. The fixed source render is a visual reference for native comparison; independent lighting and tone mapping prevent a pixel-identical cross-engine claim. This remains an original synthetic acceptance garment, not a commercial jacket reconstruction or production sewing pattern.

### Actual adapter and RealityKit comparison

The tracked `scripts/render_mesh_fidelity.swift` harness compiles with the actual `MeshAssetSceneAdapter.swift`, FormMeshAssets and LabRendering. It reads the Blender camera manifest and uses the production neutral light values (key 3000, fill 600). It writes original-source, orange/green colorway, UV-patch and cleared-source PNGs plus measured renderer diagnostics, without the application library, CUA or a printer.

```sh
xcrun swiftc -parse-as-library -I .build/out/Products/Release -L .build/out/Products/Release \
  -lFormMeshAssets -lLabRendering Sources/FormApp/MeshAssetSceneAdapter.swift \
  scripts/render_mesh_fidelity.swift -o .local/cad-foundation/fixtures/render-mesh-fidelity
.local/cad-foundation/fixtures/render-mesh-fidelity .local/cad-foundation/fixtures/blender
```

Actual RealityKit captures preserve all 33 source parts, 7 material slots, 2 original images, 174,600 triangles and the 1289.999962 × 630.000019 × 275.120795 mm source bounds. Bottom-center Table anchoring is the only origin adjustment. Source camera silhouettes and separate zipper, patch, lettering, seams and rib geometry agree visually with Blender. Surface reflection, highlight shape and overall exposure differ because the source uses Cycles area lights/Standard sRGB while LAB uses neutral IBL/directional light and its tone mapping. No source factor or global lighting was silently changed to hide that difference.

Derived orange `#C56836` and forest green `#32483B` colorways are visibly distinct while retaining weave detail. The UV test changes only the independent patch primitive; it does not blanket the jacket. Mesh builds remain 33 across source/colorway/UV edits. Material builds progress 7 → 8 → 9 → 10, so each changed slot adds one material. Source texture uploads begin at 2; each derived colorway/patch adds one texture. Warm 1200 × 1000 captures measured approximately 14–24 ms; parsing, preparation and four captures took approximately 1.68 seconds (1.77 seconds including the fifth clear/restore capture) in the isolated development harness. These measurements describe this fixture/host and are not a promised frame rate for every bounded asset. Clearing overrides restores the original material/mesh signatures and retained source bytes.

## Remaining interchange work

- USD/USDZ and OBJ import are not enabled. Apple documents [Model I/O format discovery](https://developer.apple.com/documentation/modelio/mdlasset/canimportfileextension(_:)) for USD/USDZ/OBJ and [RealityKit asynchronous USD hierarchy loading](https://developer.apple.com/documentation/realitykit/entity/init(contentsof:withname:)). Those APIs prove format-level loading, not preservation of every material channel, bounded dependency extraction, units or editable source mappings. The next importer must verify those requirements with real fixtures before advertising support; synchronous RealityKit load methods explicitly block the main actor.
- A visual GLB/USDZ exporter for the edited LAB scene is not implemented by this module. Exact original root bytes and dependencies are retained; copying a raw `.gltf` root alone is not a complete external-resource export. Source-preserving bundle export and normalized edited-scene export need separate validation.
- Imported source part transforms are preserved and inspectable, but arbitrary per-part geometry editing, feature reconstruction, mesh repair and skin/morph animation are not exposed. Product placement/uniform scale, source-slot colorways and UV artwork are the supported edits.
- General curved decal projection, UV seam repair, automatic reattachment after topology changes, calibrated textile print dimensions and supplier sewing-pattern reconstruction remain outside this foundation. UV0 mapping is explicit and carries an unverified physical scale.
- Topology inspection does not detect self-intersections or disconnected internal shells, establish minimum walls, repair bad geometry or certify printability. Multi-solid CAD outputs need separate output components before this preparation path. Source display tessellation is reused; a dedicated fabrication-tolerance remesh is future work.
