# Actual stitches on physical textile faces

Schema 28 extends [regenerable embroidery](embroidery.md) with explicit underlay, backtracking locks, physical thread width, and a 3D surface derived from the same generated needle commands as the native editor and production exports. A configured patch no longer displays the original artwork as a printed approximation. It displays its actual needle paths over the existing fabric base; the authored patch construction/border remains independent presentation geometry.

The surface keeps the full physical object-face coordinates. Hoop-centered integer needle coordinates are mapped to the corresponding centered millimeter face without fitting or recentering their bounds. A small motif stays small and keeps its original placement. Solid needle segments become thread; jumps, trims, color changes, and end commands break visible runs. Travel never appears as thread on the garment. Thread colors come from the same palette used by SVG and the ordered DST thread sidecar. Source compound holes and masks are respected by digitizing and remain open in the thread coverage.

A transparent diffuse map represents the needle paths. A normal map approximates rounded thread cross-sections along those same paths; it does not simulate displaced cloth, tension, physical thread stacking, or fit. Width is the configured physical thread diameter, defaulting to 0.22 mm when no process override is saved. Maps are capped at 1024 pixels on their longest edge, with the physical aspect ratio retained. They do not create a mesh per stitch. Both CPU image memory and corresponding GPU texture cost are accounted for in bounded caches.

## Explicit process settings

`EmbroideryDesign.process` is optional. Opening **Configure thread and locks** in the native Embroidery window adds it; existing schema-25 designs retain their default needle behavior until process settings are supplied.

- `threadDiameter`: 0.1–0.8 mm, used for native/SVG thread width and physical surface coverage. Explicit process preflight also keeps running/satin thread bodies clear of clipping boundaries and increases fill endpoint clearance for wider thread.
- `tieIn`, `tieOff`: independent opt-in booleans, false by default.
- `tieLength`: 0.2–1.5 mm; `tieRepeats`: 1–3.

Tie-in emits back-and-forth needle movements along the first available existing stitch segment after a thread start or trim. Tie-off backtracks along the last existing segment before a trim or end. The distance is capped to that segment so the lock does not invent a new route across a source hole. Short non-trimmed travel does not create a fresh lock on every fill row. These are actual command sequences tagged `tieIn`/`tieOff` in JSON/SVG, subject to the normal hoop, stitch, and command budgets. They are not a machine-specific knot guarantee.

Regions may independently include `underlay`:

- `method: centerWalk` requires satin. It follows the source centerline to its end and back before the satin rails. `stitchLength` is physical millimeters.
- `method: sparseFill` requires fill. It emits a lower-density scanline pass at 90° to the top-fill angle before the top stitches. `spacing` is 0.8–8 mm and at least 1.5 times the top-fill spacing. `inset` is 0.2–3 mm. The effective source and clip boundaries are stroked to obtain an inset exclusion region; scanline intersections retain compound holes and nested masks. A region that cannot produce the requested underlay fails explicitly rather than displaying a fictitious pass.

Underlay uses the region's thread and is tagged `underlay`; it is included in the native command playback, actual surface, JSON, SVG, DST, stitch counts, and limits. Center-walk and sparse-fill are bounded basic algorithms. There is no inferred contour/zigzag underlay, fabric profile, pull compensation, automatic routing, density tuning, needle selection, speed control, or verified sew-out. All process settings remain explicit and require sample review for production.

## Shared state, invalidation, and performance

`EmbroiderySurface` caches generated programs, color/normal maps, and invalid-source results. Its signature includes physical face size/corner, needle source geometry with stitch-role layers retained, saved digitizing/process settings, texture size, and installed-font revision. Placement and attachment offsets are absent. Thread/region/source edits invalidate the affected surface; idle sync, camera movement, and moving a patch reuse it.

`TableSceneController` recognizes embroidery appearance edits and replaces only the local face material. Base/border geometry remains owned by the existing object; cached SceneKit geometry/materials are copied for the face so changing one decoration cannot recolor another. Font invalidation clears shared surface resources. A missing source or failed preflight suppresses the invalid needle face, keeps its fabric/construction geometry, and exposes **Embroidery needs attention** in the inspector. It never silently falls back to printed source artwork. Removing digitizing settings explicitly returns the normal artwork-face workflow.

Native controls and `form_update_object embroidery` share these fields and Undo. `form_export_artwork` regenerates the same program and reports `underlay_stitches`, `tie_in_stitches`, `tie_off_stitches`, and `thread_diameter_mm` alongside the existing physical preflight. The existing MCP tool surface is unchanged. No hardware is contacted.

## References and evidence

Ink/Stitch's official [satin underlay documentation](https://inkstitch.org/docs/stitches/satin-column/) describes center-walk and more advanced underlay families. Its [fill documentation](https://inkstitch.org/docs/stitches/fill-stitch/) describes lower-density supporting passes, while [tack and lock stitches](https://inkstitch.org/docs/stitches/lock-stitches/) distinguishes thread securing from ordinary stitch work. FORM implements the specific bounded algorithms above independently; those references do not establish identical stitch routing or physical results.

`EmbroideryProcessTests` checks actual underlay/lock order and coordinates, hole/inset preservation, bounded failure and schema defaults/persistence, exact physical texture placement, transparent travel, normal-map bounds, and cache/font invalidation. `EmbroiderySurfaceTests` checks real native SceneKit materials and snapshots, linked-source/copy isolation, preserved base/border geometry, source/process/font updates, cached invalid-source recovery, shared Undo/preflight/exports, and actual thread sidecars. The external Pyembroidery reader independently decodes the resulting commands as documented in [embroidery](embroidery.md). Integrated packaged/native acceptance is recorded separately in [validation](validation.md).
