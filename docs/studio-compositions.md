# Studio compositions

Studio arranges linked copies of your products for a render. Each saved scene owns its instances, placement, camera, lighting and output size. Moving a Studio instance leaves the source object, its artwork and the Table camera unchanged. Several instances can reference the same design; a different printed design uses a different source object.

## Arrange a scene

Open Studio with the aperture button beside the main environment tabs. Choose a saved scene in the left sidebar, or create an **Empty scene** and use **Add to scene** to add products. **From Table** starts with the current physical objects and their existing placement.

Click a product in the stage or its name in the instance list to select it and open its placement controls. Transform handles appear directly on the selected instance: drag the red X, green Y or blue Z arrow to move along that world axis, or drag the rotation ring to turn around the vertical axis. These handles work in every tool, including Orbit. The stage dock uses the same buttons as Canvas and Table:

- **Move** drags the selected instance across the ground plane, retaining its height.
- **Transform handles** shows or hides the object controls; it starts on.
- **Orbit** changes the camera. Dragging empty space also orbits; Shift-drag pans and scrolling zooms.
- **Focus selected** frames just the selected instance; **Frame scene** fits all visible scene instances.

The Instance inspector provides precise X, Height (Y), Z and vertical rotation fields, visibility, and a product source picker. Duplicate an instance to reuse the same design at another placement. Select another source in the picker to compare an independently editable design. Appearance overrides change the scene instance's material; they do not create new artwork designs. Lift and Rotate also remain available as keyboard tools for whole-object dragging.

A completed placement drag is one scene Undo step. Escape or an interrupted gesture restores its starting placement. Save the scene to persist the draft. Choosing another scene offers Save, Discard or Cancel when the current draft has changes.

## Render the alternatives

Save separate scenes for compositions and camera angles, then export each with **Export image**. A scene is a composition, rather than a saved revision of the design: its next render uses the current linked source artwork. Image output is a PNG and its `render.json` record in a new `.render` folder. Existing output folders are preserved.

The [Dispatch examples](../examples/studio-compositions/README.md) include a five-carton aligned stack, a second camera on that stack, a second print design, an angled cluster, and a side-by-side comparison. The stack spacing comes from the actual folded paper geometry and stock caliper.

## Agent authoring

`form_studio_scene` lists, gets, creates, saves, duplicates and deletes complete scene definitions. Save uses the current scene revision; each instance has a unique ID, a source object ID (or prop), `positionMM`, `rotationDegrees` and visibility. Repeated source IDs create real presentation instances without duplicating source designs. `form_export` with `format:"png"` and `scene_id` renders the saved scene through the same native renderer.

See [the reproducible example script](../scripts/create_dispatch_studio_examples.py) for construction, independent artwork, physical bounds, camera composition, exports and saved-project checks using the public tools.

[Native interaction and visual evidence](validation/studio-composition/native-results.json) covers the shared controls, real stage picking, world-axis movement, yaw rotation, cancellation, Undo, camera framing and clean render output.
