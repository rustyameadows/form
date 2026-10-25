# FORM 0.1 implementation

This build follows the product brief and the October 24 interface sketches: one continuous Table, a compact native title bar, contextual floating inspectors, camera/focus/isolation controls, and a home screen of actual saved scene previews.

The deliberate change to the original brief is agent delivery. **Codex is the creative collaborator. FORM makes no external model or AI API calls.** Its local MCP server exposes the same domain operations used by the native interface. An embedded agent interface can later use those operations without introducing a second editing system.

## Modules

| Module | Responsibility |
| --- | --- |
| `FormCore` | Codable product graph, dimensions, parameter schemas, materials, artwork, recipes, arithmetic expressions, persistence, undo/redo, atomic edits, MCP discovery and protocol, local transport |
| `FormGraphics` | Core Text shaping/font discovery, Bézier and cached live-boolean geometry, shared native artwork drawing, shaped outlines, editable SVG parsing/import, physical SVG output, bounded caches |
| `FormApp` | SwiftUI shell, AppKit pointer and artwork interaction, Metal-backed SceneKit renderer, contextual controls, previews, studio, native file panels, PDF/SVG/PNG exports |
| `FormMCP` | MCP over stdio; forwards tool calls to the running app over a user-owned Unix socket |

No third-party Swift packages, model credentials, cloud services, or CAD licenses are required. Optional slicing uses a separately installed official OrcaSlicer app; optional P1S status uses the local network.

## The rendering boundary

The initial renderer uses **SceneKit backed by Metal**, rather than the brief's proposed RealityKit starting point. SceneKit provides native macOS hit testing, procedural geometry, demand-driven drawing, camera projection, and offscreen rendering in one small implementation. It is isolated from the product model; no SceneKit types enter `FormCore`. SceneKit is deprecated in current Apple SDKs, so a future RealityKit or custom Metal renderer remains a planned replacement, not a dependency of the file format or automation interface.

Physical dimensions and placement are stored in millimeters. Rendering converts 100 mm to one scene unit. Camera state, workspace placement, recipe parameters, and artwork are separate values.

Local camera navigation preferences live in UserDefaults, outside the project and its undo history. `CameraPreferences` defines orbit direction, bounded speed, and wheel reversal. Table and Studio controllers read the store directly; artwork and print preview cameras read the same live preferences through a closure without owning or changing the document camera. Mouse navigation updates camera transforms without rebuilding object geometry.

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

Live boolean groups require schema 5; schemas 1–4 still load. The document stores operations and editable operands. `FormCore.BooleanCommands` creates and validates the hierarchy; `FormGraphics.BooleanGeometry` resolves paths for the native canvas, linked faces, and all exports. Its bounded 64 MB cache excludes paint, names, locks, and root placement while tracking operand geometry, order, visibility, hierarchy, transforms, and clips. Flattening retains a hidden live source; Divide emits individual regions. Creation, flattening, division, and release preserve the result's stack position relative to unrelated siblings. See [live booleans](live-booleans.md).

Reusable vector components require schema 6; schemas 1–5 still load. Independent artwork frames hold editable source definitions; empty instance groups store a source reference, placement/size, and selected overrides. Resolution derives ordinary nested artwork with stable per-instance IDs before the canvas, surface signatures, and exports consume it. A bounded 64 MB cache keys each artwork and its reachable source graph, preserving source-only immutable resource updates. Validation rejects cycles and excessive expansion; source deletion bakes affected instances before removing the definition. Detachment retains ordinary editable text, geometry, masks, live booleans, and current overrides. See [components](reusable-components.md).

Named project palettes and paint references require schema 7; schemas 1–6 still load. Swatches store explicit sRGB values in the manifest. Optional IDs on fills, strokes, gradient stops, text spans, backgrounds, and component overrides resolve before component expansion, native drawing, physical texture signatures, and exports. Editing a swatch alone leaves every object resource unchanged. Component caches depend on reachable resolved colors, so an unused palette edit does not rebuild them. Deletion bakes only the removed color's references, including hidden/locked artwork, and Undo restores the links. Native attributed text carries swatch identity through selected-character formatting and shaped glyph outlines; component and physical-face detachment retain palette links. See [shared colors](shared-swatches.md).

Editable opacity, blend/isolation settings, blur, and shadows require schema 8; schemas 1–7 still load. Shared shadow colors resolve with other palette references. The renderer applies complete-layer opacity once, passes ordinary group blending through, and isolates groups with effects/opacity or explicit isolation. A 64 MB Core Image cache reuses source pixels across placements; actual affine scale determines preview density, with per-layer allocation limits. SVG preserves live filters/compositing; PDF rasterizes only filtered layers at the requested DPI. Production raster/PDF output rejects effects exceeding those limits at the requested resolution. See [appearance](artwork-appearance.md).

Image crop/adjustment fields require schema 9; schemas 1–8 still load. ImageIO provides oriented pixel metadata and bounded thumbnail decoding; a separate 64 MB cache reuses bitmap content across placements. Crop remains a normalized window into the original file. A shared saturation/contrast/brightness matrix drives Core Image and live SVG filters. Effective DPI uses the complete resolved physical transform, including shear and component/surface fitting. Native file drops, disk placement/replacement, original-asset reuse, and three MCP tools share the same import/edit boundary. Original bytes remain in the package; invalid imports validate before adding an asset. See [image editing](image-editing.md).

`FORM_LIBRARY_PATH` selects a separate library for development or tests. `FORM_SOCKET_PATH` selects a separate local bridge. These settings require no change to a project document.

## Artwork and production

Artwork is a validated hierarchy of text, vector shapes/paths, groups, masks, and imported images in millimeter coordinates. Affine transforms preserve nested group geometry. The AppKit canvas uses a magnifying scroll view, physical rulers/guides, direct handles, and native rich text. Core Text shapes in typographic points; rendering and outlines convert at the millimeter boundary. Shared font-metric decoration paths keep underlines and strikethroughs consistent between text and outlines. Cached text layouts exclude placement from their keys; image and geometry caches account for actual bitmap dimensions.

Native character undo remains granular while editing. The domain engine groups the complete editing session into one step and removes cancelled/no-op interactions while preserving a prior redo branch. Project switches commit active text and numeric/name drafts before saving the old project. Agent mutations use the same boundary; inspection calls preserve editing focus.

The sleeve recipe derives its assembled geometry and unfolded cut/score layout from the same width, height, spine, stock, tab, and fold parameters. PDF exports preserve physical page dimensions and include bleed/crop marks. SVG dielines preserve millimeter units and distinguish cut lines from scores. PNG renders are 3000 × 2000. Component summaries are JSON.

The expanded [2D specification](2d-design-typography-vector-spec.md) remains governing scope. The [editor guide](2d-editor.md) records working controls and material gaps, including advanced typography, full SVG fidelity, publication, color management, and physical integration. General solid booleans, arbitrary CAD import, advanced manufacturing tolerances, collaboration, and photorealistic path tracing are also unfinished.

Native inline text uses the complete artwork affine map through AppKit coordinate transforms, including rotation, scale, shear, and reflection. A signed SVD and explicit reversal of prior coordinate operations keep native input and pointer geometry aligned during updates. Exact Bézier subdivision, contour split/join/reversal, node modes, and physical node transforms live in `FormCore.PathCommands`; the native direct-selection UI and `form_edit_path` call the same implementation. Document-level compound creation/release and multi-path endpoint/node edits use validated candidates and commit atomically. Shape-to-path conversion preserves native appearance and retains hidden parametric sources. See [path editing](path-editing.md).

Clock numerals and indices are ordinary editable artwork. A physical circular boundary clips the source on the dial and in production artwork exports. Render signatures omit hand-time/visibility parameters; existing pivots update independently. The beveled dial and bore use a bounded radial mesh, and lathed surfaces carry texture coordinates for material rendering.

## Local slicing and printer status

The native Print sheet extracts selected construction meshes into millimeter Z-up STL geometry. It supports component selection, a separate print transform, bed validation, physical filament profiles, and per-object saved setup. An asynchronous process adapter runs official OrcaSlicer 2.4.2 with resolved BBL presets and per-job settings/data. Successful jobs retain STL, G-code, sliced 3MF, estimates, a bounded layer preview, and logs inside the project.

The Bambu adapter uses Network.framework TLS and a deliberately read-only MQTT codec. It can authenticate, subscribe to device reports, acknowledge messages, and maintain the connection. It cannot publish commands, transfer files, heat, move, calibrate, or start prints. Certificate trust uses the official CA and serial, or a user-verified certificate pin. Live hardware verification awaits the printer details. See [printing architecture and research](printing.md).

## Automation

The app serializes native and MCP edits on the main actor. The stdio executable handles MCP discovery even when the app is closed; editing tools return a clear instruction to open FORM. A local Unix socket is restricted to the owning user, checks peer identity, and does not bind a network port. Notifications produce no stdio response, and stdout contains only JSON-RPC messages.

Batch edits validate and commit as one undo step; a failed member rolls the whole batch back. Camera tools, project state, recipes, materials, artwork, decisions, and exports are available to an agent. A project can preserve a Codex conversation reference without storing credentials or introducing a second conversation service.

Vector paint uses shared `PaintCommands` and UUID-stable gradient-stop edits. `StrokeGeometry` expands centered/inside/outside strokes with a 32 MB cache cost limit and a 20,000-segment dash-expansion guard. Aligned strokes export as actual vector outlines. `ArtworkOutlines` preserves fill, appearance, layer order, and recoverable sources; mask shape conversion redirects consumers. Native mask-editing context and selected stop IDs are ephemeral session state. Explicit stroke enable/alignment fields require schema 10; older formats remain readable. See [paint, gradients, and masks](paint-gradients-masks.md).

Typography's optional `featureSelections` maps an independent feature type to several explicit on/off selectors; legacy `features` remains readable for single/exclusive choices. Ordered descriptor settings preserve independent pairs. Native attributed text retains assignment metadata when AppKit normalizes away a selector equal to the face's defaults, and respects actual native font replacement/reset. The same settings drive Core Text, glyph outlines, physical faces, and exports. Up to 256 explicit settings per typography value are permitted. Font capability discovery has a 256-face cache cleared by the existing font-change notification. These assignments require schema 11, including assignments present only in rich text spans; schemas 1–10 remain readable. See [font features](font-features.md).

Schema 12 adds project `textStyles`, text/style references, property-level override names, and separate live paragraph references for character-only applications. `TextStyleCommands` materializes inherited changes only in stored users, so ordinary typography feeds all existing renderers. Renaming a style updates metadata; style formatting rewrites only affected source objects, leaving physical and component instances intact. Colors, transforms, frame behavior, and manual pair positions remain independent. Native metadata distinguishes tracking from word/pair additions, preserves assigned font aliases, and restores the original stored element when text Undo returns to its canonical starting input. Read-only style discovery preserves active drafts; mutations commit them before editing. Successful project switches dismiss resource sheets. See [reusable text styles](reusable-text-styles.md).

Print preparation has project/object ownership separate from Studio printer/filament profiles. `OperationEngine.onProjectDidChange` fires after a successful transition; `StudioStore` dismisses the sheet and invalidates its coordinator. Each asynchronous slice completion carries a request containing project, object, and job IDs. Invalidated requests cannot publish results or clear a newer job's busy state. Geometry/settings reconciliation refreshes the mesh without rebuilding on placement or paint edits. Explicit native setting bindings persist once; Undo/Redo reads the restored per-object configuration without creating another edit. Read-only status reports ownership and presentation without preparing or switching objects.

Mesh export prepares material-free geometry copies through an offscreen SceneKit renderer before reading vertex sources, avoiding unit placeholder vertices from unprepared primitives. `FormAppTests` directly exercise coordinator transitions, owned-process termination, asynchronous-result races, Undo, and unseen primitive dimensions using injected temporary repositories; existing core/graphics tests remain separate.

Schema 13 adds optional `Typography.kerningMode` on elements, rich spans, and style definitions. Explicit metrics/none modes use separate tracking attributes; only none sets zero kerning. Manual pairs and word spacing compose without drifting into tracking metadata. Missing modes retain the previous renderer exactly. SVG text import resolves inherited font kerning, and live SVG exports explicit modes while default outlines retain Core Text glyph geometry. Native text creation starts in metrics mode; existing documents are unchanged. See [font kerning](kerning.md).

Schema 14 adds optional saved paragraph tab stops/repeating intervals and real positive hyphenation semantics, including rich spans and unused text styles. `ParagraphCommands` patches containing UTF-16 paragraphs while retaining character formatting and independent style references. `ParagraphLayout` caches TextKit storage/layout/container data (256 entries / 16 MB estimated cost); its real hyphenated glyphs drive measurement, overflow, native drawing, linked surfaces, and outlines. Placement is excluded from layout signatures. Ordinary text keeps the Core Text path. SVG uses an explicit outline fallback for tabs/hyphenation and reports its count when other text remains live. Native tab sheets retain their paragraph target after a failed agent open; successful mutations dismiss unapplied drafts. See [paragraph composition](paragraph-composition.md).

Unicode case composition uses each source span’s treatment, Foundation’s contextual casing, and original UTF-16 coordinates. `TextCase` derives source/display ranges and one shared ephemeral provenance record for native input. A single record across the buffer preserves ligatures and kerning; production rendering skips its creation and uses a uniform-formatting fast path. Native insertions and case controls preserve original source, partial expansion edits materialize only the edited character, and metadata-only normalization adds no Undo step. Marked input stays untouched until commit. No new model field/schema is introduced. See [text case and VERSO](text-case.md).

Schema 15 adds source-positioned `glyphOverrides`, separate from style inheritance. `GlyphCatalog` discovers actual font glyphs and feature-produced alternates, validates font-table signatures, and canonicalizes variable instances to the file's default face without discarding axis values. `GlyphEngine` maps source clusters through case composition and derives Core Text glyph-info attributes for shared layout, native input, physical faces, and exports. Native provenance/render attributes stay ephemeral; typing strips inherited glyph markers, attributed paste renews duplicated IDs, and marked input waits for commit. Bounded face/query/glyph-info caches invalidate on font activation. Point text with explicit choices measures ink overhangs independently of its intrinsic text container, keeping native drawing and exported outlines aligned at left/center/right. Native and MCP assignment/clear resize point text in the same Undo transaction. Production export rejects unresolved choices before writing; SVG uses portable outlines, and bitmap-only glyphs explicitly reject vector conversion. See [alternate glyphs and QUILL](glyphs.md).


Camera schema 16 adds an optional normalized quaternion while retaining legacy yaw/elevation cameras. A shared local right/up/outward basis drives orbit, pan, framing, native SceneKit transforms, and snapshots. Direct orthonormal matrices avoid SceneKit look-at basis inversions at poles. Native navigation has a single fixed direction and Shift-pan gesture; obsolete local direction settings are no longer applied. Per-gesture anchors require a fresh mouse-down and cancel on responder/window/size/project changes. Named views reset orientation, exit isolation, and fit all project geometry. Cached geometry bounds exclude selection outlines; Table and Studio panel insets preserve the same project pivot. Framing is immediate, and inset refits follow content changes rather than arbitrary SwiftUI updates.
