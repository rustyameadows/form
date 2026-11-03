# Publication workflow refinement — 2 November 2026

This pass addresses discoverability and everyday magazine authoring on top of the existing shared page/story/master and physical-sheet model. The editable 52-page issue remains the native review document; its existing artwork and saved scenes are preserved.

## Changes in this pass

- **Pages stays discoverable.** A labelled Pages action appears beside the Canvas/Table view chooser in publication projects. View → Publication Pages (⇧⌘P), the workspace menu and the existing Canvas tool all reach the same navigator. Opening it retains split direction and the current page and clears an obscuring Canvas Find panel. Layers and Pages controls reflect the panel actually on screen.
- **Navigate by the printed folio.** The navigator shows the selected spread's labels, accepts printed numbers and cover labels, disables unavailable previous/next actions, and follows the selected page when reopened or when thumbnail grouping changes. Its settings action explicitly addresses the navigator's document, even after another object was selected.
- **Inspect a page directly.** Selected-page controls expose label, inherited/overridden chapter title, numbering restart and automatic/explicit master assignments. Chapter and master inventories are collapsed by default. Edits capture project, publication and logical-page identities so stale callbacks cannot change an imported copy or replacement page.
- **Add capacity to the right chapter.** Adding a page follows an explicitly selected story or the sole story on the current page, preserving regular columns and gutter. A cover or an ambiguous multi-story page does not silently extend an unrelated chapter. New capacity inherits the adjacent page's background transparency and output intent rather than introducing an opaque cream print rectangle.
- **Reuse correct thumbnails.** Bounded transient previews retain actual stock color and opacity, composed cross-gutter crops, shared story/master content, font state and referenced raster contents. Preview substrate stays outside production artwork. Cache reuse reduces repeated rasterization; no maximum-document responsiveness claim is made.

## Remaining product work

These are real gaps, rather than claims of complete desktop-publishing coverage:

1. **Automatic pagination.** Linked source flows through existing frames and preserves overset text. Adding/removing pages automatically to fit edited copy, with explicit cover/chapter/stock rules, is not implemented.
2. **Document-wide layout changes.** Existing frames retain physical coordinates after margin changes. A previewable resize/recolumnize operation with local overrides would make large format changes easier.
3. **Larger structural edits.** Page moves are currently single-step commands; bulk selection, drag reordering and richer section management would improve long documents.
4. **Production feedback.** Preflight should provide a scrollable, actionable issue list that locates affected pages/frames. Long native preflight and PDF exports still need progress/cancel feedback.
5. **Broader imposition and book production.** Current exact two-up folded-sheet output and explicit parent-sheet stock are exercised by the magazine. Rich multi-signature planning, creep compensation and press-specific marks are further production work. Geometry does not simulate paper mechanics or establish manufactured binding strength.
6. **Editorial automation.** Generated contents/indexes, footnotes/endnotes and maintained cross-references need dedicated document primitives and editing flows.

The next highest-value authoring work is overset-driven pagination and bulk page/section manipulation. The next production work is actionable preflight and explicit signature planning. These should continue to use the canonical page/story sources, with Canvas spreads and physical/print arrangements derived from them.

## Validation

Focused native tests cover navigation/source preservation, chapter-local capacity, transparent K-only stock, page metadata/stale targets and thumbnail invalidation. The final AppKit-host gate passes **235 tests**; **45 offline Python tests** also pass. Native review found and corrected two further issues: a far-page jump did not reveal the selected thumbnail, and the settings shortcut did not scroll past general artwork controls. Mounted native tests now exercise both visibility conditions. A further **25 focused UI checks** pass after the final picker-label/accessibility polish. Native review verified the visible Pages button and shortcut, printed folio38 jumping, selected-thumbnail visibility in both grouping modes, direct publication-settings reveal and Find→Pages handoff. The reviewed magazine’s canonical artwork, publication records, stories, styles and saved Studio compositions remain byte-equivalent to the pre-test public snapshot.

The final signed build was installed and verified after the desktop was unlocked. [Native UI screenshot](images/publications/refinement-native-ui.png) and its [source/app evidence](images/publications/refinement-native-evidence.json) record the completed check.
