# FORM
## 3D/CAD Foundation Upgrade
### Engineering Implementation Specification | October 26, 2026

**Audience:** Agent and engineering team working on Form's native macOS application  
**Status:** Proposed upgrade; not a claim of implemented functionality  
**Codebase:** `rustyameadows/form`, implementation branch `codex/form-v0.1`  
**Objective:** Replace the SceneKit rendering dependency, introduce an industrial-strength geometric modeling foundation, make high-fidelity imported models first-class objects, and give the agent a capable, reliable 3D authoring vocabulary.

---

## 1. Executive Direction

Form should become a serious environment for **creating, importing, editing, assembling, rendering, and fabricating physical objects**, without turning its interface into conventional engineering CAD.

The application currently has an effective product graph, physical-unit system, 2D/3D links, material assignments, native inspectors, recipes, print-preparation pipeline, and MCP interface. Retain those investments.

The 3D foundation needs four complementary changes:

1. **Modern rendering:** Move the Table, object previews, Studio, and relevant print/physical views off SceneKit. Prefer a native RealityKit-backed implementation if it meets the detailed functional tests, with Metal/MetalKit handling custom rendering and picking needs. Do not introduce a web renderer.
2. **Real CAD geometry:** Integrate Open CASCADE Technology (OCCT) as a native C++ boundary-representation (B-rep) solid-modeling kernel, separate from the renderer.
3. **Excellent interchange:** Make complex external mesh and CAD assets usable without reducing them to boxes, cylinders, or existing Form recipes. Support viewing and decorating imported meshes even when they cannot be parametrically edited.
4. **Agent-native modeling:** Introduce typed, composable geometry operations and a persistent feature/dependency graph so agents can produce complex editable objects through reliable tools rather than primitive stacking or ad hoc source-code edits.

**Core rule:** The renderer displays models, the geometry kernel constructs models, the product graph defines their meaning, and the agent directs operations. None substitutes for the others.

Do not rewrite the 2D editor, product package format, Studio Library, embroidery stack, or printing stack as part of this upgrade.

## 2. Starting Point: Verify, Preserve, and Document

Current repository documentation identifies:

- SwiftUI/AppKit application with `FormCore`, `FormGraphics`, `FormApp`, and `FormMCP` modules.
- SceneKit rendered through Metal, isolated outside the core product model.
- Millimeters in the document; a renderer-specific scale currently converts 100 mm to one scene unit.
- Parametric recipes, custom primitive-based recipes, linked artwork, physical materials, object transforms, iterations/variants, and immutable revisions in `.form` packages.
- C++ bridges already used for 2D clipping and meshing, providing an existing integration pattern for native geometry libraries.
- A native Orca-based slicer integration, physical printer profiles, and material inventory.
- Established camera bindings and automated native/MCP/save-reopen test coverage.

**Before changing code, audit actual source, not just documentation.** List all SceneKit usages, geometry factories, SceneKit-specific materials and hit tests, export paths, camera state, render signatures, object-selection mechanisms, and offscreen render dependencies. Identify any SceneKit types crossing module boundaries despite the intended separation.

Save baseline project fixtures and reference screenshots for at least: the clock study, folding sleeve/cyanotype kit, NASA jacket, multi-object collection, saved Studio render, and existing slicing export. Record build/test commands and performance on a real supported Mac.

The branch is an active development branch, not `main`; verify the actual branch head and current changes before implementation.

## 3. Target Architecture

Implement distinct services with stable, testable interfaces:

| Layer | Responsibility | Recommended implementation |
|---|---|---|
| Product/document graph | Identity, components, parameters, construction, artwork, dependencies, revisions, physical units | Existing `FormCore`, extended schemas |
| Exact solid geometry | Analytic curves/surfaces, B-reps, booleans, fillets, shelling, precise CAD imports and exports | OCCT behind C ABI/C++ adapter |
| Mesh assets/processing | Imported polygons, UVs, textures, material groups, bounds, normals, topology checks, display LOD | Independent asset/mesh module, suitable vetted parsers |
| Construction recipes | Packaging, textiles, paper, product-specific relationships and fabrication rules | Existing recipes expanded to consume exact geometry |
| Feature/dependency graph | Rebuildable operations, source references, parameter expressions, failures, dirty propagation | Form-owned typed graph |
| View scene and renderer | Mesh/material display, lighting, selection, object transforms, cameras, 2D artwork textures | RealityKit-backed renderer candidate; custom Metal where justified |
| Agent tools | Plan, create, inspect, edit, validate, import, render, export | Existing MCP/domain command system extended |

One product may have **multiple representations**: authoritative B-rep, editable construction graph, imported source mesh, generated display mesh, lightweight preview, fabrication mesh, and 2D artwork. Do not make triangles the only editable source for CAD solids. Do not make B-rep mandatory for garments, scans, cloth, or artist meshes.

Maintain stable product and component UUIDs. Make derived meshes rebuildable/cached. Preserve the original source file and provenance of each import.

### Physical coordinates

- Document dimensions: **millimeters**, with `Double`-precision geometry and parameters.
- Use one canonical axis/orientation convention in the document; document transforms at importer and renderer boundaries.
- Convert at the renderer adapter boundary only. Do not leak RealityKit meters or old SceneKit scene units into document geometry.
- Imported files with unknown units require an explicit choice or a clearly marked unverified assumption; never silently treat every mesh unit as a millimeter.
- Keep scene rendering numerically stable for both small parts and large spatial Tables, using appropriate origin-relative transforms when necessary.

## 4. SceneKit Migration: Preferred RealityKit, Not a Blind Rewrite

Apple has deprecated SceneKit and recommends RealityKit for new 3D development. For Form, the immediate goal is a **renderer-neutral scene contract**, followed by a measured RealityKit migration. A full custom Metal rendering engine is a fallback if RealityKit cannot meet essential professional viewport behavior, not the starting assumption.

### 4.1 Renderer interface

First extract `FormSceneRenderer` (conceptual name) independent of SceneKit and RealityKit. Define operations to:

- Upsert/remove renderable components by stable object/component IDs.
- Supply geometry buffers or mesh resources, submeshes, materials, texture maps, transforms, visibility, selection and highlights.
- Set camera and lighting; request fit/focus, named views and offscreen captures.
- Perform object picking, and ultimately face/edge picking, returning semantic IDs.
- Render tabletop/reference assets, shadows, grids, outlines, selection adornments, and physical guides.
- Update transforms without rebuilding geometry; update artwork texture without rebuilding unaffected geometry.
- Load resources progressively, share immutable assets, and release GPU resources on project change.

The native mouse-navigation controller and the product graph should not depend on renderer-specific entity/node types.

### 4.2 Short renderer proof-of-capability spike

Build a second viewport displaying real Form objects in RealityKit. Verify against the existing app before committing to a full migration:

1. Multiple independent meshes and material slots; imported high-detail textured asset.
2. Physical-scale transforms, group/instance reuse, alpha materials and double-sided surfaces where needed.
3. Selection/picking of overlapping components, highlighting, isolation and focus.
4. Orbit/Shift-pan/zoom and the existing named-view behavior, including camera persistence.
5. Live source artwork updates on a clock face or package panel.
6. Fast geometry reloading after parameter changes and correct undo/redo.
7. Offscreen Studio PNG at requested pixel dimensions, consistent framing, lighting and transparent background where specified.
8. Multi-object scene memory behavior and responsiveness under a representative load.
9. Correct native AppKit/SwiftUI integration in Table, Studio, inset previews and relevant print views.

If RealityKit passes, migrate to it. Where an individual viewport function is missing or too inflexible, implement **targeted Metal passes or overlays**, rather than rewriting the entire renderer. If critical needs cannot be fulfilled by RealityKit plus focused Metal work, document the failed tests and authorize a dedicated `MTKView` renderer with its own lighting, resource, picking and offscreen pipelines.

### 4.3 Migration execution

- Keep the SceneKit implementation temporarily behind the common renderer interface for side-by-side comparison.
- Replace one consumer at a time: Table, object inset/previews, Studio, then print/physical previews dependent on the renderer.
- Port all existing geometry factories to common mesh payloads before introducing new visual features.
- Preserve existing selection semantics, camera shortcuts, saved compositions, project screenshots, hit test meaning, performance behavior and rendering invalidation.
- Perform visual and behavioral comparisons on pinned fixture projects.
- Remove all SceneKit imports/dependencies from shipping targets once all acceptance tests pass. Retain a separate archived branch for comparison rather than shipping two engines indefinitely.

**Acceptance:** SceneKit is not linked by the distributed Form app, while the existing Table, Studio, artwork preview, camera, and print preparation workflows still function.

## 5. Integrate a Real Solid-Modeling Kernel

Use **Open CASCADE Technology (OCCT)** for exact/analytic CAD shapes and standard engineering exchange. OCCT is a mature C++ modeling kernel; it is not a ready-made user interface, parametric history system, or material renderer.

### 5.1 Native integration

- Pin a tested OCCT release and its source/binary provenance.
- Create an isolated `FormCADKernel` interface and C++ bridge. Prefer a narrow C ABI with opaque handles and explicit error/results, memory ownership, and release functions, following Form's existing C++ bridge pattern.
- Keep OCCT C++ types out of Swift-facing public APIs, project JSON and MCP tool schemas.
- Own geometry calls in a controlled worker/service; ensure thread safety and cancellation boundaries. Long operations must not block the main UI thread.
- Use binary/native shape data (e.g. B-rep files or versioned kernel assets) for source geometry; keep product graph and feature history in Form-owned serializable data.
- Store bounds, units, topology summary, named components, and generated mesh hashes as metadata.
- Rebuild derived display meshes when source topology or tessellation settings change.

**Licensing gate:** OCCT uses LGPL 2.1 with an exception, with obligations that must be reviewed for shipping, linking, notices, and redistribution. Confirm the intended distribution architecture with an appropriate licensing review; pin third-party licenses and attribution. A commercial OCCT license is an option, not a prerequisite for initial technical experimentation.

### 5.2 Required geometry operations

**Core primitives:** Box, cylinder, sphere, cone, torus, planar face, circle, rectangle, polygon, arc, spline and polyline.

**Sketches/profiles:** Plane selection, dimensional 2D profiles, loops and holes; controlled constraints and references. Start with dimensioned profiles and simple relations before pursuing a complete Fusion-class sketch solver.

**Feature operations:**

- Extrude/add and extrude-cut.
- Revolve and revolve-cut.
- Sweep along a path.
- Loft through section profiles.
- Union, subtract and intersect solids.
- Fillet and chamfer selected edges.
- Shell/hollow/thicken where geometrically valid.
- Offset surfaces or profiles within explicitly supported cases.
- Hole/slot/pocket/boss features.
- Linear/circular pattern, mirror, copy and transform.
- Join and place components within an assembly.

For every operation, specify supported input topology, units, tolerance, output type, failure modes, and parameter dependencies.

### 5.3 Geometry health and persistent references

Provide precise diagnostic results: failed boolean, self-intersection, invalid wire, non-solid result, fillet radius too large, open shell, or ambiguous selection. Never silently replace a failed exact feature with a visual approximation while still labeling it CAD-valid.

Use face and edge references that are stable where possible, but explicitly account for **topological naming problems**: changing a feature can split or replace faces/edges. Maintain semantic anchors and operation-generated mapping where available; detect ambiguous remapping and request review instead of attaching holes or artwork to the wrong face.

Store an operation graph so generated geometry can be regenerated deterministically. Use transaction boundaries and keep the previous valid shape if a new operation fails.

### 5.4 Tessellation

The kernel outputs a B-rep; the renderer needs triangles. Generate display meshes with selectable tessellation quality, including vertex normals, indexed triangles, material groups and geometric-to-display mappings for picking. Provide preview quality for fast edits and higher quality for close inspection/export. Respect smoothing boundaries and sharp edges.

CAD tolerances and display tessellation tolerances are different concepts and should never be conflated.

## 6. Imported Models Must Be First-Class

Support two categories of 3D interchange through separate import pathways.

### 6.1 Mesh/visual assets

**Priority:** GLB/glTF for rich textured assets, then USD/USDZ for Apple-native content, plus OBJ/STL where appropriate. Verify exact parsing, material, texture and scene-graph capabilities of the chosen libraries; do not assume an OS importer preserves all features.

Import hierarchy, mesh parts, materials, textures, UVs, normals, transforms and source metadata wherever the format provides them. Show a real inspection of unit/scale and coordinate orientation. Keep source bytes plus normalized Form asset data.

A detailed bomber jacket imported from Blender should look substantially like its source reference, remain positionable on the Table, and support material overrides, attached patches/labels, and artwork projection where suitable UVs are available. **It does not need to become a parametric sewing pattern or editable B-rep.**

### 6.2 Engineering assets

**Priority:** STEP via OCCT, including assembly/part hierarchy, exact geometry, names and colors where available. Add IGES as a secondary format if justified. Export STEP from supported B-rep shapes. A STEP import may preserve exact geometry without preserving the original application's feature history or sketch constraints; represent it as an imported editable-at-solid-level body with explicit limitations.

A clock movement, fastener, enclosure, or supplier part should be imported at proper size and used in assembly and clearance checks.

### 6.3 User-visible editability states

Every object should clearly distinguish:

- **Reference/visual mesh:** View, position, render, decorate; no promise of precise CAD edits.
- **Imported CAD body:** Exact measurements, limited direct operations, assemblies and machining-oriented outputs; original parametric history unavailable.
- **Native feature model:** Fully editable Form parameters and feature operations.
- **Construction recipe:** Product-aware parametric object with domain-specific rules and outputs.

Do not silently treat every import as a fully editable native product.

### 6.4 Import safety

Use bounded file size, polygon count, node depth, texture dimensions, decompression and processing limits; validate indices, coordinates, paths and embedded assets. Inspect third-party parser licenses. Reject or quarantine invalid input without corrupting the current project.

## 7. Agent-Native CAD Authoring

The biggest creative improvement must be **what the agent can actually do**, not only what the renderer can display.

Expose CAD operations as typed, inspectable domain/MCP commands. Reuse the same underlying commands for native UI and external agents. Do not make agents write new Swift source code merely to construct ordinary new objects.

### 7.1 Proposed tool groups

**Inspect:** Query object hierarchy, solids, meshes, dimensions, local planes, faces/edges, parameters, constraints, materials, open issues and operation history.

**Plan:** Declare proposed components, construction type, rough overall envelope, sketch/feature dependencies, expected output fidelity, assumptions and unresolved measurements.

**Create:** New sketch plane/profile, exact primitive, extrude, revolve, sweep, loft, boolean, fillet, shell, pattern, assembly component and external asset import.

**Modify:** Edit an operation parameter; suppress/reorder supported features; update material or component transform; attach artwork; rename and organize geometry.

**Validate:** Geometry check, bounds, wall thickness where supported, clearance/interference, non-manifold checks, manufacturability checks within explicitly supported process rules.

**Observe:** Render fixed views, generate section/exploded views when supported, inspect geometry selection, and return structured errors and provenance.

**Export:** STEP for exact supported CAD, STL/3MF for suitable fabrication meshes, GLB/USDZ for appropriate visual sharing, and existing connected 2D/production outputs.

### 7.2 Structured feature graph

An agent action should create a durable node such as:

- `SketchProfile` dependent on a plane and dimension parameters.
- `ExtrudeFeature` dependent on `SketchProfile`, distance and direction.
- `FilletFeature` dependent on a prior body, edge selection and radius.
- `AssemblyOccurrence` dependent on a source part and placement.

A feature stores input references, parameters, version, output asset identity, validation state and regeneration dependencies. It is not just a transcript of tool calls.

Document dimensions remain driven by named parameters. Generate native inspectors from the same schemas. Rebuild only impacted downstream features when parameters change.

### 7.3 Transactional edits and model feedback

For a multi-operation agent edit:

1. Read the current revision and selected-object state.
2. Submit a structured plan/operation batch.
3. Evaluate against a sandbox/working revision.
4. Return explicit errors, geometry diagnostics and preview renders.
5. Commit one undoable revision only if checks pass or the user intentionally accepts a clearly marked incomplete model.
6. Reject stale operations when the user has changed the object in the meantime.

Agents need error messages that are useful for repair, not just `operation failed`.

### 7.4 Intelligent modeling loop

Use the Model Lab harness already specified to benchmark:

**Request → brief/measurements → visual direction → construction plan → operations → geometry health → standard renders → critique/repair → editable product.**

A reference image or generated concept may guide appearance but must not be mistaken for exact geometry. Keep aesthetic critique distinct from deterministic geometric validation. Track the number of operations, failures/retries, editable parameters, dimensional accuracy, and execution time/cost.

## 8. Editing UX: Stay Form, Not Fusion

The Table remains a spatial creative studio. An object selection should reveal meaningful controls: height, profile, curvature, radius, wall thickness, holes, materials and construction options relevant to that object.

Expose a focused **Model** mode for deeper control, including an object/component tree, feature list, sketch/profile viewer, dimension inputs, face/edge selection, preview/commit, and diagnostics. A simple native 2D sketch plane may reuse parts of Form's vector geometry engine, but maintain explicit distinction between graphic Bézier art and constrained CAD profiles.

Do not require a full CAD command ribbon or manual sketching to create a sophisticated object. The agent can generate a parametric model and provide editable levers. Advanced users can inspect and change the underlying feature sequence.

Support three levels of interaction: direct parameter edits, explicit modeling operations, and agent-authored structural revisions. Keep meaningful undo/redo across all of them.

## 9. Materials, Artwork, and High-Fidelity Presentation

Imported visual meshes should preserve submesh material assignments, base color, textures, normal maps, roughness, metallic response and alpha behavior to the extent supported by the interchange format and renderer.

Render material previews in a consistent color-managed environment, with physical-scale texturing and credible paper, fabric, plastic, metal, painted, ceramic and 3D-printed surfaces. Add environment lighting, shadows, anti-aliasing, reasonable tone mapping and Studio presets.

Keep appearance separate from geometry. A texture or embroidery change should not cause a B-rep rebuild. A transform-only change should not cause remeshing. A CAD feature edit invalidates only derived meshes and dependent artwork mappings.

For arbitrary curved imported assets, support existing UV-based artwork as a first route; add planar/decal projection with explicit limits. Linked artwork on UV seams or topology-changing faces requires a review or remapping workflow, rather than silently stretching or losing the design.

## 10. Fabrication and Validation

Reuse Form's current Print workspace and Orca flow. Replace the mesh producer, not the slicing product experience.

For CAD-derived solids, produce controlled tessellation suitable for print export and validate outward orientation, closure and geometry health. Check selected walls, overall dimensions and basic part clearances when reliable methods are available. Mark a mesh as suitable for print-preparation only after appropriate checks; do not certify manufacturing quality automatically.

For imported visual meshes, provide a repair/convert workflow where feasible, with explicit warnings when the mesh cannot become a printable solid.

Preserve current printer safety behavior: software previews/exports are permitted; do not introduce printer upload/start commands as part of this upgrade.

## 11. Project Persistence and Migration

Preserve existing `.form` packages and all current object types. New files may include:

- `CAD/` kernel-native shape assets and optionally neutral STEP copies.
- `Meshes/` normalized imported source meshes and display tessellations.
- `Textures/` referenced textures and material data.
- Versioned feature graphs and imported provenance in object resources.
- Cached preview/LOD resources that can be safely rebuilt.

Introduce a new schema version with a migration reader for old documents. Existing primitive recipes should continue to load. Migrate old objects lazily or through an explicit upgrade transaction, not by silently altering their geometry.

Retain separate IDs for document objects, source parts, assembly occurrences, feature nodes, CAD faces where trackable, and derived display meshes. Store object and source revision hashes for selective invalidation.

Test complete save/quit/reopen and undo for imported meshes, exact solid geometry, parameter changes, material overrides, artwork links, camera state and assemblies. A renderer migration must not force a project file-format migration by itself unless absolutely necessary.

## 12. Delivery Phases and Gates

### Phase 0: Foundation audit and baselines

Map existing SceneKit usage, recipe limitations, mesh generation, persistence and exports. Capture fixtures, native UI tests, render screenshots, performance measurements and current docs. Deliver an architecture map and migration checklist.

**Gate:** Existing tests pass and the baseline is reproducible.

### Phase 1: Renderer-neutral interface and RealityKit spike

Implement the renderer contract, dual-backend test configuration, sample high-detail mesh, live artwork, camera controls, object selection and offscreen render. Benchmark the spike against the current renderer.

**Gate:** Written go/no-go against all Section 4.2 tests. RealityKit is preferred; a custom Metal path requires concrete evidence of blockers.

### Phase 2: Migrate rendering consumers

Move Table, native inset previews, Studio and relevant print views to the accepted renderer. Match existing scene behavior before changing its aesthetics. Remove shipping SceneKit once parity is established.

**Gate:** No SceneKit dependency in the shipped application, complete camera and saved-project regression suite passes.

### Phase 3: OCCT bridge and exact CAD basics

Integrate pinned OCCT, create the C++ boundary and kernel service, support B-rep primitives, profiles, extrude, revolve, boolean, fillet/chamfer, shell, sweep and loft as staged capabilities, tessellate to the renderer, and persist exact shapes.

**Gate:** Native app and MCP generate, modify, undo, save/reopen and export a multi-feature exact solid. Invalid operations return actionable errors without damaging the previous revision.

### Phase 4: Interchange and complex asset support

Implement prioritized GLB/glTF import, STEP import/export, source-preserving materials/assemblies and view/edit capability flags. Add USDZ and OBJ/STL based on verified support and user value.

**Gate:** Detailed externally authored jacket and hard-surface device load with correct scale, hierarchical parts and appearance; STEP part retains measurable CAD geometry and can be assembled with native parts.

### Phase 5: Feature graph and agent authoring

Expose the new geometry and inspect/validate commands to MCP and native UI. Implement structured operation graphs, regeneration, editable parameter inspectors, stale-edit protection and typed diagnostics.

**Gate:** Without modifying application source, the agent produces an editable clock enclosure, lamp housing, vase and structured box/enclosure using real modeling operations.

### Phase 6: Quality, production, and performance

Improve shading, materials and selection; add display mesh LOD, incremental rebuilds, geometric repair/validation, curved artwork placement where supported, Studio quality, and import guardrails.

**Gate:** Complex collections remain responsive, production exports have correct dimensions and valid geometry, and all prior Form 2D/textile/project workflows still work.

**Scheduling:** Renderer migration and CAD kernel exploration may run in parallel against the renderer-neutral contracts. Do not delay all mesh import work until the exact CAD kernel is complete. Do not merge incomplete architectural replacements into a known-good baseline without passing their gates.

## 13. Acceptance Demonstrations

The implementation is accepted when these real workflows function end to end:

**A. Sophisticated imported jacket**
Import a detailed textured GLB jacket. Preserve parts, visible material quality, scale and position. Attach a separate patch/artwork asset. Create a colorway variant. Save/reopen. No claim of garment pattern editability.

**B. Exact clock enclosure**
Agent creates a 7-inch-diameter case, 2-inch depth, recessed dial, back opening, movement cavity placeholder, mount points and softened edges. Expose editable diameter, depth, bezel and wall-thickness parameters. Change diameter; downstream geometry updates predictably. Export STEP and a validated fabrication mesh. Missing movement dimensions remain flagged.

**C. Sculptural printable vase**
Agent builds a smoothly curved vessel from a sketch/profile and revolve or loft, with controllable wall thickness and a stable opening. Modify height and profile, inspect cross-section, validate closed printable geometry, then send only to the existing local slice-preview pipeline.

**D. Lamp with true features**
Create a base, hollow shade, support arm and openings as editable components, using sweeps/lofts/booleans/fillets rather than only fused primitives. Edit major proportions and verify component transforms and clearances.

**E. Packaging and 2D preservation**
Load existing folding sleeve and cyanotype kit. Dielines, scores, live artwork, typography, 2D Canvas, production exports, and undo must remain unchanged or improve. Avoid converting packaging construction to generic solids that lose its domain knowledge.

**F. Scene migration and stress test**
Open a Table containing imported mesh products, native CAD parts, references, artwork, fabric swatches, and multiple iterations. Maintain correct picking/camera behavior and sustained interactive responsiveness. Test reloads, cache invalidation, memory release, and Studio PNG quality.

## 14. Quantitative Quality Targets

Establish baselines on a named supported Mac and record hardware/OS and asset complexity. Initial targets to verify and refine:

- Interactive Table and ordinary selection/navigation: target 60 fps for benchmark scenes, without UI blocking during geometry generation.
- Object transform updates: no B-rep regeneration or unnecessary mesh upload.
- Direct native parameter edits: preview feedback should begin promptly; report median/p95 rebuild latency per feature class rather than claiming every operation is instant.
- Save/reopen: no loss of exact dimensions, object IDs, source attachments, material assignments, parameters or operation order.
- CAD integrity: valid solids pass kernel validity checks; open/invalid solids are explicitly labeled.
- Imported fidelity: compare standard renders and object dimensions against known Blender and CAD references, recording differences.
- Export fidelity: measured STEP solid bounds and mesh outputs agree with native mm geometry within documented tolerances.
- Regression: the existing automated and native acceptance suites remain green, with new geometric/renderer stress tests.

Performance limits for import size and geometry complexity must be documented and tested instead of advertising arbitrary complexity.

## 15. Non-Goals for This Upgrade

- Rebuilding the 2D vector and typography editor.
- Replacing Form's product, material, or project architecture wholesale.
- Training a proprietary 3D foundation model.
- Full cloth simulation or production garment pattern drafting.
- Feature-history reconstruction from imported STEP files.
- Guaranteed parametric editability of arbitrary imported meshes.
- Full Fusion 360/FreeCAD-level sketch constraints, assemblies, drawings, CAM, or FEA in the first pass.
- Direct printer job transmission or hardware activation.
- A web/electron renderer or an embedded game engine without a proven need.

## 16. Immediate Instructions to the Implementing Agent

1. Inspect the current `codex/form-v0.1` source, branch head, existing test harness and local working tree; summarize verified vs. proposed behavior.
2. Deliver an architecture diagram and exact SceneKit dependency inventory.
3. Create the renderer abstraction and a working RealityKit proof of capability **before** deleting SceneKit.
4. In parallel, prototype the OCCT bridge with one real profile → extrude → cut → fillet → STEP export pipeline, including save/reopen and cancellation-safe errors.
5. Prototype importing one complex textured jacket mesh, preserving hierarchy and materials independently of the CAD work.
6. Report the measured spike results and recommended implementation sequencing, then continue through phase gates as implementation authority permits.
7. Add regression evidence and update project documentation with each integrated stage. Never claim a capability is complete because its UI control exists; demonstrate actual geometry and retained project state.

**Definition of done:** Form can display sophisticated external models and its agent can author genuinely complex, editable, dimensionally credible geometry through durable domain operations, while the native app no longer depends on SceneKit and all existing Form workflows remain intact.

---

## Source and implementation references

- Current Form status: `https://github.com/rustyameadows/form/blob/codex/form-v0.1/docs/project-status.md`
- Current architecture: `https://github.com/rustyameadows/form/blob/codex/form-v0.1/docs/architecture.md`
- Third-party geometry integration precedent: `https://github.com/rustyameadows/form/blob/codex/form-v0.1/docs/third-party-geometry.md`
- Camera contract: `https://github.com/rustyameadows/form/blob/codex/form-v0.1/docs/camera-navigation.md`
- SceneKit deprecation/RealityKit transition: `https://developer.apple.com/videos/play/wwdc2025/288/`
- RealityKit `MeshResource`: `https://developer.apple.com/documentation/realitykit/meshresource`
- Open CASCADE Technology and licensing: `https://github.com/Open-Cascade-SAS/OCCT`
- MetalKit `MTKView`: `https://developer.apple.com/documentation/metalkit/mtkview/`
