# FORM 0.1 implementation

This build follows the product brief and the October 24 interface sketches: one continuous Table, a compact native title bar, contextual floating inspectors, camera/focus/isolation controls, and a home screen of actual saved scene previews.

The deliberate change to the original brief is agent delivery. **Codex is the creative collaborator. FORM makes no external model or AI API calls.** Its local MCP server exposes the same domain operations used by the native interface. An embedded agent interface can later use those operations without introducing a second editing system.

## Modules

| Module | Responsibility |
| --- | --- |
| `FormCore` | Codable product graph, dimensions, parameter schemas, materials, artwork, recipes, arithmetic expressions, persistence, undo/redo, atomic edits, MCP discovery and protocol, local transport |
| `FormGraphics` | Core Text shaping/font discovery, Bézier geometry, shared native artwork drawing, shaped outlines, editable SVG parsing/import, physical SVG output, bounded text/image caches |
| `FormApp` | SwiftUI shell, AppKit pointer and artwork interaction, Metal-backed SceneKit renderer, contextual controls, previews, studio, native file panels, PDF/SVG/PNG exports |
| `FormMCP` | MCP over stdio; forwards tool calls to the running app over a user-owned Unix socket |

No third-party Swift packages, model credentials, cloud services, or CAD licenses are required. Optional slicing uses a separately installed official OrcaSlicer app; optional P1S status uses the local network.

## The rendering boundary

The initial renderer uses **SceneKit backed by Metal**, rather than the brief's proposed RealityKit starting point. SceneKit provides native macOS hit testing, procedural geometry, demand-driven drawing, camera projection, and offscreen rendering in one small implementation. It is isolated from the product model; no SceneKit types enter `FormCore`. SceneKit is deprecated in current Apple SDKs, so a future RealityKit or custom Metal renderer remains a planned replacement, not a dependency of the file format or automation interface.

Physical dimensions and placement are stored in millimeters. Rendering converts 100 mm to one scene unit. Camera state, workspace placement, recipe parameters, and artwork are separate values.

The renderer updates an object only when its geometry, material, or artwork fingerprint changes. Moving an object updates its transform. Shared node templates reuse immutable geometry and texture data; caches have bounded costs. The view targets 60 Hz while interacting and does not render continuously while idle. Paper stacks cap the number of represented sheet edges independently of the real sheet count.

## Parametric objects

Built-in constructions include clocks, paper stacks, booklets, scored folding sleeves, lamps, hollow revolved vessels, boxes, cylinders, extruded polygon profiles, material swatches, artwork sheets, and image references.

Custom project recipes consist of parameter schemas and primitive parts. Part dimensions, placement, and rotation use a bounded arithmetic grammar with parameter variables, parentheses, and `+ - * /`. No expression executes Swift, JavaScript, shell commands, or Foundation predicate code. The same schema generates the native inspector and validates MCP edits.

Iterations have independent design identities. Linked variants share parameter and artwork edits, with local material and placement choices. Group membership controls joint selection and movement. Edits are undoable across native and MCP interactions; undo history is session-local. The saved activity history persists across launches.

## Documents and Studio Library

By default, the library lives in `~/Library/Application Support/FORM`. Each project is a Finder package:

```text
<project-id>.form/
  Manifest.json
  Objects/<object-id>-<content-hash>.json
  Assets/<asset-id>.<extension>
  Preview.png
  Exports/
```

Object revisions are immutable. Saving writes changed resources before atomically publishing the manifest. Unchanged objects are not rewritten. Older object revisions remain in the package; garbage collection and durable cross-session undo are future work. Imported references are copied into `Assets`, so reopening does not depend on the original Downloads file. The shared `Studio.json` stores materials, equipment, filament inventory, printer metadata, and an optional Orca path. Printer codes stay in Keychain. Custom material definitions are also carried in projects.

Extended vector/typography artwork requires schema 2, recorded in the manifest and project. Schema-1 documents load with optional-field defaults; a schema-1-only reader rejects schema 2. Canvas settings, guide placement, names, locks, and hidden editable sources are excluded from physical artwork signatures, avoiding unnecessary 3D texture invalidation.

Independent source links and physical artwork boundaries require schema 3; schema 1 and 2 still load. A product face references a same-project artwork sheet and a physical fitting mode. Source edits update its immutable object resource while consumers retain their existing object files. The graph validates references and rejects cycles/dangling links. Detachment, independent iterations, and source deletion bake the current resolved appearance. See [shared artwork](linked-artwork.md).

Import provenance, transparent frame/fill/gradient-stop appearance, gradient affine maps, and dash phase require schema 4. Readers retain schemas 1–3. SVG conversion produces ordinary native artwork; original source bytes and embedded images are copied to the package. Provenance is excluded from render signatures. See [SVG import](svg-import.md) for supported features and limits.

`FORM_LIBRARY_PATH` selects a separate library for development or tests. `FORM_SOCKET_PATH` selects a separate local bridge. These settings require no change to a project document.

## Artwork and production

Artwork is a validated hierarchy of text, vector shapes/paths, groups, masks, and imported images in millimeter coordinates. Affine transforms preserve nested group geometry. The AppKit canvas uses a magnifying scroll view, physical rulers/guides, direct handles, and native rich text. Core Text shapes in typographic points; rendering and outlines convert at the millimeter boundary. Shared font-metric decoration paths keep underlines and strikethroughs consistent between text and outlines. Cached text layouts exclude placement from their keys; image and geometry caches account for actual bitmap dimensions.

Native character undo remains granular while editing. The domain engine groups the complete editing session into one step and removes cancelled/no-op interactions while preserving a prior redo branch. Project switches commit active text and numeric/name drafts before saving the old project. Agent mutations use the same boundary; inspection calls preserve editing focus.

The sleeve recipe derives its assembled geometry and unfolded cut/score layout from the same width, height, spine, stock, tab, and fold parameters. PDF exports preserve physical page dimensions and include bleed/crop marks. SVG dielines preserve millimeter units and distinguish cut lines from scores. PNG renders are 3000 × 2000. Component summaries are JSON.

The expanded [2D specification](2d-design-typography-vector-spec.md) remains governing scope. The [editor guide](2d-editor.md) records working controls and material gaps, including non-destructive boolean groups, advanced typography, full SVG fidelity, publication, color management, and physical integration. General solid booleans, arbitrary CAD import, advanced manufacturing tolerances, collaboration, and photorealistic path tracing are also unfinished.

Native inline text uses the complete artwork affine map through AppKit coordinate transforms, including rotation, scale, shear, and reflection. A signed SVD and explicit reversal of prior coordinate operations keep native input and pointer geometry aligned during updates. Exact Bézier subdivision, contour split/join/reversal, node modes, and physical node transforms live in `FormCore.PathCommands`; the native direct-selection UI and `form_edit_path` call the same implementation. Document-level compound creation/release and multi-path endpoint/node edits use validated candidates and commit atomically. Shape-to-path conversion preserves native appearance and retains hidden parametric sources. See [path editing](path-editing.md).

Clock numerals and indices are ordinary editable artwork. A physical circular boundary clips the source on the dial and in production artwork exports. Render signatures omit hand-time/visibility parameters; existing pivots update independently. The beveled dial and bore use a bounded radial mesh, and lathed surfaces carry texture coordinates for material rendering.

## Local slicing and printer status

The native Print sheet extracts selected construction meshes into millimeter Z-up STL geometry. It supports component selection, a separate print transform, bed validation, physical filament profiles, and per-object saved setup. An asynchronous process adapter runs official OrcaSlicer 2.4.2 with resolved BBL presets and per-job settings/data. Successful jobs retain STL, G-code, sliced 3MF, estimates, a bounded layer preview, and logs inside the project.

The Bambu adapter uses Network.framework TLS and a deliberately read-only MQTT codec. It can authenticate, subscribe to device reports, acknowledge messages, and maintain the connection. It cannot publish commands, transfer files, heat, move, calibrate, or start prints. Certificate trust uses the official CA and serial, or a user-verified certificate pin. Live hardware verification awaits the printer details. See [printing architecture and research](printing.md).

## Automation

The app serializes native and MCP edits on the main actor. The stdio executable handles MCP discovery even when the app is closed; editing tools return a clear instruction to open FORM. A local Unix socket is restricted to the owning user, checks peer identity, and does not bind a network port. Notifications produce no stdio response, and stdout contains only JSON-RPC messages.

Batch edits validate and commit as one undo step; a failed member rolls the whole batch back. Camera tools, project state, recipes, materials, artwork, decisions, and exports are available to an agent. A project can preserve a Codex conversation reference without storing credentials or introducing a second conversation service.
