# Project-defined parametric solids

LAB supports exact CAD feature graphs for engineering geometry and project-defined constructions combining sampled solids with analytic profiled sweeps. A solid recipe is editable project data. Application code handles generic operations and never dispatches on the recipe's name or ID.

`form_create_recipe` accepts ordinary `parts`, or `parts: []` with a `solid` definition. An explicit `replace: true` revises a project-owned recipe as one Undo operation. Existing matching object parameters are retained and validated. Built-in recipes cannot be replaced. `form_add_object` instantiates the definition; native inspector sliders and `form_update_object` use the same controls and validation.

A solid contains:

- `spacing`: an expression giving the physical sampling interval, 0.15–2 mm.
- `floorY`: optional planar trim, retaining geometry above that physical Y coordinate.
- `normalizeHeight`: optional final uniform scale to an explicit physical height, with the standing surface moved to Y=0.
- `fillVoids`: optional explicit filling of enclosed air. Openings connected to exterior air remain open. Disabled by default.
- `nodes`: bounded construction groups and primitives.

Every numeric primitive value is an expression string. Expressions support arithmetic, `pi`, parameter variables, ordered local bindings, and these functions: `sin`, `cos`, `sqrt`, `abs`, `floor`, `ceil`, `round`, `fract`, `pow`, `atan2`, `min`, `max`, `clamp`, `mix`, and zero-based `pick(index, choices…)`. Function angles are radians. The parser does not execute code or evaluate Foundation expressions.

A group has `kind: "group"`, `children`, optional `count` and a unique local `index`, and optional ordered `bindings: [{name, expression}]`. Bindings and repeat indices are local to their subtree; they cannot overwrite parameters or ancestor bindings. Groups express radial arrays, spatial repetition, sampled curves, variable sections, layered relief and other constructions without adding application code.

The two initial solid primitives are:

| Kind | Required expression values | Optional values |
| --- | --- | --- |
| `segment` | `x, y, z, endX, endY, endZ, radius, endRadius` | `blend, aspect, endAspect, roll` |
| `ellipsoid` | `x, y, z, radiusX, radiusY, radiusZ` | `axisX, axisY, axisZ, roll, blend` |

A segment is a rounded tapered solid between two endpoints. Optional cross-section aspect ratios (0.25–1) vary independently at its ends; roll rotates their plane. This supports flattened fins and transitions to finite circular tips. Sampling a curve with overlapping segments forms a variable-radius spine. An ellipsoid's third radius follows its axis; roll rotates its other two axes. Blending is a bounded smooth union distance in mm; zero preserves the ordinary union. Colors and materials belong to the instantiated object.

For example, a reusable radial connector can be described with a repeated group. Its `arms` and `reach` are ordinary recipe parameters:

```json
{
  "spacing": "0.3",
  "nodes": [{
    "kind": "group", "count": "arms", "index": "i",
    "bindings": [{"name": "angle", "expression": "i*2*pi/arms"}],
    "children": [{
      "kind": "segment",
      "values": {
        "x": "0", "y": "0", "z": "0",
        "endX": "reach*cos(angle)", "endY": "8", "endZ": "reach*sin(angle)",
        "radius": "4", "endRadius": "2", "blend": "0.5"
      }
    }]
  }]
}
```

Table, Studio and print preparation consume the same indexed surface. Sampled segment/ellipsoid primitives are fused volumetrically. The mesher uses consistent shared edge identities, outward winding and an optional flat sole. Sign-preserving distance conditioning and topology-checked short-edge collapse remove numerical slivers and reduce upload cost without reversing faces. Geometry and render caches count actual buffers toward their memory budgets. Separate GPU chunks retain shared source normals and respect existing payload limits.

## Analytic profiled sweeps

Schema 56 adds `kind: "sweep"` nodes. These directly tessellate a curved, varying closed profile, retaining smooth faces or crisp profile creases independently of voxel pitch. Their `sweep` payload contains:

- `samples`: expression for 2–128 path samples; `variable`: a unique local coordinate running from 0 to 1.
- `bindings`: optional ordered local bindings evaluated at each path coordinate.
- `values`: expression strings for `x`, `y`, `z`, `radiusX`, `radiusY`, and optional `roll` in radians.
- `sides`: 3–64 ellipse sides, default 16; or `profile`: 3–64 simple closed polygon points `[[x,y],...]` within ±10. Omit a repeated final endpoint and collinear corners.
- `initialNormal`: optional three expression strings setting the first profile X axis. It must be nonzero and not parallel to the first path segment.
- `smoothProfile`: default true. False retains each profile edge's crease. End caps retain separate normals in either mode.

The curve uses stable parallel transport. Section radii remain positive, 0.005–500 mm, including deliberate finite capped tips. Coordinates remain within ±1000 mm. Repeated nodes can instance the same authored curve with local bindings. Aggregate analytic output is limited to 1.8 million triangles, and the combined surface to two million triangles/four million indexed vertices. `floorY` is unavailable in analytic assemblies; author capped geometry above the intended sole instead.

For example, a gently curved, tapered formed strip:

```json
{
  "kind": "sweep",
  "sweep": {
    "samples": "24", "variable": "u",
    "values": {"x":"3*sin(u*pi/2)","y":"length*u","z":"0","radiusX":"mix(5,0.2,u)","radiusY":"0.6"},
    "profile": [[-1,-0.5],[-0.8,-1],[0.8,-1],[1,-0.5],[1,0.5],[0.8,1],[-0.8,1],[-1,0.5]],
    "initialNormal": ["1","0","0"], "smoothProfile": false
  }
}
```

Analytic surfaces assemble without Boolean union. Intersecting closed shells are not automatically one valid fabrication solid. Inspection reports `representation`, `analytic_sweeps`, geometrically welded component count and an explicit qualification. Topology checks do not test all self-intersections. Preserve the detailed assembly and evaluate a separate union/manufacturing representation when needed; never silently replace the authored master with a coarse sampled surface.

Use `form_solid` with `command: "inspect"` and an `object_id` to read actual bounds, triangle/vertex counts, connectivity, closed/oriented topology, volume and elapsed time. `export_stl` adds an unused absolute `.stl` path and exports the inspected millimeter surface in Z-up fabrication coordinates. It does not contact a printer. Existing destinations are preserved.

Limits are explicit: 24 recipe parameters, 512 KB solid source through MCP, 256 roots or children per group, depth 12, 32 local bindings per node, repeat count 0–1000, 12,000 expanded primitives, coordinates within ±1000 mm, radii 0.1–500 mm, blend 0–3 mm, 80 million field samples and two million output triangles. Out-of-budget construction fails with an error. Small features require a sufficiently fine sampling interval.

Schema 57 optionally retains `previewNodes`, a separate bounded construction using the same parameters, physical settings and normalization. Both definitions are validated before mutation. `evaluate(parameters, useEditingPreview: true)` selects it explicitly; default evaluation and export retain the full source. Schema 62 preserves both definitions after integration with the other project features; this interaction update adds no project schema or modeling command.

## Native parameter interaction

The `codex/solid-render-quality` checkpoint integrates the existing source into native controls. A slider changes a transient parameter draft immediately and queues its authored `previewNodes` on a background worker. A recipe without `previewNodes` uses its full source in the background instead. Neither kind of held result changes the accepted project. The last accepted full mesh is retained for cancellation or failure. The control remains the same native field/slider while work completes; Escape cancels that gesture.

On release, the coordinator requires a valid full-detail surface before calling the ordinary `form_update_object` command once. A matching full surface already evaluated during the gesture can be reused. A released edit remains an intention while its full result is pending: another control starts from those pending values, and cancelling the later control restores the earlier intention. Valid successive releases publish in order as separate Undo steps. Pending gesture boundaries are bounded to 16 per object; older boundaries can coalesce while their accumulated parameter values remain in later intentions.

Each request owns a project epoch, object, recipe, complete parameters and unique token. Superseded work is cancelled and a late result cannot replace a newer request or another project. The sampled mesher checks a thread-safe cancellation probe during field sampling, void filling, triangulation and cleanup; cancelling a task does not merely hide an obsolete result. Undo/Redo and reopening can reuse matching full-source cache entries through the same ownership checks.

Agent `form_update_object` retains its established command semantics: core validation accepts the project parameters, then derived full geometry is prepared in the background. A later geometry failure retains the last valid displayed mesh and reports an issue; the accepted agent parameters remain available for repair. Native parameter drafts wait for full geometry before accepting their change. Both paths use the same saved recipe and parameters.

## Full-detail consumers and resource bounds

Table and Studio composition editing defer cold solid construction. Studio captures, print preparation, isolated object views and ordinary native `form_solid` inspection/STL export prepare full sources asynchronously. Editing previews cannot replace the full-source cache. Full preparation returns strong per-object surfaces so cache eviction cannot silently turn a capture into a synchronous cold rebuild. Identical instances share their full buffers and count once against the aggregate source budget.

Linked vector views keep their last path with a pending marker while a changed full source is unavailable. Completion updates the derived path without adding an Undo step. A pending linked vector or rendered view cannot be exported as if it represented the current source. The ordinary native `form_solid` tool keeps its existing `inspect`/`export_stl` commands and adds full-source quality/revision evidence; its topology, shell connectivity and STL encoding run off the UI actor. `form_batch` already excludes `form_solid` from its allowed operations.

Mesh evaluation and native inspection/STL CPU work share two process-wide worker slots, with at most 128 requests waiting for a slot. Interactive retained surface buffers have a 256 MiB budget and at most 128 object entries; full-source cache entries have a separate 96,000,000-byte/12-entry bound. Final preparation permits at most 512 MiB of unique retained full-source buffers. A preview which cannot fit alongside its last accepted full surface is rejected without accepting its parameters; a later full release can still succeed. These are resource limits, not geometric or visual quality guarantees.

The integrated gate passes 89 test methods and the compatibility gate passes 43, both with zero failures. Fourteen coordinator methods overlap, giving 118 unique passing methods; all 14 coordinator, three surface-worker and three native cancellation cases pass. The signed release passes deep/strict verification and the ordinary LAB app runs as the sole instance.

Native MCP checks exercised sampled-union spacing 0.45 mm and an analytic 96-sample/64-side source, with 14 rapid parameter updates and 15 status requests. The recorded helper roundtrip summary was median 24.07 ms and maximum 55.41 ms. Full-source inspection/revisions, STL export, Undo/Redo, reopening and camera preservation were checked, and three 2000 × 1600 native renders were reviewed. Native accessibility slider actions changed Height 146 → 155 and Width 90 → 96; Command-Z restored the two values as separate Undo steps. These are command/accessibility-control measurements, not a physically held mouse drag, hardware-event-to-display latency or FPS result. The earlier private reference-tree visual goal remains unfulfilled. See [the consolidated validation record](quality-consolidation-validation.md) and [the handoff](modeling-handoff.md).

These constructions are not exact BRep geometry. Topology inspection does not certify print strength, resolve process-specific support requirements, or establish safe consumer-toy use. Exact feature models remain the appropriate source for toleranced engineering interfaces. Schema 62 preserves sampled definitions, analytic sweeps and editing-preview definitions. This reconciles the earlier development schemas with the paper, paint, font, image generation and object-view features integrated on main. Older project schemas remain unchanged until they use a new capability.
