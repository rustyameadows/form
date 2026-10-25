# Camera controls

This is FORM’s fixed 3D navigation contract. It replaces the earlier direction settings and modifier aliases.

| Input | Result |
| --- | --- |
| Left drag in Orbit mode | Turn the scene with the pointer: right follows right; down follows down. |
| Shift + left drag in Orbit mode | Pan the entire view in screen space, without rotating. |
| Scroll / pinch | Zoom while retaining the current orientation and orbit pivot. |
| Click / Shift-click | Select / extend the selection. |
| Focus / `F` | Frame the selection and place its center at the orbit pivot. |
| Fit all / `⌘0` | Frame the visible collection; in isolation this frames the isolated collection. |
| Perspective / `1` | Reset the perspective orientation, leave isolation, and frame the whole project. |
| Top / `2` | Reset to exact overhead orthographic view, leave isolation, and frame the whole project. |
| Front / `3` | Reset to exact front orthographic view, leave isolation, and frame the whole project. |
| Orbit / `O` | Return to camera navigation. |
| Move / `V` | Drag objects to place them; Shift snaps placement to 10 mm. |
| Isolate / `I`, Escape | Isolate the selection; Escape returns to the collection. |

There is one pan gesture. Space, Option, middle-drag, and right-drag do not provide additional navigation schemes. The 2D artwork editor has its own editing controls; this contract covers its 3D object inset as well as the Table, Studio, and print preview.

## Orbit and recovery

The camera rotates about its local axes with a persistent normalized quaternion. Both directions can continue through any number of complete rotations. There is no vertical-angle stop, pole snap, or world-up flip. Dragging back along the same path reverses the rotation, including diagonals. Passing over a pole carries the orientation continuously through the inverted view; a named view restores a canonical upright orientation.

Pan uses the same actual camera right/up basis as rendering and framing, so the scene follows the pointer even after a complete orbit. Focus and Fit preserve orientation. Named views always discard the old pan target and distance and frame all project objects, regardless of selection. Framing reserves room for floating controls without moving the subject-centered pivot. Camera changes are immediate, so a new drag cannot jump ahead of an unfinished framing animation.

A drag needs a fresh mouse-down and is cancelled when its view resizes, loses the responder, changes windows, or receives a framing command. Late mouse events cannot reuse a previous gesture’s anchor. Clicking a newly active scene accepts the first gesture. Navigation never moves object definitions or rebuilds geometry. Rendering remains demand-driven.

## Persistence and previews

Existing yaw/elevation-only project cameras retain their saved composition. The first orbit adds an optional orientation, requiring schema 16 so older readers cannot silently lose an inverted camera. Readers retain schemas 1–15. Font glyph choices independently require schema 15. Shared layout and export paths use the same camera basis. Inset camera navigation survives unrelated UI updates; changed object geometry triggers reframing.

## Validation

Core tests project actual SceneKit cameras through full rotations and inverted views, compare pointer directions, reverse motions, verify screen-space pan and physically framed bounds, and round-trip the saved orientation. Direct AppKit event tests cover mouse-down/drag/up, Shift transitions, late events, view changes, named views, Focus, and Fit. Actual computer-use input validates the packaged app. Results and limits are recorded in [validation notes](validation.md).

The orbit / Shift-pan / wheel-zoom organization follows the [Blender navigation model](https://docs.blender.org/manual/en/5.0/editors/3dview/navigate/navigation.html), with left-drag as FORM’s primary navigation input.
