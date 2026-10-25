# Canvas and Table

Canvas and Table are peer design surfaces in the same FORM project. This direction was requested October 25, 2026 and is part of the active implementation goal.

The freeform 2D Canvas holds loose typography, notes, references, images, and vector experiments without requiring an artboard. Finite physical artboards and object-face regions sit within it. They provide the physical boundaries used for manufacturing/export and the links to 3D product surfaces. The Table remains the continuous 3D environment for objects, construction, materials, and physical relationships.

Moving artwork onto a mapped region makes it part of that physical source. Moving it back onto the loose canvas removes it from the product. Source text, styles, components, asset links, masks, physical coordinates, and meaningful Undo must survive those transfers. Existing shared artwork remains the source of truth; the two views must not maintain divergent copies.

Both surfaces can be used alone, together in a resizable split, or with the Canvas in its own window. A single active canvas/editor and a single Table camera avoid competing gesture ownership. Project changes, Save, Undo, and native/MCP edits act on shared state. Command focus follows the surface being edited. Closing a detached surface restores a usable main-window arrangement.

Implementation acceptance:

- Start a blank project, choose Canvas, and immediately type or draw without creating an artboard.
- Pan through and place content outside finite frames, including negative coordinates; the working area expands with content.
- Create and position a physical artboard, link it to a product, and drag typography onto it. The 3D face updates immediately; one Undo restores both source and destination.
- Move artwork back out while preserving its appearance and all named resources.
- Use Canvas, Table, Split, and a separate Canvas window without losing native text input, camera state, focus, or project ownership.
- Save/reopen and validate the same operations through deterministic MCP commands.
- Keep frame/selection exports physically bounded and camera/viewport changes outside geometry rebuilds.

This document records required behavior. Shipping evidence belongs in validation.md; unfinished requirements must remain visible in implementation-goal.md.
