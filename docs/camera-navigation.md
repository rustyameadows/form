# Camera controls

This is FORM’s fixed 3D navigation contract. It replaces the earlier direction settings and modifier aliases.

| Input | Result |
| --- | --- |
| Left drag in Orbit mode | Turn the scene with the pointer; horizontal movement changes yaw, vertical movement changes pitch. |
| Shift + left drag in Orbit mode | Pan the entire view in screen space, without rotating. |
| Scroll / pinch | Zoom while retaining the current orientation and orbit pivot. |
| Click / Shift-click | Select / extend the selection. |
| Focus / `F` | Fit and center the selection in the usable viewport around floating panels. |
| Object list / `⌘F` | Filter Table objects; click a name or press Return to select and focus it. |
| Fit all / `⌘0` | Frame the visible collection; in isolation this frames the isolated collection. |
| Perspective / `1` | Reset the perspective orientation, leave isolation, and frame the whole project. |
| Top / `2` | Reset to exact overhead orthographic view, leave isolation, and frame the whole project. |
| Front / `3` | Reset to exact front orthographic view, leave isolation, and frame the whole project. |
| Orbit / `O` | Return to camera navigation. |
| Move / `V` | Drag objects to place them; Shift snaps placement to 10 mm. |
| Isolate / `I`, Escape | Isolate the selection; Escape returns to the collection. |

There is one pan gesture. Space, Option, middle-drag, and right-drag do not provide additional navigation schemes. The 2D artwork editor has its own editing controls; this contract covers its 3D object inset as well as the Table, Studio, and print preview.

## Orbit and recovery

The default is a constrained, world-up turntable. Horizontal drags rotate indefinitely around the fixed vertical axis and cannot change pitch or bank the view. Vertical drags change pitch only. Diagonal drags combine those independent changes; small pointer noise is not suppressed by an invented axis lock or deadband, and it cannot accumulate roll.

Pitch ends at exact Top and Bottom (±90°). These are FORM’s explicit upright-view endpoints, rather than a claim about Fusion’s exact numeric limits. Reversing the mouse responds immediately. This replaces the earlier free-orbit behavior: unlimited vertical somersaults were allowing the tilted local axes that made ordinary scene exploration difficult. Horizontal orbit remains unlimited.

Earlier saved free-orbit quaternions retain their look direction, pivot, and zoom while rendering with a level world-up frame. No manual leveling step is needed. Named views continue to recover canonical directions and frame the whole project.

Pan uses the same level camera right/up basis as rendering and framing, so the scene follows the pointer without rotating. Focus and Fit preserve orientation. Named views always discard the old pan target and distance and frame all project objects, regardless of selection. On the Table, framing measures the floating navigator, inspector and toolbar, chooses an unobstructed area that gives the subject the largest useful size, then pans and zooms the camera to center it there. This optical target persists like a manual pan; the next orbit retains it. Resizing a viewport or closing a panel preserves the current pose until another explicit framing action. Camera changes are immediate, so a new drag cannot jump ahead of an unfinished framing animation.

A drag needs a fresh mouse-down and is cancelled when its view resizes, loses the responder, changes windows, or receives a framing command. Late mouse events cannot reuse a previous gesture’s anchor. Clicking a newly active scene accepts the first gesture. Navigation never moves object definitions or rebuilds geometry. Rendering remains demand-driven.

## Persistence and previews

Existing yaw/elevation-only project cameras retain their saved composition. The first orbit adds an optional orientation, requiring schema 16 so older readers cannot silently lose an inverted camera. Readers retain schemas 1–15. Font glyph choices independently require schema 15. Shared layout and export paths use the same camera basis. Inset camera navigation survives unrelated UI updates; changed object geometry triggers reframing.

## Validation

Core tests project actual SceneKit cameras through unlimited horizontal rotations and Top/Bottom endpoints, verify independent yaw/pitch and a level projected horizon across 2,000 noisy drags, compare pointer directions, reverse motions, verify screen-space pan/framing, and reopen earlier banked orientations. Direct AppKit event tests cover mouse-down/drag/up, Shift transitions, late events, view changes, named views, Focus, and Fit. Actual computer-use input validates the packaged app. Results and limits are recorded in [validation notes](validation.md).

The orbit / Shift-pan / wheel-zoom organization follows the [Blender navigation model](https://docs.blender.org/manual/en/5.0/editors/3dview/navigate/navigation.html), with left-drag as FORM’s primary navigation input.
