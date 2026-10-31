# Object Views toy-car demo

The separate demo app is `build/LAB-object-views-stable.app`. It uses the isolated
library in `.local/ObjectViewStableDemo` and does not need the normal LAB
library. Reopen it from this worktree with:

```sh
bash scripts/run-object-view-demo.sh
```

Open **Object views / Toy car study** from Home if the study is not already
open. To create another copy, choose **File → New from Study → Object Views —
Toy Car**. The source car and artwork page are in Split view. Select a view on
the canvas to see its 3D preview, Spin, size, treatment and link controls in the
inspector. Canvas actions offers **Place four object views** for another object.

The source car is a project-local procedural recipe with editable length and
width. Its four sample placements include vector silhouettes, line illustration
and a transparent rendered image. Use Canvas actions to export the page. SVG contains vector paths and the
rendered image; PDF contains the page artwork. Rendered views use LAB's existing RealityKit scene
materials and lighting. Render resolution is set per placement.

To rebuild the demo bundle from this checkout, quit the demo app and run
`bash scripts/build-object-view-demo.sh` from a normal Terminal. Install the pinned OCCT engine first using `scripts/install-occt.sh`. Alternatively,
`LAB_OCCT_ROOT` and `LAB_OCCT_ARCHIVE` can point to an existing installation and
its source archive. The script builds a separate bundle with a separate application
identifier.

This is a working subset of the broader brief: camera perspective/framing,
cel shading, hatching, halftones, curve simplification and pattern view-angle
variation remain to be implemented. Vector generation has geometry and
complexity limits; native rendered output inherits the current renderer's
material and UV support.

Views use a fixed object-space frame when their angle changes. Existing placements made before this update keep their saved appearance until they are refreshed or reconfigured; the first regeneration may reframe them once to adopt the stable scale. Their placement size and transforms remain intact.
