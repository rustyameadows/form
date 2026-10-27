# Function, Fabricate and Studio · LAB 0.5

These environments share LAB's type, colors and controls, but each has a different working structure. Form retains the freeform Canvas and Table. The established primary-drag orbit, Shift-drag pan and named whole-project views remain the navigation contract.

## Function: how does it work?

Function is a technical bench for **any supported medium**. Its component navigation, central review and contextual controls follow the selected object:

- Lamps and other parametric objects retain their original dimensions and component parameters.
- Exact CAD objects retain their feature/model controls.
- Fabric constructions expose original pieces, physical allowances, grain, notches, seam correspondence, assembly declarations and supported cloth behavior.
- Paper constructions expose identified panels, folds, glue joins, dimensions, clearances and opening behavior.

Assembly and relevant flat/panel/pattern views are available within this bench. Selecting a technical component addresses that individual object even when its visual arrangement belongs to a Form group. Technical review does not imply a new electrical solver, calibrated cloth fit or crease simulation.

## Fabricate: choose, prepare, review

The left rail presents five steps. You can revisit any step; incomplete choices remain visible and block the guide's final output actions.

1. **What to make.** Choose the source object. Paper supports a declared prototype quantity; other routes open their existing process-specific preparation.
2. **Process.** Explicitly choose from routes supported by that source. Each card explains why it is available. Opening Fabricate does not silently select a process.
3. **Material.** Review the declaration's origin and choose what will actually be used. Paper has editable name, caliper, GSM, grain and sheet dimensions, plus a separate measured/verified declaration. Applying stock is undoable and retains artwork coordinates. 3D printing requires an explicit saved filament and printer, stored in that object's print setup. Fabric assemblies retain their per-panel material snapshots; the original construction remains their editing home. Other routes identify the design material and lead to their detailed stock/thread/process controls.
4. **Prepare.** Paper reviews the real net on physical sheets with quantity, margin and spacing. Other routes open their actual bed, page, original-pattern, material-layout, embroidery or decoration preparation window.
5. **Review & export.** Paper exports cut/crease SVG, actual-size sheet PDF or an immutable production packet. Other processes retain their established detailed output review. Archive and collection tools remain directly accessible.

Material confirmation is scoped to the active source and session. Changing the source, process or material declaration invalidates it; unsaved paper-field changes must be applied before continuing. Confirmation records an explicit choice, not certification. Unknown grain or unmeasured material remains labelled. No step sends or starts a machine job.

## Studio: compose a presentation

Open Studio with the secondary aperture icon. The stage has its own camera; moving it does not move the design camera. Add existing products from the left menu, duplicate a selected instance, choose another product/variant as its source, and edit instance placement in millimeters. A shelf/riser prop has its own dimensions and color. Material overrides affect the instance; linked source geometry and artwork remain shared.

**Save scene** or **Cmd-S** stores the composition. The saved-scene menu recalls it without rebuilding design objects. A scene contains independent instance identities, source references, placements, visibility, backdrop, lighting, output dimensions and motion settings. Unsaved changes are labelled as a scene draft. Draft Undo/Redo uses the normal Edit menu; saving is one document Undo operation. Save or discard an edited draft before choosing another scene.

The Camera inspector exposes yaw, elevation, distance, target and projection. **Frame scene** fits the presentation instances. Drag, Shift-drag and scroll retain the same camera behavior as the Table. Perspective currently uses LAB's fixed 39° vertical field of view; lens, depth-of-field and object animation controls are not implied.

The camera-motion strip supports an orbit or an upright eased transition between captured start and end cameras. Capture start, reposition the camera, capture end, then scrub or play the motion. Playback is a presentation preview; committed product/cloth geometry remains static.

Image output preserves the chosen pixel size, within the existing 16-megapixel bound. Video streams actual RealityKit frames into H.264 MP4, with even pixel dimensions fitted within a 1920-pixel longest edge, 12/24/30 fps and at most 600 frames over 0.5–20 seconds. Export has progress and cancellation. A source/project change during capture rejects delivery. Existing output destinations are preserved.

- An image is delivered in a new `.render` folder with PNG and `render.json`.
- A video is delivered in a new `.motion` folder with `Video.mp4` and `render.json`.

Records identify the scene definition, source-design digest, dependent resource hashes and actual media dimensions/hash. They are provenance records rather than full source archives. Keep the `.form` project for editable sources. Missing product sources stay recorded for repair and block rendering; replacing a source does not silently retarget another product.

Existing saved shots remain available through **Existing saved shots…**. Their established camera/subject/export behavior is retained separately from the new scene-instance workflow.

## MCP

`form_studio_scene` provides `list`, `get`, `create`, `save`, `duplicate` and `delete`. `save` accepts the complete scene definition and requires its current revision when updating. Unknown fields, invalid numbers and oversized definitions are rejected atomically. Up to 32 scenes and 128 instances per scene are supported; attached component expansion is bounded.

```json
{"command":"create","name":"Retail shelf 01"}
```

Read the returned scene, edit its instance/source/placement/camera/motion fields, then save it:

```json
{"command":"save","scene":{"id":"…","revision":1,"name":"Retail shelf 01","instances":[],"camera":{},"pixels":{},"lighting":"soft-side-v1","surface":"Daylight","motion":{}}}
```

The second example shows the argument shape; use the complete valid definition returned by `create`/`get`. Native controls and MCP use the same model operations. `form_export` with a saved `scene_id` accepts `png` or `mp4` and a new absolute output-folder path. No external model or machine call is part of these operations.

The [overhaul plan and acceptance](environment-ui-overhaul.md) retains the [Function](design/environment-ui/function-concept.png), [Fabricate](design/environment-ui/fabricate-concept.png) and [Studio](design/environment-ui/studio-concept.png) image-generation concepts. Exact prompts and built-in-tool provenance are in [prompts.json](design/environment-ui/prompts.json). Concepts are design references; actual native screenshots and test records establish acceptance.
