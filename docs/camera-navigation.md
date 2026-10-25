# Camera navigation

The default Table tool is **Orbit**. A drag anywhere, including over an object, rotates the view. A click still selects; Shift-click extends selection; double-click focuses. **Pan** (`H`) moves the view with the pointer. **Move** (`V`) explicitly enables object placement. **Orbit** (`O`) returns to navigation.

Temporary controls remain available: Space-drag or Option-drag pans, right-drag orbits, and middle-drag pans. Shift reduces orbit and pan sensitivity to one quarter; in Move mode it retains 10 mm placement snapping. Scroll up zooms in and scroll down zooms out. Pinch changes zoom. Fit (`⌘0`), Focus (`F`), and perspective/overhead/front (`1`/`2`/`3`) provide quick recovery.

## Behavior

- Both orbit axes follow the dragged surface. Sensitivity scales with viewport height.
- Pan uses the camera's actual right/up vectors and visible height, including projection and zoom. A 50-point drag moves a point on the focus plane by 50 screen points in either axis.
- The camera uses a fixed world-up vector on every update. Repeated orbit and pan gestures cannot accumulate roll.
- Orbit preserves orthographic projection. Elevation can pass below the Table to inspect undersides, with a stable upright horizon and limits just short of either pole. The ground hides when viewed from underneath.
- Zoom supports small objects and remains bounded. Camera gestures, zoom buttons, presets, Fit, and Focus save their resulting composition.
- Camera gestures update the existing scene and request drawing. They do not rebuild object geometry or enable continuous idle rendering.

The same camera implementation serves the Table, live object inset, and print-bed preview. Print preparation remains local; camera navigation sends no printer commands.

## Regression coverage

Camera tests verify the projected direction of orbit, exact pan displacement at several viewport heights, azimuths, elevations, and projections, reversible zoom, distance limits, and 1,200 repeated camera updates with an upright horizon. Framing tests include views above and below the Table.

Native mouse validation and measured results are recorded in [validation notes](validation.md).
