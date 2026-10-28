# Cloth simulation foundation (schema 31)

This implementation integrates real cloth calculations with native controls, saved initial definitions, the local MCP bridge and explicit print preflight. Runtime motion remains transient. The integrated release passes 620 tests, the real packaged MCP workflow and actual native control/mouse acceptance. It has not been validated as calibrated fabric, predictive fit, a full garment assembly, or a production sewing process.

## Physical model

`ClothStudy` contains only the initial `ClothMesh`, explicit `ClothSettings`, and static analytic contact shapes. Geometry boundaries use millimeters; the solver uses meters, kilograms, seconds, gravitational acceleration in m/s², and distance-constraint compliance in m/N. Triangle areas determine vertex masses by lumping area/3 at a declared areal density. Supplied vertex masses are also supported. Material UV coordinates remain attached to rest topology.

Each substep predicts positions from velocity and external acceleration, then solves distance constraints using XPBD:

```
alphaTilde = compliance / h²
DeltaLambda = (-C - alphaTilde * lambda) / (sum(inverseMass * |gradient|²) + alphaTilde)
DeltaPosition = inverseMass * gradient * DeltaLambda
```

Multipliers accumulate across solver iterations and reset per substep. Warp, weft, shear and seam links have separate declared compliance. Global exponential velocity drag damps existing velocity before adding gravity; it is distinct from constraint-space Rayleigh damping. The implementation follows the authors' [XPBD formulation](https://mmacklin.com/xpbd.pdf), [ACM DOI](https://doi.org/10.1145/2994258.2994272).

Substeps and iterations remain explicit. The authors' [Small Steps paper](https://matthias-research.github.io/pages/publications/smallsteps.pdf) motivates using multiple smaller steps. This implementation does not claim exact timestep invariance: free-fall integration converges with smaller steps, and coupled constraints still require adequate resolution/iterations.

Grid panels use structural and diagonal distance constraints plus two-cell axial distance links as a bending proxy. This is mesh dependent; it is **not** an angular bending modulus or a conversion from a fabric manufacturer's stretch/stiffness declaration. The primary author's [cloth example](https://raw.githubusercontent.com/matthias-research/pages/master/tenMinutePhysics/14-cloth.html) and [Ten Minute Physics collection](https://matthias-research.github.io/pages/tenMinutePhysics/index.html) were reviewed for distance-constraint cloth, area masses and mesh normals. FORM's Swift implementation is independent.

## Contacts, pins and seams

Fixed pins have zero inverse mass and exact target positions. A zero-gap seam joins explicit vertex pairs; finite positive seam gaps are also allowed. Incompatible ideal links between two fixed targets are rejected. A pinned target cannot lie inside an inflated contact shape.

Static planes and spheres have a declared half-thickness offset. Swept vertex/sphere tests prevent a fast point crossing to the far side between substeps. Triangle/sphere contact projects the actual closest surface point with mass-weighted barycentric gradients, preventing the curved support from cutting through triangle interiors. Initial overlap is recovered before the velocity reference, avoiding an artificial rebound. Contact projection is inelastic, followed by bounded Coulomb tangential velocity reduction. Every constraint iteration rechecks contacts. Diagnostics separately report vertex/surface penetration, stretch ratio, distance error, seam gap and distance-constraint force estimates.

The current scope is **static analytic contacts**: vertex/plane, swept vertex/sphere, and discrete triangle/sphere nonpenetration. It does not include continuous moving-triangle contact, moving colliders, arbitrary collision meshes, self-collision, fabric layers, pressure/air, cutting allowances or full garment construction. A fast face with no vertex/sphere crossing can still tunnel between substeps; this is not a general cloth collision engine. The two-panel example demonstrates actual paired seam constraints and two pinned open-top points; its panels can intersect because self-collision is absent.

The sphere-drape acceptance fixture explicitly pins one central vertex to the sphere's top. Its other 288 vertices move under gravity and contact constraints. An entirely unrestrained sheet can slide off the sphere; the pin is a declared boundary condition, not an authored fold.

## Bounded, demand-driven lifecycle

- Mesh caps: 4,096 vertices, 8,192 triangles, 32,768 links; at most 16 static colliders.
- Declared frames: 1/240–1/30 s; 1–16 substeps, 1–24 iterations; finite 0.05–120 s study duration.
- A request advances 1–120 frames within a two-million-evaluation work estimate. Oversized requests fail before changing state. A numerical failure rolls the request back to its last accepted state, exposes an error, and requires Reset.
- Stop freezes positions, velocities and elapsed time. Start resumes. Reset restores the initial mesh, velocities and declared pins exactly.
- `ClothSession` owns runtime state, with one outstanding value-snapshot work item. Only its matching owner/generation/sequence token can publish. Stop, Reset, source edits, project/object changes, Undo/Redo, pin edits and closing invalidate pending results.
- Repeated frame reads and unchanged source binding perform no simulation. No timer, document write, history entry or network/device call exists in the core runtime.

## Surface and attachment mapping

`ClothSurface` reuses triangle indices and material UV sources while replacing only positions/normals. It copies the caller's material, keeps its properties, uses FORM's existing 100 mm/scene-unit scale, and leaves node transforms untouched. Surface bounds come from the actual moving vertices, for eventual focus/selection bounds.

`ClothSurfaceAnchor` binds a decoration point to a stable triangle and barycentric material coordinates. Its position, normal, material tangent and physical normal offset follow that same surface point. The front/back panels have separate triangle identities and outward normals; mirrored material coordinates preserve each panel's orientation. A collapsed local surface reports an error instead of inventing an attachment orientation.

## Native and MCP workflow

Create **Cloth studies** from Home for the prepared NASA materials lab, or add **Fabric drape** / **Seamed panels** to an existing project. Select a cloth object to use Run, Stop, Step and Reset in its contextual inspector. Solver/contact settings apply as one undoable source edit. Dimension, mass and resolution controls rebuild the initial template; changing them resets preview motion. Only one cloth study owns the runtime at a time. Activating another study resets the previous transient surface.

The material palette and artwork editor still work on the physical surface. Printed artwork and fabric-repeat textures stay attached to fixed material coordinates; actual raster sizes are capped at 2,048 pixels per edge. A separate object can use **Cloth placement** to choose a panel, Across/Down percentages, physical clearance and angle. Its anchor follows the moving surface at its physical size. Move drags project onto its current panel; moving a selected parent and decoration applies one translation. Detach to Table preserves its current world point and returns it to the Table plane orientation. Deleting a surface with attached decorations is rejected until they are detached or deleted together.

`form_cloth` shares that same owner/controller:

```json
{"command":"get","object_id":"…"}
{"command":"configure","object_id":"…","settings":{"friction":0.4,"substeps":8}}
{"command":"step","object_id":"…","frames":10}
{"command":"run","object_id":"…"}
{"command":"stop","object_id":"…"}
{"command":"reset","object_id":"…"}
{"command":"snapshot","object_id":"…","path":"/absolute/path/cloth-frame.json"}
{"command":"attach","object_id":"decoration UUID","surface_object_id":"cloth UUID","u":0.7,"v":0.25,"panel":0,"offset_mm":2}
{"command":"detach","object_id":"decoration UUID"}
```

Get returns the full initial definition and current diagnostics. Configure accepts partial settings or an exclusive complete `ClothStudy` definition; invalid settings/contacts/work budgets reject atomically. Step runs while paused, subject to the solver work cap. Get also reports current physical bounds; attached-object queries report their current world placement. Snapshot returns actual coordinates, normals, UVs, panel IDs and triangles, or writes a reviewable local JSON with byte count and SHA256. Run requires an open project view. Read/runtime operations bypass text-field commit notifications, project history, autosave and camera changes. Project/source/material/artwork/font changes and Undo/Redo invalidate transient work. Home, deletion and project switching clear it.

Only optional `ProductObject.cloth` and `clothAttachment` raise a document to schema 31. Current frames, velocities and tasks are never serialized. A saved project reopens at its declared initial state. Cloth is an **open flexible surface** and print/slice preparation rejects it until an explicit closed solid is created and validated. The prepared template does not operate any printer or sewing machine.

## Current evidence

The optimized core/surface/controller checkpoint passes 29 focused tests (the GPU render is skipped in a sandbox-only run and independently passed with Metal access), including analytical gravity convergence, compliant spring equilibrium at two timestep sizes/masses, multiplier accumulation across iterations, exact pins, actual seam closure, swept contacts, friction scaling, numerical rollback, bounded work/time and stale-result lifecycle handling. The 289-vertex, 512-triangle drape computes 90 frames (1.5 s simulated) in approximately 0.26 s on this development machine; this is a measured solver-only fixture, not a general frame-rate guarantee. The current finite vertex penetration is below 1e-7 mm and triangle-surface penetration is approximately 0.00251 mm (inside the declared 0.4 mm half-thickness), with a maximum edge stretch ratio below 1.1 under the fixture's declared proxy parameters.

Native surface/attachment tests verify stable UV/index buffers, physical scale, material retention, moving bounds and barycentric anchors. The offscreen Metal/SceneKit proof shows the calculated drape with a fixed printed material grid and stripe; the curved support no longer pokes through triangle interiors. The isolated Run/Stop/Step/Reset controller passes four lifecycle tests, including replacing the source from an actual running-frame callback; the old runner cannot continue publishing. Shared app integration tests additionally cover exact project/Undo/Redo/file preservation through runtime bridge calls, source settings Undo/reopen, current attachment/bounds updates, font/artwork invalidation, Home/project changes and explicit print rejection. The real packaged workflow and actual native controls now pass in the 620-test integration. Native Run/Stop reaches 195 frames on the 578-vertex seam study without source/history/camera or base-geometry changes; active friction-field Apply and one Undo are verified. Computer use found and corrected a redundant vertical texture flip; actual front/back Metal quadrant proofs and the running NASA panel verify readable orientation. Four real mouse directions isolate/reverse camera axes, and Perspective frames the whole project while a panel stays selected. See [validation](validation.md).

The shared-source validation log is `.local/validation/cloth31-integration-tests.log`: 30 core tests and 18 app tests pass (the app total includes four existing textile Move regressions). These include 44 cloth-specific cases and one sandbox Metal skip, covered separately by the native proof run. Headless AppKit tests use actual mouse handlers and SceneKit picking: a label drag changes its material point, parent+label selections translate once in either object order, and Undo/Redo restore the exact source. The guarded `scripts/smoke_cloth.py` workflow is prepared for the packaged app; it refuses ordinary libraries and independently checks snapshot coordinates, normals, physical contacts and SHA256 output metadata.
