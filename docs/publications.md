# Linked stories and physical publications

LAB publications use the ordinary Canvas artwork and text tools. A publication is an ordered collection of physical artboards; a linked story is one editable rich text source flowing through frames on those artboards. A physical sheet assembly projects those same pages onto ordered front/back leaves on the Table. Reader spreads, running furniture, and PDF arrangements are derived from those sources.

Book contents, layouts, artwork, stock, enclosure geometry, parameters, and presentation scenes are project data. The application supplies generic editing, composition, validation, and rendering. Creating a different publication does not require changing application code or selecting a built-in book model. The implementation brief is [Multi-sheet publications](multi-sheet-publications.md).

## Source ownership and identities

| Record | Owns | References |
| --- | --- | --- |
| `PublicationDocument` | Ordered page membership, layout, margins, numbering, master assignments, optional baseline grid and language | Physical page objects and canonical master sources |
| `PublicationPage` | Stable logical page identity and optional page-specific settings | One physical artboard through `objectID` |
| `TextStory` | Original source string, rich UTF-16 spans, list identities, glyph choices, shared styles and language | Ordered text frames through object/element pairs |
| Page artwork | Editable vector/image artwork and physical frame geometry | Empty story-frame references; no saved per-frame copy of story words |
| Master artwork | Editable canonical running furniture | An ordinary independent artboard outside publication page membership |
| `ProductObject.sheetAssembly` | Physical stock, ordered face mappings, opening, bend and optional enclosure planes | Publication pages and ordinary artwork sources; no duplicate page artwork |

A `PublicationPage.id` identifies the logical page entry. Its `objectID` identifies the actual artboard. **Public `page_id`/`page_ids` command arguments are artboard object UUIDs.** Explicit physical leaf fields `frontPageID`/`backPageID` instead use `PublicationPage.id`. `form_publication get` returns both; `spreads` returns logical page records as well as the derived physical leaf pairs. Text frames use an artboard object UUID plus an artwork element UUID.

One physical page belongs to one publication. New page membership requires an independent design: make a pre-existing linked variant an independent iteration before adding it. Linked story frames also require independent page designs; variants sharing one design are rejected for those frames. A publication supports at most **200 pages**. The project budget is 30 publications and 200 stories, with at most 400 linked frames and 100,000 source characters per story. These are explicit validation budgets, not a claim that every maximum-size layout has been visually or interactively accepted.

## Native workspace

Facing publications appear as editable reader spreads on Canvas by default, including when the navigator is hidden and after reopening. The rail does not enable or disable that layout. Open **Pages** beside the Canvas/Table chooser, or choose **View → Publication Pages (⇧⌘P)**, to use the floating page rail. The workspace menu and Canvas book icon open the same navigator; closing it keeps that entry available. It selects a publication, shows page thumbnails or facing spreads, navigates previous/next, and focuses the corresponding existing Canvas frames. Thumbnails use the same resolved page artwork as rendering and PDF, including linked text, running furniture and cross-gutter crops, with nonprinting stock color underneath. Enter a printed folio or cover label in **Go to page** to jump directly. The navigator’s settings button opens compact controls for the selected page and its publication. See the [refinement audit](publication-refinement-audit.md) for remaining document and production work.

Agents open the same navigator with `form_set_view {"view":"split","publication_id":"<publication UUID>","object_id":"<page artboard UUID>"}`. `canvas`, `artwork`, and `canvas_window` also support `publication_id`. Omit `object_id` to retain the publication's current page or select its first page. Requests validate the document and page membership before editor handoff; navigation creates no page/workspace source or Undo entry and leaves Table selection and the physical camera unchanged. The response reports the chosen `publication_id`, canonical `object_id`, and `navigator_visible` state.

**New publication** collects the name, physical dimensions, page count, columns, margins, gutter, facing-page choice, and whether to create a linked body story. It creates ordinary editable artboards and optional shared story capacity in one edit. The rail adds a page after the selection, duplicates a page, moves it earlier/later, removes membership, or deletes the physical page. **New chapter** inserts a page with its own linked story and chapter title, then opens the story source editor.

The shared publication inspector is used from both Canvas and Table. It contains publication layout and page labels, chapter/story sources and overset status, canonical masters, physical sheet controls, preflight, and PDF export. Actions to open pages, edit a master, or find the physical object navigate explicitly. Changing shared publication data updates its representations without making selection in one viewport an implicit navigation command in the other.

The chapter list is a view of actual linked stories, rather than a second text model. **Reflow stories** refreshes composition; it does not rewrite the source or manufacture additional pages.

### Linked text editing

Select text on an independent physical artboard and open **Text flow & publication**. **Start linked text story** transfers its editable source into a story. Linking an empty frame adds capacity; **Link + append its words** explicitly appends existing frame content and formatting to the global source, separated by a paragraph break when needed.

Double-click a linked frame to edit. Its native text views share one `NSTextStorage`, layout manager, source mapping, and native Undo manager. Caret navigation can continue into the next physical frame. Formatting an active selection changes its source range; formatting selected linked frames outside text editing changes the story once. Escape finishes linked editing and restores Canvas commands. Frame dimensions and vertical alignment remain physical layout data; linked frames use area text.

**Story source** opens a separate galley using the same storage, including overset words. It can recover an unframed story by attaching a new empty frame. Overset is preserved source that lacks capacity, not missing text.

Open a named source through **Pages → Stories** (stories on the current page appear first), or its **Story source** action in the publication inspector. The source window uses readable editing ink independently of the story's printed color. Bold, italic and underline act on the selected words, or the insertion style for subsequent typing; their shortcuts are **⌘B**, **⌘I** and **⌘U**. Existing font families, ink and rich source settings remain attached to those words. Formatting updates the same linked Canvas frames immediately. Unsupported font traits are disabled rather than synthesized.

The linked-page picker navigates within the source; **Show on Canvas** explicitly reveals that frame. Opening a source retains the current selection instead of jumping to its end. **⌘F** searches the story. The footer shows word/character counts, overset navigation and reading zoom; reading zoom does not change physical typography. **Notes & references** opens a sidebar for selected-text or insertion-point annotations. These are editable, nonprinting editorial metadata, with native Undo alongside text edits. Closing the source finishes the same Canvas editing interaction.

Reordering pages changes a story's page reading order while preserving its within-page column order. Duplication adds empty frame references to the same story without duplicating its words. Removing a frame or page removes capacity and preserves the complete source, even when no frames remain. Removing membership leaves the artboard unless physical deletion was requested. Publication-linked variants are guarded against accidental source coupling.

Structural operations validate a candidate before publishing it. Rejected edits preserve the project and Undo. Removing pages clamps an implicitly paired assembly's turned-leaf position to its remaining leaf count in the same edit. Explicit leaf mappings remain authored references: removing a mapped page is rejected until that mapping is repaired. Remove a linked physical assembly before removing every page or deleting its publication; the app does not silently delete the physical object.

## Facing pages, labels and masters

`layout` is optional. Legacy documents without it retain their saved independent-page layout. With `facingPages: true`, a first `recto` page is on the right alone, followed by verso/recto pairs. A first `verso` page starts on the left. The page rail's facing toggle changes its thumbnail/navigation presentation; publication layout data determines the actual logical grouping. Creating physical sheets adopts facing layout when none was saved, while an explicit `facingPages: false` remains respected.

Explicit `spreadID` assignments group one page or two consecutive verso/recto pages. A group must be contiguous and cannot recur later. This preserves page reading order; it is not an arbitrary rearrangement of page content.

Document margins are millimeters. Optional `innerMargin`/`outerMargin` mirror left/right on facing pages; an explicit page `margins` record overrides that rule. Margins guide newly created text frames. Changing margins or reordering pages does not move, resize, or scale existing artwork.

Numbering supports `arabic`, `lowerRoman`, `upperRoman`, `lowerAlpha`, and `upperAlpha`, plus start, prefix, and suffix. A page `numberOverride` restarts the sequence at that page. A manual `label` overrides its displayed label without changing its number. `chapterTitle` carries forward until another explicit title; an empty string clears it. An absent title inherits the preceding chapter.

A master references an independent canonical artboard through `sourceObjectID`, with physical `x`/`y` translation, `side` (`all`, `recto`, `verso`), and `behind`. Its element artwork is composed at its original physical size; the app does not scale it to fit a differently sized page. Edit the canonical master on Canvas. The generated page groups are locked derived furniture, with stable namespaced element/list identities. Saving a page strips those generated copies so they cannot drift from the canonical source.

Supported running tokens are `{{page.number}}`, `{{page.label}}`, `{{page.total}}`, `{{publication.name}}`, and `{{chapter.title}}`. Runtime expansion preserves rich spans and deterministic paragraph identities, including multiline replacements. A page's `masterIDs: null` uses the masters' side policies; `[]` disables furniture; an explicit list applies those masters. Up to 32 masters are supported. Master sources cannot be publication pages or contain linked-story frame capacity, including through nested components.

Canvas, page thumbnails, physical faces, linked object views, and PDF resolve masters and stories through the shared artwork source path. Canonical page, story, and master edits invalidate dependent live object views; frozen views keep their snapshots. Live cycles through pages, masters, components, or sheet assemblies are rejected atomically.

## Editing across the gutter

A graphic or text frame belongs to one canonical page object. Its local coordinates may cross the gutter or move entirely onto the neighboring half of its reader spread. Canvas draws that element once, under the shared physical spread clip, with both paper backdrops below it. Clicking its visible portion on either half selects the original source; moving and resizing across the gutter retains that owner. Native text hosts use the same spread coordinates and clip. There are no separately editable copies on the two pages.

Each physical page crop derives the appropriate portion of both pages' canonical artwork. The shared crop path feeds PDF, imposed output, physical faces and live object views. Editing the original image transform or words updates both crops; source words, geometry and identities remain stored once. Runtime neighbor groups have deterministic IDs and are stripped if a resolved crop reaches a save path. Masters stay page-local and do not spill onto the neighboring page.

Selection and native text edit one canonical owner at a time. A spanning element is editable from either half. Whole-spread framing, trim/gutter outlines and optional margin guides use derived physical geometry. Source `canvasPosition` values remain unchanged by rail visibility, spread navigation, focus or reopening; unrelated Canvas frames retain their existing placement and behavior. Dragging into a different spread retains the existing cross-frame artwork transfer behavior.

Preflight checks canonical crossing artwork against the shared spread extent. It checks running furniture against its own page and omits duplicate warnings for derived neighbor crops. Dependency validation distinguishes canonical source from rendered page output: ordinary neighboring crops are not a cycle, while a live view feeding its own rendered spread back into printed artwork is rejected.

When one physical construction supplies parent stock, or all relevant constructions agree on color and opacity, Canvas previews that stock side as a nonprinting backdrop. Parent front slots use the outside stock profile and back slots use the inside profile. Keep `artwork.backgroundOpacity: 0` where the physical stock should show through. The preview does not tint the saved artwork, add an ink rectangle or turn substrate color into printed color. Conflicting physical contexts do not choose an arbitrary stock preview.

## Baselines, language and rich source changes

A publication's optional `baseline_grid` contains spacing and origin in points. Paragraphs opt in separately. The compositor reserves full line heights and aligns actual baselines to the grid. Native editing, Canvas, physical faces, generated outlines, and PDF share the placement. Grid-aligned frames must be unrotated, unscaled, and top-aligned. Other linked frames retain supported transforms and vertical alignment.

Language precedence is explicit character language, story language, publication language, then system behavior. Locale-specific hyphenation and case/source provenance remain attached to the original text. Lists continue across frames using global paragraph identities and source offsets. Displayed case expansion can make display coverage differ from source coverage.

For agent text changes, use `form_story replace_text` with a global UTF-16 `location` and `length`. It splices the canonical source, inherits insertion formatting, preserves unaffected rich spans and list identities, remaps global kerning positions, and shifts or removes affected glyph choices. It rejects ranges splitting a surrogate pair. `get`/`edit` also support a complete rich `source` object when deliberately replacing formatting. Direct sparse `edit text` must still have compatible existing range metadata; use `replace_text` for ordinary insertions, deletions, and chapter rewrites.

## Physical sheets on the Table

**Create linked physical sheets** adds a generic `sheetAssembly` object referencing a nonempty publication. Default physical leaves come from logical recto/verso pairs. A recto-first sequence starts with page 1 on a leaf front and page 2 on its back. A verso-first sequence starts with a blank front and page 1 on the back. A missing final face is blank. These leaf pairs differ from reader-facing spreads: pages 2 and 3 face one another but belong to different physical leaves.

The shared inspector controls:

- **Opening:** 0–180 degrees; 0 is a closed stack.
- **Reader spread:** named visible page labels select the remembered physical leaf position. Its stored `activeSpread` is the number of leaves turned toward the left stack, from 0 through leaf count, rather than a logical page number.
- **Page bend:** 0–20mm free-edge rise for the idealized cylindrical viewing bend, applied when open. Geometry also validates bend radius against actual stack offset and caliper.
- **Binding:** none, saddle stitch or side staples; one to eight fasteners, physical crown centers, head/tail inset, crown/wire/clinch dimensions, and side-staple edge inset/margin flex.
- **Stock:** parent-sheet sections expose color/K-only intent, stock choice, caliper, weight, texture and stock/ply colors. Without declared parents the inspector exposes leaf caliper. Changing multi-ply caliper updates its plies proportionally. Ply color controls read and update the effective face color as well as the cut edge; texture reports mixed face settings and a chosen texture updates explicit ply overrides consistently.

Explicit leaves may pair/reorder canonical page entries, use per-leaf stock and finish assignments, and omit one face. Each page face may be mapped only once in that assembly. The two sides of a leaf must have matching trim dimensions; different leaves can have different sizes. Missing or mismatched sources reject instead of fitting artwork.

Declared `parentSheets` represent the actual folded paper, with two front and two back print slots per parent. Slots reference stable logical page IDs and may contain explicit null padding. Each parent owns stock, physical size and `printIntent` (`color` or `blackOnly`); its two viewing leaves derive stock rather than keeping independent copies. A recto-first 52-page publication has 27 reader spreads, 26 viewing leaves and 13 folded parents. These counts describe different representations.

Implicit parent nesting recompiles in the same page edit when pages are inserted, removed, duplicated or reordered, retaining existing parent identity, stock and print intent by ordinal where possible. Added parents use the assembly's default stock and color intent. Padding remains physical blank slots, not phantom logical pages. Explicit leaf mappings keep their authored reference checks.

Optional enclosure planes describe covers, wraps, flaps, and spines as authored geometry, not product-specific application branches. Each plane has a stable string `id`, name, physical size, position, rotation, stock, optional front/back source crops, and finishes. Up to 32 planes are allowed. Positions and dimensions use existing CAD scalar expressions with object parameters plus `width`, `height`, `pageCount`, `leafCount`, `stackThickness`, `openingDegrees`, `activeSpread`, and `bendMM`. Front/back crops translate physical source coordinates through `sourceOriginMM`; they must stay within the selected source's trim and bleed. They never stretch artwork. Plane transforms are explicit, rather than an inferred binding mechanism.

Physical rendering uses the existing paper stock/ply, edge, artwork, and finish paths. Front/back artwork stays tied to canonical sources; source changes refresh dependent physical surfaces. Consumed page/master/enclosure sources remain editable on Canvas and available as explicit scene subjects while ordinary Table presentation shows the assembly. Studio can compose the resulting object with the existing camera and instance tools.

### Independent Studio copies

Select a publication instance in the Studio to use **Publication pose**. Its opening slider and numeric field, named reader-spread picker, page bend, and binding picker use the same physical controls as the source inspector. A copy can inherit its source binding or override it with unbound, saddle stitch or side staples. **Use source pose** clears all overrides. Other copies and the canonical publication retain their own settings.

The saved optional `StudioInstance.sheetPose` contains `openingDegrees`, `activeSpread`, `bendMM`, and `bindingStyle`. Omitted fields inherit the source. Opening is 0–180 degrees, bend is 0–20mm, and the turned-leaf position is checked against that construction’s actual physical leaves. Three copies can display different open spreads while a fourth remains closed, all reading the same original page artwork, stories, stock and binding dimensions. Pose overrides are applied before instance geometry and capture sampling are prepared; each instance has its own render identity.

When source page removal shortens the construction, an accepted copy displays the nearest available physical leaf position without rewriting the saved scene. Its control getter uses that same effective position; an intentional pose edit or duplication starts from the visible position. New or changed out-of-range authoring requests still reject.

A slider gesture makes one draft Undo step. Scene Save persists the independent poses through the existing `form_studio_scene` flow; it does not create additional design objects or copy page artwork. Native image generation and still export capture the visible composition with those poses. A saved scene’s source artwork/materials remain live.

Agents use the existing `form_studio_scene get`/`save` complete-scene API. For example, an instance may contain `"sheetPose": {"openingDegrees": 180, "activeSpread": 10, "bendMM": 1.5, "bindingStyle": "saddleStitch"}`. `activeSpread: 10` is ten turned physical leaves, not logical page 10. Keep the returned scene ID/revision and all other instance fields when saving a changed pose.

This is an idealized visual assembly. Opening rotates ordered leaf stacks; bending is a bounded cylindrical mesh deformation that preserves neutral leaf width. Fastener geometry and the side-staple margin flex are bounded visual representations. This is not a contact/gravity/friction simulation, a sewn-signature or adhesive solver, or a manufacturing-tolerance model. Enclosure planes and finishing are authored representations. A valid assembly or PDF alone does not establish realistic binding behavior or visual quality.

## Preflight and PDF

Preflight reports overset, overly wide glyph/line content, missing fonts, unresolved glyph choices, story capacity outside the publication, missing/conflicting output profiles, and geometry outside bleed. Hidden linked frames continue to reserve capacity and are reported. Physical/export source validation prevents silently exporting stale linked views.

Choose one output layout:

| `layout` | Output |
| --- | --- |
| `pages` | Ordered individual reader pages; mixed trim sizes/orientations supported |
| `spreads` | Derived reader spreads at original physical sizes; mixed sizes supported, without artwork scaling |
| `booklet` | Two-up front/back folded-sheet order; matching trim dimensions required |

When no facing layout is saved, explicitly choosing `spreads` derives recto-first facing output without changing the saved document. An explicitly disabled facing layout retains individual-page groups.

Without declared physical parents, booklet output requires a multiple of four slots. `pad_to_multiple_of_four: true` explicitly adds blank **output** slots, including a leading blank for a verso-first document and trailing blanks as needed. Without permission to pad, incomplete folded sheets are rejected. Padding and imposition do not insert source pages, reorder the publication, split stories, or change page artwork. The returned `arrangement` lists side dimensions, sheet/reverse identity, placements, source page numbers, and blank slots.

PDF pages carry MediaBox, CropBox, TrimBox, and BleedBox. Without declared physical parents, an arranged side uses the common minimum exterior bleed of its source pages. Different allowances produce a `shared_bleed` preflight warning; larger allowances are clipped without changing trim or artwork scale. Physical trim and bleed are millimeters; the configurable 36–1200 `dpi` controls raster effects, not a fit-to-page transformation. Native and outlined text use the shared compositor. Default export refuses overset. Explicit `allow_overset` permits reviewed partial flow; other errors still block output.

Source appearance is sRGB. An assigned [ICC output profile](color-management.md) must be present on every page with the same digest. Conversion preserves physical boxes. Without declared parent sheets, production ink composites and plates retain `pages` output, and spreads/booklet with production ink declarations require an explicit `ink_output: "preview"` appearance export. See [Production inks](production-inks.md).

### Physical parent-sheet output

When a publication has declared `parentSheets`, the same export API uses their physical mapping, paper sizes and per-parent printing intent. It infers a physical edition when there is one, or when every declared edition agrees. Optional `physical_object_id` selects an edition explicitly; conflicting editions require that choice. Reader spreads and imposed parent sides remain separate arrangements.

- Default output and `ink_output: "composite"` produce print content. A `blackOnly` parent requires actual declared process-K paints with zero C/M/Y components, a transparent artwork background and a portable matching CMYK profile. RGB black alone does not establish K-only output.
- A `color` parent supports the actual photographs, vector artwork, native text and effects through the shared page compositor and profile conversion. A neighboring color photograph outside a black-only page’s physical crop does not contaminate that page’s ink validation.
- `ink_output: "preview"` produces a screen appearance proof with the correct stock-side color behind the artwork. Its response marks `for_print: false`, `stock_color_encoded_in_pdf: true`; ink declarations are not encoded as production separations.
- Physical print output reports `for_print: true`, `substrate_is_printed: false`, and `stock_color_encoded_in_pdf: false`. Parent stock color stays a substrate, rather than a printed rectangle. This path supports composite output; `plates` is rejected.

`layout: "booklet"` uses each parent’s two front and two reverse slots at its declared `sizeMM`, including explicit blanks. It adds no exterior bleed or printer margin. A 52-page letter-trim issue on 13 ledger parents therefore exports 26 landscape sides, each exactly 431.8 × 279.4mm; MediaBox, CropBox, TrimBox and BleedBox coincide. Authored source bleed is cropped to the actual paper rather than extending those boxes. Reader pages/spreads from that physical edition also retain their original trim without additional exterior bleed. Leave a physical safe area where the two trims already fill the parent sheet.

`form_publication preflight` accepts the intended layout and ink mode through the same physical source checks. `form_export_publication ink_output: "preflight"` returns the physical report without writing a PDF. Export metadata includes the chosen `physical_object_id`, `parent_sheet_count`, arrangement and stock/print flags. A Generic CMYK profile is a profile-pinned digital conversion study; it is not evidence of press calibration.

## MCP command reference

Commands use snake_case arguments. Nested saved definitions (`layout`, `numbering`, `masters`, `definition`, rich `source`) use their Codable camelCase fields. All `index` values are zero-based insertion positions. Unless a row says otherwise, page command UUIDs identify artboard objects, not logical page entries.

### `form_publication`

| `command` | Arguments and behavior |
| --- | --- |
| `list` | Returns `publications`. |
| `get` | `publication_id`; returns the complete document, including page `id` and `objectID`. |
| `spreads` | `publication_id`; returns `spreads` and physical `leaves` without editing source. |
| `create` | `name`, ordered `page_ids` (may be empty), optional `margins`, `language`, `layout`, `numbering`, `masters`; returns `publication_id`. |
| `settings` | `publication_id`; optional `name`, ordered `page_ids`, `margins`, `language`, `baseline_grid`, `layout`, `numbering`, `masters`. Omitted fields retain their values. `language`, `baseline_grid`, `layout`, `numbering`, `masters` accept null to clear. |
| `reorder` | `publication_id`, ordered `page_ids` containing every existing page exactly once. Updates linked frame page order. |
| `add_page` | `publication_id`; optional `width`/`height` in mm (160/210 defaults), `columns` (1 default, 1–4), `gutter` (8mm default), `story_id`, `index`. Returns new object `page_id` and frames. |
| `create_pages` | Same page arguments plus `count` (1–200); creates the batch atomically and returns object `page_ids`. The resulting publication must remain within 200 pages. |
| `insert` | `publication_id`, ordered distinct new object `page_ids`, `index`; inserts existing independent artboards. |
| `remove` | `publication_id`, object `page_ids`, optional `delete_objects` (false default); removes capacity while preserving story words. |
| `duplicate` | `publication_id`, object `page_id`, optional `index`; creates an independent page iteration and additional shared-story capacity. Returns its object `page_id`. |
| `page_settings` | `publication_id`, object `page_id`; optional `label`, `margins`, `spread_id`, `number_override`, `chapter_title`, `master_ids`. Null clears each override; empty `master_ids` disables furniture. |
| `sheet_assembly_create` | Complete `definition`; optional `publication_id` (must match), `name`, `position` (three mm coordinates or `{x,y,z}`). Returns `object_id` and definition. |
| `sheet_assembly_configure` | `object_id`; complete `definition` **or** sparse `opening_degrees`, `active_spread`, `bend_mm`; optional matching `publication_id`. |
| `preflight` | `publication_id`, optional `output_layout` (`pages`, `spreads`, `booklet`), `pad_to_multiple_of_four`, intended `ink_output` (`preview`, `composite`, `plates`), and `physical_object_id`; uses the same source/compositor/physical-edition checks as export. |
| `delete` | `publication_id`; removes publication membership and releases story association. A surviving physical assembly cannot reference a deleted publication. |

Generated page dimensions are 20–2000mm, gutter 0–100mm, with at least 5mm remaining in each text frame. Existing artboards retain their own supported physical sizes. `margins` uses `{top,right,bottom,left}` in millimeters; `baseline_grid` uses `{spacing,origin}` in points.

Example document settings:

```json
{
  "command": "settings",
  "publication_id": "<publication UUID>",
  "layout": {"facingPages": true, "firstPageSide": "recto", "innerMargin": 19, "outerMargin": 15},
  "numbering": {"start": 1, "style": "arabic", "prefix": "", "suffix": ""},
  "masters": [{"id": "<master UUID>", "name": "Running furniture", "sourceObjectID": "<artboard object UUID>", "x": 0, "y": 0, "side": "all", "behind": false}]
}
```

A complete sheet definition contains `version: 1`, `publicationID`, `stock`, `openingDegrees`, `activeSpread`, and `bendMM`, with optional `leaves`, `enclosure`, `binding`, and `parentSheets`. Omit `leaves` for live default pairing. Explicit leaf records have `id`, optional `frontPageID`/`backPageID` (**logical page UUIDs**), optional `stock`, and `finishes`. Enclosure records have `id`, `name`, `size: {x,y}`, `positionMM: {x,y,z}`, `rotationDegrees: {x,y,z}`, `stock`, optional `front`/`back`, and `finishes`. CAD scalar components accept existing numeric/expression values. A face is `{sourceObjectID, sourceSide, sourceOriginMM?}`, with `sourceSide` `outside` or `inside`. Each array and source reference is validated before the candidate is accepted.

`binding` uses `style` (`none`, `saddleStitch`, `sideStaple`), `count`, optional `positionsMM`, `endMarginMM`, `edgeInsetMM`, `crownLengthMM`, `wireDiameterMM`, `clinchLengthMM`, and `flexWidthMM`. Positions are crown centers measured down from the head edge; omitted positions distribute the requested count between the end margins. Counts, dimensions, crown separation and edge clearance are validated.

`parentSheets` is an ordered array of `{id, frontPageIDs, backPageIDs, stock, sizeMM, printIntent}`. Front/back arrays each contain exactly two logical page UUID/null slots in physical left/right print order. The complete nested mapping must cover the publication once, with explicit leading/trailing padding as needed and compatible doubled trim dimensions. Configure binding and parent stock through the existing complete `sheet_assembly_configure definition`; no separate modeling command or copied page artwork is required.

### `form_story`

| `command` | Arguments and behavior |
| --- | --- |
| `list` | Returns `stories`. |
| `get` | `story_id`; returns the record and complete editable rich `source`. |
| `create` | Ordered `frames: [{object_id,element_id}]`, optional `name`, `publication_id`; transfers original frame content to one source and returns `story_id`. |
| `append` | `story_id`, ordered `frames`; links additional capacity and appends any existing frame words/formatting. Use empty frames to add capacity only. |
| `reorder` | `story_id`, ordered `frames`; must retain the existing membership and publication page order. |
| `unlink` | `frames`; removes those references and retains their source words in the story. |
| `edit` | `story_id`, complete rich `source` or `text`; optional `name`, `language` (null clears). Full source edits must carry valid range metadata. |
| `replace_text` | `story_id`, global UTF-16 `location`, `length`, replacement `text`; returns the updated complete source. |
| `publication` | `story_id`, `publication_id` or null to release association. |
| `delete` | `story_id`; explicitly deletes the story after unlinking its frames. |
| `layout` | `story_id`; native source/display/glyph ranges per frame, used dimensions and overset range. |

`form_edit_artwork` paragraph/list/glyph commands on a linked frame route to the global story; their ranges are global UTF-16 source offsets. Swatches and reusable `form_text_style` styles target the same source, so a shared style edit reflows its consumers without splitting a chapter into page copies.

### `form_export_publication`

Use `publication_id`, optional absolute `.pdf` `path`, `dpi` (300 default), `outline_text`, `allow_overset`, `layout` (`pages` default), `pad_to_multiple_of_four`, supported `ink_output`, and `physical_object_id` for an explicit declared parent-sheet edition. Export returns the path, byte count, output page count, source page count, arrangement, and preflight/profile metadata. `ink_output: "preflight"` requests an ink report rather than writing a PDF; `form_publication preflight` instead accepts the intended output mode (`preview`, `composite`, or `plates`). Export, layout, and compositor preflight require the running native app. The local bridge gives publication export a bounded 600-second response window and publication preflight 180 seconds; client wrappers should leave a longer outer wait. Ordinary editing requests keep their existing shorter deadline.

Rejected story/page operations and core-only atomic batches validate before ending a live native story editor, preserving its responder, selection, draft and Undo. Finish native editing before mixing publication edits and graphics operations in one batch. Commit marked input before structural agent edits or publication export. Read-only story list/get/layout, publication list/get/spreads/preflight, and PDF export do not themselves end a native story editor.

## Storage and validation checkpoint

Schema 26 introduced story/publication records. Optional facing-layout, numbering, master/page settings and `sheetAssembly` data require **schema 63**. Old documents decode without those fields and keep ordinary text behavior. Composed furniture, resolved story fragments, displayed list numbers, native layout contexts, and derived physical geometry are not additional saved authoring sources.

The focused integration checks pass strict asymmetric source/PDF/physical-face pixels, mounted cross-gutter image and text editing, master replay, stock-side previews, source-preserving Undo/reopen, physical parent lifecycle, per-copy Studio pose and gesture/save behavior. Physical PDF checks verify actual page boxes and retained K-only ink operators. These checks establish the exercised source and output behavior; they are separate from the final issue’s native visual review. `scripts/verify_publication_workflows.py` authors disposable 12-page and 64-page projects through the native MCP, calibrates real compositor capacity, and checks source editing, shared styles, lifecycle/Undo, reopen, preflight, and PDF arrangements. Its companion physical workflow exercises linked assemblies and authored scene views.

The final **VARIOUS** issue has completed native source, visual and output acceptance: 52 logical pages (48 interior folios plus four covers), 6,542 editorial words, 110 visual placements, 13 parent sheets of 11 × 17 inches and two actual shared-source Studio compositions. All 27 reader views were inspected individually; page/imposition contacts, independent opening poses and binding comparison were reviewed. Accepted-source exports contain 52 pages, 27 reader views and 26 imposed sides, with zero native publication preflight issues. Recursive inspection of the actual final booklet confirms exact-zero C/M/Y on all eight K-only sides, the selected embedded ICC identity and exact physical boxes. The [example README](../examples/publications/various-quarterly/README.md), [native results](../examples/publications/various-quarterly/VALIDATION.md) and [hash-pinned summary](../examples/publications/various-quarterly/validation.json) identify the actual source, final PDFs and native scene images.

`scripts/author_various_quarterly.py` preserves canonical copy and records source/stock/scene/output evidence through public MCP. The original portfolio and semantic/annotation/framing repairs remain traceable; offline plans and passing tests were followed by actual native render review. This establishes the exercised issue and generic workflows, not maximum-budget responsiveness, press calibration or manufacturing proof.

## Measured still-rendering result

Final Studio stills and generator scene captures use 16 centered subpixel samples of the same native scene. One output-sized render target is reused; premultiplied RGBA samples accumulate in linear light on a background worker. Requested pixels, camera pose, source geometry, materials and physical caliper remain unchanged. Interactive rendering, thumbnails and video retain native sampling. Perspective, orthographic and transparent output use the same capture implementation.

The existing 8192-pixel edge and 32-megapixel output limits remain unchanged. The single accumulator uses 16 bytes per output pixel: 51.2MB for the exercised 2000 × 1600 capture, with an explicit 512MB maximum at 32MP. This records the allocation bound; it does not claim maximum-budget responsiveness.

The controlled 0.12mm paper-stack case reduced measured alias RMS from 0.023053 to 0.002558 (89%) and peak contrast from 0.079509 to 0.011728 (85%), retaining individual paper-edge lines and the original nine mesh builds. The 195-test integration gate passed, including this actual GPU comparison, both camera projections, premultiplied transparency, linear-light energy, cancellation and the unchanged pixel budget. This is renderer evidence, separate from final magazine layout, material and native Studio acceptance.

The retained [native-sampling image](images/publications/foreedge-before-native.png), [final-still image](images/publications/foreedge-after-still.png) and [measured diagnostics](images/publications/foreedge-still-diagnostics.json) are byte-for-byte copies of the accepted production-test outputs. The [evidence manifest](images/publications/foreedge-still-evidence.json) records their original paths and SHA-256 hashes. Rejected diagnostic rounds remain in the local validation record.

## Typed physical inspection and instance pose commands

`form_publication` with `command: "sheet_assembly_inspect"` and a physical `object_id` reads the existing assembly without opening an editor, modifying source or creating Undo. It returns the authored stock, binding and pose; resolved physical sizes, stack caliper and binding positions; and separate page, leaf, parent-sheet, enclosure and reader-spread maps. Each map reports `total`, `offset`, `limit`, `truncated`, `next_offset` and `items`. Request `offset` 0–200 and `limit` 1–50 (default25) to page through the maps. All lengths are millimeters and angles are degrees. Inspection payloads are limited to 1 MiB before protocol wrapping; reduce the page limit if unusually large stock declarations exceed that bound. Finish counts are included; finish-mask artwork is not duplicated into inspection.

Binding inspection distinguishes `unspecified` (no declaration), `unbound` (explicit `style: "none"`) and `bound`. It does not infer a binding from an enclosure silhouette. Render-candidate face flags are conservative geometry information, not camera visibility or a manufacturing claim. The tool catalog describes the complete existing assembly, stock, binding, parent-sheet and enclosure fields; misspelled nested tool-input fields are rejected without changing the project. Loading older project records retains its existing Codable compatibility.

`form_studio_scene` adds three targeted operations for publication instances in saved scenes:

| Command | Arguments | Result |
|---|---|---|
| `pose_get` | `scene_id`, `instance_id`; optional `offset`, `limit` | Authored overrides, source and effective pose, field inheritance, effective binding, clamping status, principal displayed page identities and paged available spreads. Read-only. |
| `pose_update` | `scene_id`, `instance_id`, current integer `revision`; `pose` and/or one page selector | Sparse override edit. Omitted pose fields retain their existing overrides; `null` clears a field to source inheritance. One scene Undo when changed. |
| `pose_reset` | `scene_id`, `instance_id`, current integer `revision` | Clears all instance pose overrides. Resetting an already inherited pose is a no-op. |

The pose fields remain `openingDegrees`, `activeSpread`, `bendMM` and `bindingStyle`. `activeSpread` counts turned physical leaves, not logical pages. A page selector may instead use `publication_page_id` (logical `PublicationPage.id`), `page_object_id` (the artboard UUID), or `page_label` (an exact unique printed label within this publication). Selectors are mutually exclusive and cannot accompany `pose.activeSpread`. Ambiguous labels are rejected. Selecting a page changes the remembered spread without changing the opening angle: open a closed copy explicitly when it should display that spread.

Updates require the returned saved-scene revision and retain every other instance, camera, source page, stock and canonical binding. An unsaved native draft of that same scene must be saved or discarded first; targeted edits to another saved scene preserve the draft and its Undo history. Source shrink can leave an accepted saved spread beyond the new leaf count; inspection reports both authored and clamped effective values without rewriting the scene. New edits still validate against the actual physical leaves. Principal displayed faces describe the physical pose, not camera occlusion. These operations reuse the existing portable model and introduce no alternate physical document or image-generation handoff.

## Complete text capacity preflight

Publication preflight checks every resolved text frame before asking for visible paint bounds. A standalone title too short to admit even one line is an error, including when its ink bounds are empty. Applied master text is checked after page/chapter tokens expand; linked stories report their remaining source only on the terminal frame. CoreText and paragraph/story TextKit composition use the same capacity report as the Canvas overflow indicator. Source ranges are UTF-16 offsets, including case expansion, rich text and emoji.

Linked-story layout also rejects a line that cannot fit the physical frame, including a larger font run later on that line. A bounded reflow preserves earlier fitting lines and moves the whole rejected line onward without changing source characters or formatting. Native edits and frame-size changes invalidate the measured boundaries; unresolved layout blocks export instead of reporting a fit.

The `text_frames` inventory records frame size, output participation, fit/overset/excluded/unavailable status, source/display ranges, and stable addresses. Hidden, nonprinting and paintless standalone frames remain inventoried but do not block output. Required text masks and effective text/stroke paints are checked. Hidden linked frames retain their existing global story-capacity behavior. This checks frame capacity and typographic advance; it is not an arbitrary occlusion or decorative ink-overhang detector.

Addresses distinguish `publication_page_id` (logical membership), `page_object_id` (affected artboard), and `object_id`/`element_id` (editable source). Legacy issue `page_id` retains its artboard-object meaning. `rendered_element_id` identifies a derived occurrence; master/component source and occurrence IDs are separate. Repeated master applications can produce separate page-specific issues while pointing to one editable original. Component words may be overridden per occurrence even though frame geometry belongs to the source.

Native preflight now provides **Go to frame**/**Go to source frame** actions. Captured project ownership and current rendered-to-source mappings are checked before navigation, so stale reports cannot silently target a different document or a rebound component. Marked input is preserved. Reading preflight does not commit a native draft; the native report explicitly warns when unfinished text may differ from the inspected saved source.

Default PDF export rejects capacity errors for reader pages, reader spreads, booklet sheets, physical editions and outlined text. `allow_overset: true` explicitly permits reviewed partial text, while the returned preflight still exposes the loss. Other errors remain blocking. Resizing the actual frame or editing its source clears the error without deleting any authored text.

The native output inspector now sends the same layout, physical-edition selection, blank-page policy and output intent as MCP. It also exposes effects DPI, text outlines and the explicit reviewed-overflow exception. Appearance proofs are named as proofs and retain their sRGB/nonproduction notice. The existing synchronous compositor/export route remains synchronous; this update does not introduce background export jobs, cancellation, contact-sheet rendering or Studio render/imagegen handoff.

Canvas selection context includes a `publication` relationship with logical page, artboard, printed label and selected story-frame identities. Shared master sources expose all matching master IDs; `master_id` is singular only when unambiguous. A master used by multiple publications reports ambiguity unless the current publication navigator identifies the intended document. Context reads leave navigation, project data, Undo and cameras unchanged.

## Story notes and references

`TextStory.annotations` is optional nonprinting project metadata. Each record is `{id, location, length, kind, body}`: `id` is a stable UUID, `location` and `length` address the original global UTF-16 story text, `kind` is `note` or `reference`, and `body` is literal editorial text. Zero-length anchors are supported. Up to 256 records, 4096 UTF-8 bytes per nonempty body and 65536 total body bytes are allowed; ranges cannot split a surrogate pair. References do not fetch links or create typeset footnotes. Nonempty metadata requires project schema64; older unannotated stories retain their previous schema requirement.

Use `form_story` with `command: "annotation_upsert"`, `story_id` and `annotation: {location, length, kind, body, id?}`. Omitting `id` creates and returns one; supplying it updates that record or inserts a new record with that identity. `annotation_remove` accepts `story_id` and `annotation_id`. `get`/`list` return the metadata on the canonical story. Both native and MCP edits use the same anchor validation and normal project Undo.

Anchors follow their original text: insertion before or at the start shifts the anchor, insertion inside expands it, and insertion at its end stays outside. A point anchor follows insertion at its position. Partial replacement retains an anchor over the surviving/replacement interval; fully removed text leaves a zero-length anchor at the replacement start, retaining its note/reference and ID. `replace_text` uses its exact declared edit. Complete-source replacement infers one changed interval between the unchanged UTF-16 prefix and suffix; callers that know the precise splice can supply `StoryTextEdit` to the shared Core source setter. Native Undo must restore annotation snapshots along with the corresponding text, rather than infer deleted anchor lengths from the restored words.

Notes and references never become characters, printed paint, glyphs or frame copies. Runtime print/layout stories omit the metadata, so adding a note leaves the render-cache identity and exported artwork pixels unchanged.
