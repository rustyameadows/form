# Native Figma paste: implementation, boundaries and verification

Updated 2026-10-31. Branch: `codex/figma-paste-foundations`. Base: `31f1e16`.

## Implemented route

**Ordinary Copy in Figma → Paste in LAB → native editable artwork.** The native route reads the Figma HTML/binary clipboard representation directly. It does not import SVG, convert text to permanent outlines, embed a screenshot, contact Figma, or require a plugin/account/export command. A separate adapter handles explicitly supplied SVG using the same insertion transaction.

The branch contains the decoder, scene mapper, generic paint/effect/mask model extensions, renderer integration and Canvas Paste transaction. Verification is still in progress. Public source inspection and independently generated payloads establish implementation behavior; they do **not** establish interoperability with the current Figma producer. No Figma app, account, human clipboard or real Figma design has been accessed in this round. That validation remains deferred at the user's request.

“Native” describes LAB's resulting objects: selectable layers, editable hierarchy and paths, live text, local image assets, transforms, paint/effect settings and ordinary editing/Undo. It does not imply that every Figma constraint, variable, component relationship or typography metric becomes a live LAB behavior. Temporary glyph paths and raster coverage used by renderers do not replace the editable document source.

## Architecture and transaction

| Stage | Implementation and behavior |
| --- | --- |
| Explicit Paste | `ArtworkSession` prefers LAB's native transfer representation, then a recognized Figma HTML envelope, then supported SVG representations. The native text responder continues to own ordinary text paste. A corrupt preferred representation fails rather than silently choosing a lower-fidelity one. |
| Decode | `FigmaClipboardDecoder` reads inert `(figmeta)` and `(figma)` Base64 markers, `fig-kiwi` framing and length-prefixed chunks. Raw Deflate and Zstandard are decoded locally. `FigmaClipboardKiwi` interprets the embedded schema as bounded data; no generated JavaScript or payload code executes. |
| Source values | `FigmaValue` retains signed/unsigned integer identities without a floating-point round trip, binary blobs, strings and schema enum names. A positive container version is retained; there is no claim that every positive version has supported semantics. |
| Native mapping | `FigmaArtworkImporter` and its scene, geometry, paint, image, typography and instance helpers produce native `Artwork`, selected roots, local assets, component definitions and per-node issues. Native Figma parsing/mapping runs off the main actor with cancellation. |
| Preflight and commit | `ArtworkTransferBundle` and the existing transfer engine validate graph/resource closure, preflight assets, stage bytes, revalidate the destination lifetime/scope, finish current editing, replan and commit once. Placement centers copied bounds in the visible destination, respecting group/projection transforms. Camera and group scope stay fixed. |
| Results | Successful paste selects the imported roots and creates one Undo step. The inspector exposes import notes. Blocking errors abort before document insertion. New paste, project lifetime, destination or scope changes invalidate pending work. |

Relevant source: [Canvas adapter](../Sources/FormApp/ArtworkExternalPaste.swift), [transfer operations](../Sources/FormApp/ArtworkTransferOperations.swift), [decoder](../Sources/FormCore/FigmaClipboardDecoder.swift), [Kiwi interpreter](../Sources/FormCore/FigmaClipboardKiwi.swift), [mapper](../Sources/FormGraphics/FigmaArtworkImporter.swift), [transfer plan](../Sources/FormCore/ArtworkTransferPlan.swift).

## Native representation and fidelity boundaries

| Area | Implemented mapping | Boundary that still matters |
| --- | --- | --- |
| Hierarchy and placement | Ordered groups/frames, affine transforms, reflections/shears, clipping frames, hidden/locked state and source identities. Internal support canvases become resources, not extra visible pasted pages. | Auto-layout is a copied layout snapshot. Responsive constraints are not retained as future LAB behavior. Degenerate source dimensions use the native minimum extent rather than zero-sized layers. |
| Geometry | Supplied path commands and vector networks, winding/holes, rectangles, independent circular corner radii, ellipses/arcs, polygons, stars, lines and compatible live booleans. | Supplied outline geometry can remain editable paths. Smoothed corners without supplied paths produce an approximation note. Unsupported node/geometry semantics block import. Soft-masked boolean operands cannot be geometrically flattened; keep the mask on an enclosing result. |
| Paints and strokes | Ordered native paints or ordered editable paint sublayers; solid, linear/radial/angular/diamond gradient and embedded image inks; stroke alignment, joins, caps and dashes where mapped. Gradient transforms and image crop/fit/fill/stretch/tile placement remain editable. | Independent side stroke widths, decorative caps without appropriate geometry and unknown paint/blend enums are blocking cases. Multiple source paints may introduce more LAB layers than source nodes. Compatible boolean results retain their ordered fill/stroke paint stacks. |
| Live text | Characters and UTF-16 style ranges; font family/style/weight assignment, size, alignment, line height, letter spacing, paragraph spacing/indent/direction, supported decoration/case, axes and OpenType features. Base and per-range gradient/image/fill/stroke paint stacks remain live. | LAB reshapes with local fonts. Missing fonts preserve the assignment and show fallback diagnostics. Exact source baselines/wrapping are not guaranteed. Auto-height keeps copied frame size; lists, truncation/max-lines, cap trimming, some decorations/features and future enum values retain metadata and emit notes where not mapped. |
| Text editing | Font/word edits retain imported paints. Recoloring a selected range or whole text updates the effective native fill instead of leaving it hidden beneath imported paints. Linked frames resolve shared-story paints transiently, including new rich ranges after reflow. | Bitmap-only/color-font glyphs can use live raster coverage. Vector output explicitly rejects paint/stroke combinations that require unavailable glyph outlines rather than silently dropping them. |
| Appearance editing | Native inspector rows edit/reorder/disable/add/remove paint and effect stacks, gradient stops and geometry, image placement, stroke geometry, opacity and blending. Stacked layers use these controls rather than ineffective legacy fill/stroke fields. | Base text paints and explicitly styled character paints remain distinct. Editing an individual linked frame cannot replace its shared story's source accidentally. |
| Masks | Editable alpha and luminance mask subtrees, including text/images/groups. Following siblings are clipped as one content group. Consecutive masks form source-over coverage; masks are not displayed as ordinary layers. Coverage-based picking follows transparent holes and mask transforms. | Generic `outline` remains a geometric vector clip. Figma vector masks use opaque visible fill/stroke coverage on supported leaf shapes; group/image/text vector-mask cases are explicitly unsupported. Figma luminance currently maps to an explicit `luminance-alpha` mode based on the pinned implementation's extra alpha multiplication; real producer comparison remains necessary. |
| Effects | Generic ordered drop/inner shadows and layer blur, independent shadow blends, knockout coverage, supported analytic spread, node opacity and authored isolation. Live content remains live unless layer blur requires compositing. | Figma radius-to-sigma and silhouette rules follow inspected compatibility code, not an official pixel-fidelity guarantee. Unsupported background/progressive blur, multiple layer blurs, some spread/shape combinations and unknown effects block import. |
| Components | Compatible definitions/instances use native LAB components. Complex nested overrides, swaps and copied derived geometry can be resolved to editable occurrence layers; supported freeform resize constraints are applied during this resolution. | Materialized occurrences are not linked components. Variant switching, variable bindings and responsive auto-layout are not recreated. Missing definitions, ambiguous override paths and resized auto-layout without resolved layout data are blocking cases. |
| Images and colors | Embedded local image bytes are content addressed; normalized placement and orientation are retained. Declared sRGB/Display P3 colors convert to LAB's native sRGB representation. | Missing image bytes block import; private image endpoints are never fetched. Nonzero source image adjustments need calibrated mapping and currently block. Legacy/unspecified color interpretation and font substitutions are reported; this is not a guarantee of identical source color management. |
| Output | Raster/PDF rendering uses native source plus transient coverage/effects. SVG exports editable vector content where available and embeds calculated raster mask/effect coverage where necessary. | Native import does not imply wholly vector export. Strict output validation rejects unsupported glyph outlines or excessive output resolution. Export appearance needs its own comparisons, including transparency, soft masks and non-normal blend backdrops. |

Source dimensions use **1 CSS pixel = 25.4/96 mm**; typography converts **1 pixel = 0.75 point** before authored transforms. Source settings are retained even when LAB exposes a resolved or static representation. Warnings/notes can permit import with a disclosed difference; errors prevent the entire native paste. Retaining source metadata is not a substitute for rendering a feature.

The generic paint-stack inspector edits active paint layers rather than ignored legacy stroke/gradient fields. The shared `paint_stack` command replaces the base stack atomically, preserves explicit rich-span overrides and rejects legacy edits that would have no visible effect. Shared story paint changes belong to the story source; linked frame placeholders cannot override it. Per-layer palette color copies are explicitly detached; existing whole-fill palette bindings remain linked.

The new generic native data is schema 58: per-layer source metadata, paint stacks, ordered effect stacks and coverage clip modes. These are reusable LAB features, not opaque Figma-only render objects. Mask dependency validation includes both child and clip edges; transfer includes complete referenced mask subtrees and their assets. Native ungroup cannot discard a combined clipping appearance.

Coverage-mask editing can enter nested mask groups, select zero-alpha ink to restore it, and edit the mask's paint, opacity and effects. Escape/Leave ascends through that editing scope, then returns to the masked content. Geometric outline clips retain their geometry-only policy. Ordinary project data stays hidden/locked as authored outside the active mask-edit scope.

## Provenance and partial copy

The originating project retains the inert original clipboard envelope as a `.figma` source asset and bounded per-node tagged JSON metadata. Original bytes are not executed or fetched. Source records associate with represented element IDs, and normal resource closure includes images referenced by text/shape paint stacks and mask descendants.

Copying only A from an original containing A+B omits a shared opaque original that also contains B. It retains A's required native graph/assets and appropriately scoped per-node metadata; incomplete ancestor shells lose opaque metadata that could expose unselected descendants. Complete copy, duplicate, save/reopen and Undo/Redo preserve their applicable provenance and resources. Source metadata is never silently reapplied over subsequent native edits.

See [source metadata](../Sources/FormCore/ArtworkSourceMetadata.swift), [capture closure](../Sources/FormCore/ArtworkTransferGraph.swift), [resource validation](../Sources/FormCore/ArtworkTransferBundle.swift), [generic paint resources](../Sources/FormCore/ArtworkPaintValidation.swift).

## Enforced limits

Limits apply at distinct stages; the most restrictive applicable stage wins. A decoder accepting bytes does not mean the resulting scene can be committed. No layer truncation is used to fit the limits.

| Stage | Current default limits |
| --- | --- |
| Canvas representations | Figma HTML/text snapshot: 16 MiB. Explicit SVG: 10,000,000 bytes. |
| Decoder API | HTML input 48 MiB; compressed container 32 MiB; schema 4 MiB; decompressed message 64 MiB; metadata 64 KiB; at most 16 chunks. Canvas uses the smaller snapshot cap above. |
| Schema/value interpretation | 2,048 definitions; 32,768 fields; 250,000 elements per array; 1,000,000 values; depth 128; 4,000,000 work units. Individual strings 8 MiB and total strings 16 MiB. |
| Scene and transfer | 5,000 source records and 5,000 expanded native elements including transferred definitions; 64 hierarchy levels; 200,000 mapped vector nodes; transfer graph work 1,000,000. Component definitions: 128, with native component-reference depth 8. |
| Source metadata | 256 KiB per layer; 8 MiB aggregate artwork source metadata; transfer metadata 16 MiB. |
| Local assets | 128 assets; 16 MiB per asset; 64 MiB total. Decoded raster cap 8,192 pixels per edge, 16 megapixels per frame and 32 megapixels total. Source archives count toward asset limits. |
| Typography | Mapping is bounded at 200,000 UTF-16 units, 4,096 style records and 8,192 generated style ranges. Normal native artwork/transfer validation additionally caps a text element at 10,000 Swift characters. |
| Native appearance | Up to 16 paint layers per stack and 16 effects per layer. Mask preview coverage is bounded to 8,192 pixels/edge and 16 megapixels per raster, with a 64 MB cache. Effects divide a 32-million-working-pixel budget among capture/intermediate/output layers. Nested mask/effect captures additionally share 128,000,000 reserved bytes and a depth limit of 16. Strict export checks requested resolution instead of silently reducing it. |

Decoder cancellation is checked during marker scans, decompression, schema/value interpretation and scene conversion. Renderer captures also check cancellation. Shared in-flight capture reservations bound recursively retained mask/effect buffers. A nested failure invalidates the outer capture and prevents caching a partial result; strict output exercises both render paths and rejects failure. These reservations cover accounted capture buffers, not all process memory, renderer caches or operating-system allocations. Central verification of the new nested-budget regressions remains pending.

Sources of truth: [decoder limits](../Sources/FormCore/FigmaClipboardValue.swift), [transfer limits](../Sources/FormCore/ArtworkTransferBundle.swift), [image preflight](../Sources/FormGraphics/ArtworkTransferPreflight.swift), [mask coverage](../Sources/FormGraphics/ArtworkMaskRenderer.swift), [effect rasterizer](../Sources/FormGraphics/EffectStackRenderer.swift), [shared capture budget](../Sources/FormGraphics/ArtworkRasterBudget.swift).

## Evidence and compatibility maintenance

Figma documents **Copy as SVG** as a separate interchange command. Ordinary Copy's binary-in-HTML mechanism is described in Figma's historical engineering material, but that article is not a current public clipboard specification. Kiwi serialization is explicitly described as an internal detail subject to change. [Copy between design tools](https://help.figma.com/hc/en-us/articles/360040030374-Copy-assets-between-design-tools), [Figma engineering](https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/), [Evan Wallace on Figma internals](https://madebyevan.com/figma/).

The implementation was compared against primary code at pinned revisions:

- **Canonical Kiwi** `fe3ca9484ac055ccd39fe144218ec11f720222ae`: wire primitives, schema format, structs/messages, null-terminated UTF-8 strings and Kiwi float encoding. LAB's interpreter does not evaluate generated code. [Repository](https://github.com/evanw/kiwi/tree/fe3ca9484ac055ccd39fe144218ec11f720222ae).
- **OpenPencil** `e9aa2b0b569e0219c898166ba67a2f65fe5cfc87`: native envelope/container, embedded schema, text/paint/mask/component semantics. [Clipboard reader](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/fig/src/clipboard/import.ts), [container](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/src/fig/container.ts), [schema interpreter](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/src/schema-runtime/interpreter.ts), [mask renderer](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/core/src/canvas/masks.ts).
- **Grida** `9cbacacc89517971aec37d3de1c82202fb4d7986`: independent envelope/schema implementation and geometry/blob structures. The parser decodes chunk zero's schema despite prose elsewhere suggesting clipboard payloads lack one. [Parser](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/packages/grida-canvas-io-figma/fig-kiwi/index.ts), [blob parser](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/packages/grida-canvas-io-figma/fig-kiwi/blob-parser.ts), [support-canvas fixture notes](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/fixtures/test-fig/clipboard/README.md).
- **Sketch fig2sketch** `450e3b350a6f9cf05d659459cf240def6b7f0483`: independent container/compression reference. Codec framing is inspected; the version number alone is not treated as a codec selector. [Decoder](https://github.com/sketch-hq/fig2sketch/blob/450e3b350a6f9cf05d659459cf240def6b7f0483/src/figformat/kiwi.py).

These are reverse-engineered compatibility sources, not promises from Figma. OpenPencil's missing-image resolver uses a private endpoint; its existence does not establish reliable anonymous access, and LAB does not use it. [Embedding](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/fig/src/clipboard/images.ts), [resolver](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/src/app/editor/clipboard/figma-images.ts).

Canonical Kiwi, OpenPencil and Sketch's converter are MIT licensed; Grida's root license is Apache 2.0. LAB carries reference acknowledgments and a pinned Zstandard 1.5.7 decompressor's BSD license/provenance. No third-party design fixture was adopted; test wire payloads are independently generated. Changes to the pinned references, bundled decompressor or compatibility semantics need review and regression fixtures. See [packaged notices](../Resources/ThirdPartyNotices/FigmaClipboardReferences.txt), [Zstandard provenance](../Sources/CFormFigmaCompression/UPSTREAM.json), [OpenPencil license](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/LICENSE), [Grida license](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/LICENSE), [Sketch license](https://github.com/sketch-hq/fig2sketch/blob/450e3b350a6f9cf05d659459cf240def6b7f0483/LICENSE).

Authenticated REST file/node/image endpoints and a user-invoked plugin exporter remain possible future routes. `JSON_REST_V1`, `SVG_STRING` and `Image.getBytesAsync()` are documented plugin options, but they require a Figma execution context; REST requires appropriate authorization. Neither is used by native clipboard paste. SVG export may outline text or approximate strokes and is not an equivalent route for full native text/components. [Plugin export settings](https://developers.figma.com/docs/plugins/api/ExportSettings/), [Image API](https://developers.figma.com/docs/plugins/api/Image/), [REST file endpoints](https://developers.figma.com/docs/rest-api/file-endpoints/).

## Current verification record

**In progress. Do not infer an installed/verified candidate from this document.** Root will update this section after the central compile/test loop and candidate verification:

- Final source revision: **pending**.
- Central test command/log and passed/failed counts: **pending**.
- Release build/signature verification: **pending**.
- Installed app path and executable SHA-256: **pending**.
- Native UI exercise and remaining known failures: **pending**.
- Real Figma producer interoperability: **not tested; deliberately deferred**.

Tests on the branch cover these contracts; their existence is not a passing result:

- [Wire/schema decoder](../Tests/FormCoreTests/FigmaClipboardDecoderTests.swift): independent binary primitives/fixtures, codecs, malformed framing/schema, indices, recursion/count limits and cancellation.
- [Scene mapping](../Tests/FormCoreTests/FigmaArtworkImportTests.swift), [instances](../Tests/FormCoreTests/FigmaInstanceImportTests.swift), [native typography](../Tests/FormCoreTests/FigmaTypographyTests.swift), [text paints](../Tests/FormCoreTests/FigmaTextPaintImportTests.swift), [mask mapping](../Tests/FormCoreTests/FigmaMaskImportTests.swift), [effect mapping](../Tests/FormCoreTests/FigmaEffectImportTests.swift).
- [Mask pixels/transfer/picking](../Tests/FormCoreTests/ArtworkMaskTests.swift): 50% coverage applied once to overlapping siblings, alpha/luminance orientation, native image/text/gradient sources, transformed holes, hidden-source cache invalidation, boolean masks, graph cycles and full mask-subtree resource closure.
- [Native effects integration](../Tests/FormCoreTests/NativeAppearanceIntegrationTests.swift), [text rendering](../Tests/FormCoreTests/NativeTextPaintTests.swift), [text editing](../Tests/FormAppTests/NativeTextPaintEditingTests.swift), [shared-story paint/reflow](../Tests/FormCoreTests/NativeStoryPaintTests.swift), [paint-stack commands](../Tests/FormCoreTests/ArtworkPaintStackEditingTests.swift), [paint resource transfer](../Tests/FormCoreTests/ArtworkPaintTransferTests.swift).
- [Private-board Paste](../Tests/FormAppTests/FigmaClipboardPasteTests.swift): independently encoded 1,500-layer scene, placement/scope/camera, representation precedence, stale project/scope cancellation, live text handoff, Undo/Redo, save/reopen and partial copy. Tests never read the user's general clipboard.

## Deferred real-Figma validation matrix

This round must finish without opening Figma or reading actual design clipboard data. A later authorized round should record Figma version/platform, source document provenance, advertised clipboard types, capture time and the precise LAB revision for each case.

| Source case | Compare appearance | Exercise native behavior |
| --- | --- | --- |
| Ordinary Copy in current desktop and browser Figma | Envelope/types, units, transform/order, self-contained image availability | Canvas Paste, nested destination scope, physical projection, camera preservation, one Undo/Redo |
| Dense layered frame, roughly 500/1,500/near-limit nodes | Occlusion, nested clips, independent corners, rotations/reflections/shears | Deep select, group navigation, move/scale, grouping, alignment/distribution, Copy a subset, save/reopen |
| Rich text with emoji/RTL/missing and variable fonts | Baselines, wrapping, line/paragraph spacing, decorations, per-range gradients/strokes | Change words/font/size, recolor one span and whole text, resize area text; verify characters remain editable |
| Alpha/vector/luminance mask runs | Stroke-only vector ring, consecutive mixed masks, half-opacity overlaps, text/image masks and holes | Edit original mask children, move/scale mask/content independently, pointer targeting, partial copy, Undo |
| Paint/effect-heavy art | Image fill/crop/tile, P3 colors, gradient transforms/stops, shadow order/spread/knockout, blend against different backdrops | Edit native paints/effects; compare PNG/PDF/SVG output, including transparency and output-budget rejection |
| Components/variants/nested overrides | Resolved geometry, repeated occurrence addressing, swaps, derived bounds and resized constraints | Verify which objects remain linked versus explicitly materialized; edit text/visibility and recopy dependencies |
| Missing/unsupported source data | Missing image/font/definition, unknown effects/paint types, unavailable variable/layout values | Verify blocking errors are atomic and supported differences have visible notes; no silent SVG/raster fallback |
| Limits and cancellation | Capture duration, memory and cancellation latency for dense/nested scenes | Repeat Paste, change project/scope during staging, reject oversized input, preserve live text/history/assets on failure |

A successful parse or visual resemblance alone is insufficient. Record whole-scene and close-up comparisons plus actual selection/edit/copy/Undo loops. Keep raw source captures local with explicit user authorization; add only permissioned, minimized regression fixtures. Until this matrix is executed, describe the work as implemented native clipboard support under synthetic verification, not universal Figma compatibility.
