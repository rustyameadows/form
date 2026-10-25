# Camera navigation

The default Table tool is **Orbit**. A drag anywhere, including over an object, rotates the view. A click still selects; Shift-click extends selection; double-click focuses. **Pan** (`H`) moves the view with the pointer. **Move** (`V`) explicitly enables object placement. **Orbit** (`O`) returns to navigation.

Temporary controls remain available: Space-drag or Option-drag pans, right-drag orbits, and middle-drag pans. Shift reduces orbit and pan sensitivity to one quarter; in Move mode it retains 10 mm placement snapping. Scroll up zooms in and scroll down zooms out by default. Pinch changes zoom. Fit (`⌘0`), Focus (`F`), and perspective/overhead/front (`1`/`2`/`3`) provide quick recovery.

The sliders button at the end of the camera bar opens **Camera navigation**. **Move camera**, the default, moves the camera right on a rightward drag and raises it on an upward drag. **Turn object** reverses both orbit axes, retaining the earlier grab-and-turn behavior. Orbit speed ranges from 25% to 200%, starting at 75% for finer positioning. **Reverse scroll zoom** accommodates the opposite wheel preference. Done or Escape closes the panel. Reset restores the defaults.

These preferences are saved locally across launches, independently of project files and Undo. The Table, Studio, artwork object inset, and print-bed preview share the same live preferences. Zoom buttons, pinch, and pan retain their direct behavior regardless of orbit direction.

## Behavior

- Both orbit axes respect the chosen direction. Sensitivity scales with viewport height and the saved orbit speed.
- Pan uses the camera's actual right/up vectors and visible height, including projection and zoom. A 50-point drag moves a point on the focus plane by 50 screen points in either axis.
- The camera uses a fixed world-up vector on every update. Repeated orbit and pan gestures cannot accumulate roll.
- Focus, isolation, and Fit reserve space for the Table's floating inspector and camera controls. Framing keeps the orbit pivot at the subject's center, so the next orbit stays centered on the object.
- Orbit preserves orthographic projection. Elevation can pass below the Table to inspect undersides, with a stable upright horizon and limits just short of either pole. The ground hides when viewed from underneath.
- Zoom supports small objects and remains bounded. Camera gestures, zoom buttons, presets, Fit, and Focus save their resulting composition.
- Camera gestures update the existing scene and request drawing. They do not rebuild object geometry or enable continuous idle rendering.

The same camera implementation serves the Table, live object inset, and print-bed preview. Print preparation remains local; camera navigation sends no printer commands.

## Regression coverage

Camera tests verify both orbit conventions, bounded sensitivity, scroll direction, settings persistence, shared preview preferences, exact pan displacement at several viewport heights, azimuths, elevations, and projections, reversible zoom, distance limits, and 1,200 repeated camera updates with an upright horizon. Framing tests include views above and below the Table, and project the actual SceneKit camera to verify that floating controls cannot cover fitted bounds in perspective or orthographic views.

Native mouse validation and measured results are recorded in [validation notes](validation.md).
