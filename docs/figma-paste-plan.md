# External design paste: Figma first

Research date: 2026-10-31. LAB baseline: `31f1e16` (`origin/main` fetched this round). Working branch: `codex/figma-paste-foundations`.

## Decision and scope

Build toward ordinary **Copy in Figma → Paste in LAB → editable native layers**. This is feasible enough to pursue, but source inspection does not establish interoperability. This round updates the regular LAB build and defines the implementation; it does not ship a Figma decoder. No Figma app/account, human clipboard, or real Figma design data was accessed. Real-copy validation is deferred as requested.

Use two adapters over one import transaction: documented SVG interchange for an early usable feature, and an isolated native Figma compatibility adapter for the intended ordinary-copy experience. Start the native decoder spike alongside the shared foundation so SVG does not become the endpoint of this work. An optional plugin-generated package is a later supported extraction route if private-format compatibility or missing resources prove limiting.

“Native” means independently selectable/editable layers, usable hierarchy, editable text where supplied, local image resources, correct transforms and order, and ordinary LAB group/move/scale/copy/Undo behavior. Static geometry does not preserve responsive auto-layout behavior. Paths made from outlined letters are editable vectors, not editable text. A raster preview is not a native import.

## What the sources establish

| Route | Evidence | Consequence for LAB |
| --- | --- | --- |
| Copy as SVG | Figma documents this explicit command for moving assets between tools. [Figma Help](https://help.figma.com/hc/en-us/articles/360040030374-Copy-assets-between-design-tools) | Useful first interchange adapter; do not confuse it with ordinary Copy. |
| Ordinary Copy | Figma's 2015 engineering account describes binary content carried in `text/html`. This is historical evidence, not a current clipboard specification. [Figma engineering](https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/) | Need representation detection and a private-format adapter. |
| Native serialization | Figma's cofounder describes Kiwi serialization as an internal implementation detail subject to change and identifies HTTP APIs as the stable file interface. [Evan Wallace](https://madebyevan.com/figma/) | Version and isolate compatibility code; reject unsupported payloads clearly. |
| Plugin export | Official APIs expose `SVG_STRING` and `JSON_REST_V1`; images can be retrieved through `Image.getBytesAsync()`. [Export settings](https://developers.figma.com/docs/plugins/api/ExportSettings/), [Image API](https://developers.figma.com/docs/plugins/api/Image/) | A future user-invoked exporter could package node JSON plus local assets. It requires an open Figma file. |
| REST extraction | Authenticated file/node endpoints expose hierarchy and optional vector geometry; separate endpoints expose image fills/renders. [REST overview](https://developers.figma.com/docs/rest-api/), [file endpoints](https://developers.figma.com/docs/rest-api/file-endpoints/) | Useful future URL/file import; not a decoder for arbitrary clipboard contents. |

Figma's SVG export settings default to outlining text. Text export can preserve characters, with rendering differences across engines; inside/outside strokes may be approximated. SVG alone therefore cannot promise a complete Figma editing model. [Official SVG settings](https://developers.figma.com/docs/plugins/api/ExportSettings/)

### Native clipboard evidence, pinned to inspected source

These are reverse-engineered implementations, not an official contract:

- OpenPencil extracts Base64 from `(figmeta)…(/figmeta)` and `(figma)…(/figma)` HTML markers, then decodes an embedded schema and a `Message`. [Clipboard reader, `e9aa2b0`](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/fig/src/clipboard/import.ts)
- The container starts with `fig-kiwi`, a little-endian version and length-prefixed chunks. Schema data uses raw Deflate; scene data can use raw Deflate or Zstandard. Detect compression by supported framing/signatures rather than assuming a codec from the version. [Container reader](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/src/fig/container.ts), [independent Sketch decoder, `450e3b3`](https://github.com/sketch-hq/fig2sketch/blob/450e3b350a6f9cf05d659459cf240def6b7f0483/src/figformat/kiwi.py)
- Grida's implementation also decodes a schema from chunk zero. Its prose claiming clipboard payloads lack a schema conflicts with this code; use the implementation as evidence for the formats it handles, without generalizing to all versions. Node records, metadata and blobs require further interpretation. [Grida parser, `9cbacac`](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/packages/grida-canvas-io-figma/fig-kiwi/index.ts)
- Kiwi has its own numbers, float representation, strings, structs and tagged messages. Interpret the supplied schema as data. Do not compile/evaluate payload-derived code. [Canonical Kiwi specification](https://github.com/evanw/kiwi), [interpreter reference](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/src/schema-runtime/interpreter.ts)
- Vector commands and vector networks require additional blob decoding; blob indices can be relative to `blobBaseIndex`. A successful outer-message decode is not a successful path import. [Grida blob parser](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/packages/grida-canvas-io-figma/fig-kiwi/blob-parser.ts)
- Some image bytes may be local, but OpenPencil also implements a missing-image resolver using a private Figma endpoint. This does not establish reliable anonymous access. LAB's initial adapter should remain local-only and diagnose unresolved image hashes. [Image embedding](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/fig/src/clipboard/images.ts), [missing-image resolver](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/src/app/editor/clipboard/figma-images.ts)
- Component definitions can live on internal support canvases, with visible instances referring to them and applying overrides. Do not paste those support pages as visible content. [Grida fixture notes](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/fixtures/test-fig/clipboard/README.md)

OpenPencil, canonical Kiwi and Sketch's converter have MIT licenses; Grida's root license is Apache 2.0. Inspect selected files, package exceptions, notices and fixture provenance before adopting code. No dependency or third-party fixture was adopted this round. [OpenPencil license](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/LICENSE), [Kiwi notice](https://github.com/open-pencil/open-pencil/blob/e9aa2b0b569e0219c898166ba67a2f65fe5cfc87/packages/kiwi/NOTICE), [Grida license](https://github.com/gridaco/grida/blob/9cbacacc89517971aec37d3de1c82202fb4d7986/LICENSE), [Sketch license](https://github.com/sketch-hq/fig2sketch/blob/450e3b350a6f9cf05d659459cf240def6b7f0483/LICENSE)

## LAB audit at the baseline

| Area | Existing implementation | Required work |
| --- | --- | --- |
| Clipboard routing | `VectorCanvas.paste` → `ArtworkSession.paste` → `pasteArtwork`; only `studio.form.artwork` is read. | Injectable representation snapshot/chooser; external SVG and Figma adapters; useful unsupported-format feedback. |
| Transaction | Preflight, detached asset staging, project epoch/scope validation, live-editor handoff, replan, one Undo, asset recovery. | Reuse this path, with an adapter factory rather than fake source-project metadata. |
| SVG | Editable groups, affine transforms, paths, gradients, geometric clips, text and embedded PNG/JPEG; fidelity report. | Clipboard placement/scope behavior, budget reconciliation and off-main parsing work. The existing importer is `@MainActor`. |
| Hierarchy/geometry | Groups, local transforms, Bézier paths, geometric clipping, booleans and components. | Decode source ordering and vector networks; map masks/instances according to explicit supported semantics. |
| Appearance | One fill/gradient, stroke, shadow and blur per element; blend modes and isolation; one corner radius. | Paint/effect stacks, independent corners and alpha/luminance masks need generic model/renderer work or explicit loss reports. |
| Typography | Native rich UTF-16 spans, point/area frames, paragraph controls, variable-font axes and features. | Direct Figma-to-native text mapping; font availability diagnostics and layout comparison. SVG text conversion has fewer capabilities. |
| Layout/components | Native components exist, but Figma overrides/variants do not map automatically. No general auto-layout/constraint model. | Preserve resolved geometry first with an explicit static-layout report. Add live semantics separately; never label detached copies as linked components. |
| Assets/provenance | Content-addressed local bytes; retained source SVG. Provenance is currently frame-wide. | Typed provenance associated with imported roots; partial copy of one imported group must work. |

Code entry points:

- [ArtworkTransferSession.swift](../Sources/FormApp/ArtworkTransferSession.swift), [ArtworkTransferOperations.swift](../Sources/FormApp/ArtworkTransferOperations.swift), [ArtworkTransferPlan.swift](../Sources/FormCore/ArtworkTransferPlan.swift).
- [SVGImporter.swift](../Sources/FormGraphics/SVGImporter.swift), [SVGText.swift](../Sources/FormGraphics/SVGText.swift), [SVGShapes.swift](../Sources/FormGraphics/SVGShapes.swift), [SVGImport.swift](../Sources/FormApp/SVGImport.swift).
- [Model.swift](../Sources/FormCore/Model.swift), [ArtworkAppearance.swift](../Sources/FormCore/ArtworkAppearance.swift), [ArtworkTransferGraph.swift](../Sources/FormCore/ArtworkTransferGraph.swift), [ArtworkTransferBundle.swift](../Sources/FormCore/ArtworkTransferBundle.swift).

Three integration traps need explicit fixes:

1. `commitSVG` currently centers imported art, clears group scope and fits the camera. Ordinary Paste should preserve the user's destination scope and camera. Reuse its parser/result, not its whole file-import UI transaction unchanged.
2. `ArtworkTransferGraph.capture` rejects partial selection whenever frame-level `art.imports` is nonempty. Adding source provenance to every external paste would make copying one group from a busy canvas fail. Associate source records with imported root closures and migrate legacy records conservatively. Root associations alone cannot isolate opaque original bytes: if one original contains roots A and B, Copy A must omit that shared original while retaining normalized per-node provenance and required assets, unless a safe subset can be reconstructed. Retain the complete original in its originating project; never include B's hidden content merely to preserve A's source record.
3. Transfer asset validation permits image/PDF/SVG/ICC extensions, not arbitrary native clipboard/HTML bytes. Add a typed inert source-record representation with resource limits; never rename native bytes to `.svg`. An imported-source closure must survive save/reopen, duplicate, partial Copy and Undo.

Current limits also differ: SVG admits 5,000 elements/depth 64 and embedded images up to 40MP; portable transfer admits 2,048 elements/depth 32, 16MP per raster frame/32MP total, 32 assets and 32MiB total asset bytes. SVG dimensions are restricted to 1–1,000mm. Define a shared external-import profile and diagnose limits before editing; do not silently truncate a dense artboard or rescale oversized/small content to make it fit.

## Proposed implementation contracts

### Clipboard routing

Snapshot pasteboard representations only on an explicit Paste action, with the existing private-pasteboard injection for tests. Keep normal text-editor paste in the native text responder. For Canvas, prefer valid LAB native content, then a supported native Figma payload, then SVG. Inspect candidate macOS SVG UTIs and SVG text without treating arbitrary HTML as artwork; actual advertised UTI combinations must be confirmed in the real-data round. PNG/PDF are separate visual-import options, not equivalent native fallbacks.

Corrupt preferred data must not silently degrade to an image or change the editor. An explicit available fallback can be offered with its limitations. Snapshot the destination and cancellation generation before asynchronous work; a new paste, changed project, frame or group invalidates pending insertion.

### Normalized import candidate

Introduce a generic value graph between format decoders and LAB insertion. It carries source IDs, selected roots, ordered parent/child relations, local affine transforms, source units and color-space/profile metadata, text spans, paint/effect information, typed local asset references, source provenance and per-node fidelity issues. Separate source-format facts from model conversion so future Sketch/Illustrator adapters can reuse the same transaction.

Map into native `Artwork` and resources only after validating graph closure. Remap every identity, retain sibling order, distinguish visible roots from support definitions, and reject dangling/cyclic references. Use three issue classes: exact mapping, approximation requiring review, and unsupported content that blocks faithful import. Preserve the original source for recovery where permitted by the scoped provenance model. Do not silently drop layers.

LAB uses millimeters for geometry and points for typography. Use the existing SVG convention, `1 CSS px = 25.4 / 96 mm`, as the proposed source-pixel policy; a 16px text size becomes 12pt before transforms. Apply conversion once across positions, paths, strokes and effects. A source scale control may be useful later. Preserve destination color/profile settings and convert source colors into the destination representation using known source metadata. Represent absent source language/profile as unspecified; missing information that affects color fidelity needs an explicit issue rather than silently interpreting Display P3 values as sRGB. [Figma export color profiles](https://developers.figma.com/docs/plugins/api/ExportSettings/)

External placement should center the copied bounds in the visible canvas or use an explicit Paste Here point, converted through the destination group's/projection's inverse transform. Preserve internal offsets, select pasted roots, and leave camera/scope unchanged. Repeated-paste behavior should be defined and tested; current internal LAB paste's 10mm offset need not change as part of external-format work.

### Native format adapter

Parse HTML as inert text; validate Base64 and container framing before decoding. Use a bounded Kiwi interpreter and maintained native raw-Deflate/Zstd implementations after checking SDK availability and packaging impact. Keep schema interpretation separate from node semantics. Unknown optional schema fields can be read/skipped using their definitions; unknown required geometry/paint semantics need diagnostics.

Enforce independent budgets for encoded bytes, decompressed bytes, schema fields/references, strings, arrays, blobs, graph nodes/depth and total work. Reject nonfinite numbers, invalid indices, cyclic graphs and expansion beyond limits before publication. Parsing/staging should support cancellation off the main thread; only editor handoff and the atomic commit belong on the main actor. Do not fetch private endpoints or remote images as a side effect of Paste.

### Commit behavior

Adapt the normalized candidate to the existing prepare → preflight → stage → revalidate → finish editing → replan → publish → commit path. Failed/cancelled input must leave document, unpublished text, selection, focus, history and existing assets untouched. Successful Paste creates one Undo step; Undo/Redo and save/reopen retain resources, hierarchy and selected roots. Fidelity review, when necessary, happens before editor handoff and remains tied to the snapshotted destination.

## Delivery slices and exit criteria

1. **Shared paste foundation and provenance repair.** Add format selection, candidate/issue types, scoped source records and resource policies. Exit: all existing LAB transfer tests pass; private synthetic boards cover responder routing, precedence, cancellation and Copy of one imported group.
2. **Editable SVG paste.** Feed existing SVG conversion into the shared transaction. Exit: dense synthetic groups preserve transforms/order/clips/text where supported; fidelity review is clear; scope/camera stay fixed; Undo and reopen work. Describe this specifically as SVG paste, pending real Figma SVG validation.
3. **Native decoder spike, alongside slices 1–2.** Implement envelope/container/schema/blob reading independently of the UI, with no public compatibility claim. Exit: independently specified synthetic examples for both codecs and malformed-input tests; documented supported container/schema boundaries and resource budgets.
4. **Native node mapping.** Add groups/frames, geometry, simple paints, paths, embedded images and editable text, then component definitions/overrides and complex appearance. Exit: generic synthetic scenes render and remain editable with explicit issue reports; absent assets and unsupported semantics cannot masquerade as complete imports.
5. **Real Figma compatibility round.** Capture approved designs from current desktop and browser versions, compare source and LAB renders, and exercise editing on dense artboards. Only then enable and describe ordinary Figma paste for the validated feature set.

Choose richer plugin/REST import later if self-contained assets or stable node semantics require it. These routes should produce the same normalized candidate rather than a parallel insertion engine.

## Verification plan

Synthetic tests can begin without Figma, but they prove our implementation contracts rather than real producer compatibility:

- Private `NSPasteboard.withUniqueName` boards; competing/corrupt representations; empty/oversized data; Canvas versus active text editing; rapid repeated Paste and project/scope A→B→A changes.
- Raw Deflate and Zstd; schema variations/unknown fields; malformed lengths, huge counts, unterminated strings, recursive schema references, invalid blob offsets, duplicate IDs, cyclic parents and nonfinite coordinates. Bound peak memory and cancellation latency.
- Generic 500/1,500/near-budget layer scenes with 8–24 nested group levels, overlapping masks, repeated assets, vector holes, rotations/reflections/shears, UTF-16 rich text, missing fonts, crops, opacity and gradients. Include one scene beyond each budget and require an atomic rejection. Keep fixtures in tests/project packages, not application-specific example branches.
- Paste into free canvas, transformed nested groups and projected physical surfaces; inspect placement and unchanged camera. Group, ungroup, deep-select, align, distribute, move, resize and Copy one pasted group; Undo/Redo every structural operation and save/reopen.
- Asset deduplication/collisions, locked/deleted targets during staging, failure after asset publication, stale review context, and exact preservation of unpublished text on failure. Import one original containing A+B, then Copy A: verify B and its opaque source content do not travel. Verify sRGB/P3 conversion and missing-profile diagnostics independently of destination preferences.

Reuse [ArtworkTransferEditingTests](../Tests/FormAppTests/ArtworkTransferEditingTests.swift), [ArtworkTransferLifecycleTests](../Tests/FormAppTests/ArtworkTransferLifecycleTests.swift), [ArtworkTransferPublicationTests](../Tests/FormCoreTests/ArtworkTransferPublicationTests.swift) and [SVGImportTests](../Tests/FormCoreTests/SVGImportTests.swift).

For the deferred real-data round, record Figma version/platform, advertised clipboard types, payload hashes/sizes and a consented source screenshot. Cover ordinary Copy and Copy as SVG separately: dense dashboard, typography-heavy artboard, clipped illustration, nested component variants/overrides, image-heavy composition, missing-font case and missing-image case. Compare whole design and close-ups for geometry, text baselines/wrapping, crop, masks, paint order, color and effects. Record actual native editing loops and performance; a successful parse or screenshot resemblance alone is insufficient.

## Status of this round

- Research and local pipeline audit complete; implementation contracts and acceptance gates documented.
- Production importer behavior is unchanged. No decoder, synthetic interoperability tests or live Figma compatibility are claimed.
- Built release from main `31f1e16` into a separate candidate, verified its signature, saved and quit the running LAB, then installed/reopened the ordinary `build/LAB.app`. Previous bundle retained at `.local/figma-paste-before-main-20261031.app`.
- Installed executable SHA-256: `0d82fdab6878931c231224fc090ce214c017f1655bd100badce3c66e77e34318` (matches verified candidate).
- Existing regression selection `ArtworkTransfer|SVGImportTests|SVGWorkspaceDestinationTests|SVGLazyInsideImportTests`: **64 tests passed**, zero failures (45 core, 19 app). Logs: `/tmp/lab-figma-main-build.log` and `/tmp/lab-figma-main-tests.log`. These validate existing LAB infrastructure, not new Figma interoperability.
- Reopened and visually inspected the existing 782-layer dense canvas. Project ID, object/artwork data, recipes, materials, notes, units and persisted project camera matched the pre-update snapshot exactly. Canvas reopened at its normal fit view; the previous hidden Layers panel was restored. Only one regular LAB app is running.
