# Advanced publication extension contract

The existing `ProductObject.sheetAssembly` is the physical authority. Pages, cover atlases, photographic inserts, jackets and cases remain editable project data using the existing artwork, stock, finish and Studio paths. There is no built-in hardcover, softcover or case generator. Optional fields preserve older documents when absent; advanced structure, physical dimension relationships and panel features require schema 65.

This document describes the implemented API contract. Completed native review and its limits are recorded separately in [the validation report](advanced-publication-validation.md). The [implementation and acceptance plan](advanced-publication-implementation-plan.md) and [book rendering handoff](book-publication-rendering-handoff.md) define the required native review. Example authoring and retained evidence are documented in [the project-data builders](../examples/advanced-publications/README.md).

## Ordered sheets, stock and bindings

- `SheetAssemblyDefinition.signatures: [SheetAssemblySignature]?`: each `{id,parentSheetIDs}` groups authoritative parent records in reading order. Every parent occurs once; each gather nests independently. Omission retains the existing globally nested run. `SheetAssemblyCommands.reimposingSignatures(in:objectID:parentSheetsPerSignature:)` returns a definition with correctly reimposed slots, preserving parent IDs, stock and ink intent. Merely grouping IDs without reimposition is not a valid reorder.
- `parentSheets[].stock` remains the single stock authority for a folded sheet. Nullable front/reverse slots represent physical blanks without adding logical pages. Viewing leaves derive their stock, reversing ply order for the reversed parent half. Conflicting explicit leaf overrides reject the transaction.
- `SheetBindingStyle` supports `none`, `saddleStitch`, `sideStaple`, `adhesive` and `sewn`. Existing fastener positions, dimensions and `flexWidthMM` remain editable. Optional `adhesiveMM` and `sewingSwellMM` are construction allowances, not changes to sheet caliper. Their sum is the binding allowance for an active binding. Gather folds, sewn thread and adhesive use distinct derived geometry/materials; opening remains an idealized physical pose rather than a mechanical simulation.
- `auxiliaryLeaves: [SheetAssemblyAuxiliaryLeaf]?`: `{id,name,placement:front|back,size?,stock,front?,back?,attachment?}`. These unnumbered leaves use canonical `SheetAssemblyFace` references and add actual stock thickness. Optional expression-based size defaults to trim. An attachment is `{planeID?,edge:left|right|head|tail,widthMM}`; a zero-width attachment to a plane follows that plane as a pasted lining, while a positive margin supplies its flexible attachment.
- `edgeArtwork: SheetEdgeArtwork?`: `{head?,tail?,foreEdge?}` uses canonical face references, separate from paper color and page-face ink. Head/tail sources span `trimWidth × textBlockThickness`; fore-edge spans `trimHeight × textBlockThickness`. The closed text block establishes registration, then each leaf's corresponding edge follows its opening deformation. Auxiliary sheets are excluded from this body-edge registration.

A publication has at most 200 logical pages. An assembly supports at most 200 physical leaves including up to 16 auxiliary leaves, 51 folded parents and 128 authored enclosure planes. The additional planes describe generic layered/folded structures, not a named product category.

Gather ribbons use the actual parent leaf height and adhesive uses body trim height. Fully turned/unturned parent folds and stitches follow the corresponding resolved leaf roots through a rigid transform that retains caliper and neutral length. A mixed turned/unturned parent at the active spread remains an idealized closed gathering; the current page-opening pose is not a length-preserving mechanical fold solver, and no stretched ribbon or exact sewn-mechanics claim is substituted for it.

## Canonical faces and generic panels

`SheetAssemblyFace` is `{sourceObjectID,sourceSide?,sourceOriginMM?}`. The source is independent canonical flat artwork or an ordinary paper object. `sourceSide` selects existing outside/inside paper artwork; the crop origin is in physical millimeters. A face receives its physical plane extent from the construction: an entire atlas is never scaled onto every plane. Source cycles, missing owners and out-of-bounds crops reject the final transaction.

`SheetAssemblyPlane` retains expression-based `size`, `positionMM`, `rotationDegrees`, its own `stock`, `front`, `back` and `finishes`. Local +X is width, local -Y is page-down, and +Z is the front face; rotations apply X, Y, then Z. `features: SheetPanelFeatures?` is also available on ordinary `PlanarPanelDefinition` and is carried through `PaperPanel.features`, so the same physical operations work for packaging, folders, signs and cases.

| Feature | Authored fields and behavior |
| --- | --- |
| Outline/cutouts | Optional panel-local expression points and ordinary cutout declarations; validate through the shared simple-polygon/hole kernel. |
| Core caliper | `stockThickness: CADScalar?` overrides the core's actual caliper. Bonded plies retain their relative proportions and their original face materials. |
| Wrapping | `wrap: {stock,turnInMM,cornerRadiusMM,stockThickness?}` adds real wrapping stock, sidewalls, corners and mitered turn-ins. Its optional caliper expression changes the wrapping material separately from the core, including proportionate ply calipers. |
| Flex | `flex: {edge,widthMM,angleDegrees,curve?}` bends a material strip about a neutral axis. Width is material arc length, not the straight endpoint distance. Circular flex and an authored neutral curve are alternative definitions. |
| Recess/inset | `recesses: [{id,origin,size,depthMM,cornerRadiusMM,insert?}]`; an insert is `{stock,face?}` with its own canonical crop. Cavities cannot overlap or collide with cutouts. Floors/depths and distinct slab/ply boundaries retain at least 0.01 mm. Source ply interfaces and materials stay at their physical depths rather than being rescaled into every slab. |

A printed wrapped front source must cover the expanded physical rectangle: cap origin minus `effectiveCoreCaliper + turnInMM`, and cap extent plus twice that margin. Sidewall and turn-in textures continue from that same registered artwork. Wrapping caliper contributes to the physical envelope and curvature clearance; it is not added to the sidewall source margin a second time.

### Authored neutral curves

`SheetPanelNeutralCurve` is `{points:[{x,y},…],fitLength?:Bool}` with exactly four CAD-expression control points forming one cubic in `(edge distance, normal offset)` millimeters. The first point is `(0,0)`. It is assigned as `features.flex.curve` with `angleDegrees:0`; `widthMM` supplies the actual material length.

With the default `fitLength:false`, the authored curve's arc length must already match `widthMM`. With `fitLength:true`, the solver changes only the common X-handle multiplier of the two interior control points. Endpoints and all control heights remain fixed; source width, material length, artwork coordinates and UVs never stretch. An endpoint chord longer than the material, an unreachable length, cusp/stationary tangent, out-of-bounds handle or radius through the actual core-plus-wrap caliper rejects the edit. There is no rigid/straight fallback for an invalid curve.

The same resolved `SheetPanelNeutralCurveProfile` drives material-distance mesh deformation, parallel caliper surfaces, normals and closed-envelope bounds. This permits a project to author a continuous curved reinforcement between independently posed panels while retaining its real stock length.

## Measurements, expressions and live dependencies

`Project.sheetAssemblyMeasurements(_:)` returns:

- `trimWidth`, `trimHeight`: maximum logical leaf trim, independent of the current opening pose.
- `textBlockThickness`: body leaves only, from authoritative stock/ply calipers.
- `bindingAllowance`: the explicitly declared adhesive/sewing allowance.
- `spineThickness`: body plus auxiliary thickness plus binding allowance.
- `closedWidth`, `closedHeight`, `closedThickness`: the actual closed envelope, including evaluated panels, flex, core and wrap thickness.
- `bindingFlexWidth`: the effective margin flex width for side-stapled, adhesive or sewn bindings, otherwise zero.

Measurement resolution deliberately omits artwork-crop validation, allowing a source artboard to derive its size from the assembly that consumes its artwork. Final validation checks the reconciled sources and crops. Measurements are memoized only within one reconciliation in dependency order; no cached size can survive an upstream edit.

The same resolver exposes `ResolvedSheetAssembly.closedBoundsMM` and `sheet_assembly_inspect.resolved.closed_bounds_mm`: `{minimum_mm:[x,y,z],maximum_mm:[x,y,z]}` in source-local millimeters, before source object placement or Studio instance transforms. X/Y/Z extents correspond to closed width/thickness/height. These complete bounds include resolved aliases, neutral curves and evaluated wrapping calipers independently of inspection pagination and current opening pose. Project-data composition consumes this authority rather than reproducing panel-envelope geometry in another language.

Ordinary authored paper uses the same real flex/wrap envelope for closed measurements and grounding, including finite circular flex, neutral curves, material caliper, off-origin panels and explicit components. A single-root construction needs no extra component merely to ground its bent material. Current viewing opening does not replace the closed-rest measurement used by dependent source dimensions. Generic jackets and cases therefore consume physical bounds rather than undeformed cap corners.

`SheetAssemblyDefinition.derived: [String:String]?` holds named CAD arithmetic. Aliases resolve after the existing object parameters and physical inputs: `width`, `height`, `trimWidth`, `trimHeight`, `leafCount`, `pageCount`, `stackThickness`, `textBlockThickness`, `bindingAllowance`, `spineThickness`, `openingDegrees`, `activeSpread`, `bendMM`, `bindingFlexWidth` and its `bindingFlexWidthMM` alias. `stackThickness` includes auxiliary leaves. Aliases share the existing CAD parser's finite domains, name-collision and dependency-cycle checks, 256-byte expression limit and bounded variable/alias allocation. Runtime poses and closed-envelope probes resolve the same aliases from their respective inputs.

Existing `form_update_object` accepts:

- `dimension_bindings`: `[{parameter,expression,inputs:{name:{sourceObjectID,measurement,parameter?}}}]`. Up to 32 target parameters and 64 named inputs per binding. Measurements include ordinary width/height/depth, an explicit numeric parameter, and the assembly measurements above. Dimension dependencies do not consume/hide source products on the Table. Derived targets must be edited through their source or explicitly detached; cycles, missing sources, invalid ranges and conflicting variant targets reject atomically.
- `artwork_regions`: `[{id,name,origin:{x,y},size:{x,y},anchors?}]`. These are nonprinting canonical-source guides, at most 64 per source. Anchors are `{elementIDs,horizontal,vertical}` with normalized 0–1 positions. They translate top-level layers/groups by the region delta; they never resize type, frames, paths or images. Each layer has one position authority. Invertible affine roots are supported; nested/conflicting anchors, singular transforms and simultaneous conflicting manual position changes reject rather than silently moving ink twice.

Reconciliation updates target dimensions and explicit anchors before full crop validation, within the same document Undo transaction. This is the shared dependency path for cover atlases, spines, jackets and one- or multi-volume cases; those constructions and their ordering are authored project data.

## Publication edits, native controls and MCP

The existing publication inspector provides structure, material, panel, canonical-source and compact whole-document **Trim** controls. Native controls and public commands use the same Core mutations and captured project/publication identities; stale imported-project fields cannot edit another project sharing document IDs.

- `PublicationCommands.resizePages(in:publicationID:width:height:)` / `form_publication {command:"resize_pages",publication_id,width,height}` atomically changes every page to a uniform 20–2000 mm trim. Both public axes and the explicit document target are required; individual page selectors are rejected. Parent `sizeMM` becomes `(2*width,height)` while parent/gather IDs, stocks, print intent, reading order, margins, story sources and canonical page artwork remain exact. Dependent cover/jacket extents and aliases reconcile before crop validation. Existing inconsistent parents, locks, unsafe page setups or another authority that would change the requested trim or move/scale page ink reject the whole operation. This is a trim edit, not an imposition or artwork-fit command.
- `PublicationCommands.addPages(...,canvasSourceOnly:false)` / `form_publication {command:"create_pages",…,canvas_source_only:true}` can create canonical pages without transient separate Table meshes. The Boolean option belongs only to bulk `create_pages`. It sets the existing `ProductObject.canvasSourceOnly` role before publication; the same editable Canvas pages feed a physical assembly. Omission/false leaves the old optional JSON field absent. It introduces no new source type. Bulk page creation gets its existing bounded 180-second bridge response window; ordinary native/control edits retain 30 seconds.
- Homogeneous `form_batch` operations consisting entirely of `form_set_artwork` decode and validate each artwork/image asset, apply the ordinary canonical-owner/style/story rules in order, then reconcile, prepare native dependent views and validate the complete candidate once. The 1–100-operation bound, per-sheet result records, single Undo and atomic rollback remain. Repeated owners preserve ordered single-tool semantics; heterogeneous batches retain their established sequential behavior. No editing deadline is expanded for this optimization.
- `form_create_recipe {recipe,replace:true}` evolves a project-owned recipe by retaining existing numeric values for still-declared parameters, adding defaults for new parameters and removing deliberately undeclared values. It preserves artwork and object/design identities. Removed controls that surviving geometry, artwork, dimension or plane expressions still need reject atomically; replacement is not permission to detach those relationships. Variant families retain their shared values and independent iterations keep their own values.

The local bridge retains exact bounded JSON framing for large projects: newline or nonempty EOF terminates one response, fragmented UTF-8 stays byte-exact, and the 8 MiB response cap is enforced before decoding. Accumulation is linear rather than repeatedly reparsing/copying the growing response. Bulk `create_pages`, publication preflight/export and existing native captures keep their specific bounded deadlines. Opening a saved project with a valid project UUID also receives a bounded 180-second preparation window, because its initial native views can exceed the ordinary editing response window. Invalid/missing IDs and ordinary editing calls retain 30 seconds. This avoids reporting a completed large-document open as a failed MCP request; it is not a viewport-latency claim.

## Material preview and render ownership

Paper stock color/opacity is substrate, separate from printed artwork. Native Canvas display paints material beneath canonical artwork through the existing direct-paper and reader-page backdrops plus `CanvasPhysicalSourceStockCache` for physical source crops. The latter covers expanded wrap rectangles, auxiliary/endpaper faces, independent inserts and registered ordinary linked-paper sources, using the same ply/profile/tint resolution as the paper renderer. It clips to each finite source frame, paints agreeing translucent regions once, and leaves conflicting consumer overlaps neutral. It does not invent a material when a source is ambiguous or exceed its bounded region allocation. Authored backgrounds remain authored ink; no source background or export pixels are changed to simulate stock.

Stock/geometry changes invalidate source and overview pixels; unrelated camera or artwork-ink edits reuse structural stock regions. Reader/direct-paper backdrops are not painted twice. Grain, texture, caliper, face-ply color, opacity and existing paper finish assignments continue through the shared paper renderer; final source sampling and relief retain their bounded capture allocations.

Auxiliary, enclosure, wrap/recess and edge sources participate in source ownership, pending-render validation, dependencies and cache revisions. Source/story/font edits reach derived physical materials through the same canonical path. Camera edits and Studio instance poses remain presentation state; they do not create duplicated editable page artwork.

## Acceptance boundary

The model and focused regressions cover construction, source ownership, bounds, atomicity, Undo and persistence. They do not establish reference fidelity, collision-free behavior for arbitrary authored poses, manufacturing tolerances or a complete bindery simulation. Accept the hardcover, softcover, registered edges and fitted cases only after the required repeated native whole-object, underside and detail comparisons and materially different parameter configurations. Production dielines, creep compensation, tooling and verified manufacturing outputs remain the handoff's explicitly deferred phase.
