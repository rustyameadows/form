# Project-defined parametric solids

LAB supports two complementary modeling sources: exact CAD feature graphs for engineering geometry, and project-defined implicit solids for rounded or organic forms. A solid recipe is editable project data. Application code handles generic operations and never dispatches on the recipe's name or ID.

`form_create_recipe` accepts ordinary `parts`, or `parts: []` with a `solid` definition. An explicit `replace: true` revises a project-owned recipe as one Undo operation. Existing matching object parameters are retained and validated. Built-in recipes cannot be replaced. `form_add_object` instantiates the definition; native inspector sliders and `form_update_object` use the same controls and validation.

A solid contains:

- `spacing`: an expression giving the physical sampling interval, 0.15–2 mm.
- `floorY`: optional planar trim, retaining geometry above that physical Y coordinate.
- `normalizeHeight`: optional final uniform scale to an explicit physical height, with the standing surface moved to Y=0.
- `nodes`: bounded construction groups and primitives.

Every numeric primitive value is an expression string. Expressions support arithmetic, `pi`, parameter variables, ordered local bindings, and these functions: `sin`, `cos`, `sqrt`, `abs`, `floor`, `ceil`, `round`, `fract`, `pow`, `atan2`, `min`, `max`, `clamp`, `mix`, and zero-based `pick(index, choices…)`. Function angles are radians. The parser does not execute code or evaluate Foundation expressions.

A group has `kind: "group"`, `children`, optional `count` and a unique local `index`, and optional ordered `bindings: [{name, expression}]`. Bindings and repeat indices are local to their subtree; they cannot overwrite parameters or ancestor bindings. Groups express radial arrays, spatial repetition, sampled curves, variable sections, layered relief and other constructions without adding application code.

The two initial solid primitives are:

| Kind | Required expression values | Optional values |
| --- | --- | --- |
| `segment` | `x, y, z, endX, endY, endZ, radius, endRadius` | `blend` |
| `ellipsoid` | `x, y, z, radiusX, radiusY, radiusZ` | `axisX, axisY, axisZ, roll, blend` |

A segment is a rounded tapered solid between two endpoints. Sampling a curve with overlapping segments forms a variable-radius spine. An ellipsoid's third radius follows its axis; roll rotates its other two axes. Blending is a bounded smooth union distance in mm; zero preserves the ordinary union. Colors and materials belong to the instantiated object.

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

Table, Studio and print preparation consume the same indexed surface. Primitives are fused volumetrically; they are not exported as intersecting display shells. The mesher uses consistent shared edge identities, outward winding and an optional flat sole. Geometry and render caches count actual buffers toward their memory budgets. Separate GPU chunks retain shared source normals and respect existing payload limits.

Use `form_solid` with `command: "inspect"` and an `object_id` to read actual bounds, triangle/vertex counts, connectivity, closed/oriented topology, volume and elapsed time. `export_stl` adds an unused absolute `.stl` path and exports the inspected millimeter surface in Z-up fabrication coordinates. It does not contact a printer. Existing destinations are preserved.

Limits are explicit: 24 recipe parameters, 512 KB solid source through MCP, 256 roots or children per group, depth 12, 32 local bindings per node, repeat count 0–1000, 12,000 expanded primitives, coordinates within ±1000 mm, radii 0.1–500 mm, blend 0–3 mm, 80 million field samples and two million output triangles. Out-of-budget construction fails with an error. Small features require a sufficiently fine sampling interval.

These are sampled design solids, not exact BRep geometry. Topology inspection does not certify print strength, resolve process-specific support requirements, or establish safe consumer-toy use. Exact feature models remain the appropriate source for toleranced engineering interfaces. Schema 55 preserves solid definitions; older project schemas remain unchanged until they use a new capability.
