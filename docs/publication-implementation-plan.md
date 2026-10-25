# Paragraph language, lists, and publication implementation plan

Status: **Proposed implementation sequence; features below are not shipped.** The current Canvas/Table integration and camera validation remain the immediate integration checkpoint. This plan extends the active [2D specification](2d-design-typography-vector-spec.md), sections 4.7, 10, and Phase 4, without changing its completion requirements.

## Existing implementation and the actual gaps

FORM already stores rich source text, reusable character/paragraph styles, UTF-16 source/display mappings, real font glyph choices, tabs, hyphenation strength, and writing direction. Ordinary text uses Core Text. Text requiring hyphenation uses the cached TextKit composition in `ParagraphLayout`; its actual glyphs feed native drawing, outlines, linked surfaces, and exports. The current paragraph renderer creates one unbounded-height text container per element and clips the visible line range to the frame. It does not share a text story across frames.

`TypographyEngine.attributes` sets paragraph direction and hyphenation strength. It currently assigns no explicit language attribute. `TextCase` uses Foundation's language-neutral uppercase/lowercase properties. `ParagraphCommands` can patch complete containing paragraphs without replacing character styles. Neither the saved model nor those commands contain list structure, an explicit document language, a story chain, page sequence, or baseline grid. Current artwork PDF export writes one frame to one PDF page.

Those existing source-coordinate and rendering boundaries should be extended. A second independent text renderer or generated numbered text pasted into ordinary source would create avoidable editing/export inconsistencies.

## 1. Language and source-preserving locale treatment

First deliver a narrow language milestone before linked frames.

Proposed model: an optional default language identifier on the artwork document and an optional language override in `Typography`, including rich spans and styles. Omitted fields retain existing document behavior. Persist canonical explicit identifiers rather than resolving a system preference into every existing file. Frame defaults and span overrides must participate in layout signatures and native attributed-text roundtrips. Allocate the next schema only when the model patch is ready; do not reserve a number in this plan.

The selected language has three separate effects to verify:

- Core Text localized glyph selection and line-breaking rules. Apple's [`kCTLanguageAttributeName`](https://developer.apple.com/documentation/coretext/kctlanguageattributename) explicitly supports these when the font provides the relevant forms.
- Locale-sensitive case treatment while retaining original source coordinates. Foundation provides locale-taking case APIs, and warns that case conversions can change length. Existing provenance and expansion tests must extend to Turkish/Azeri dotted and dotless I, Lithuanian combining marks, and Greek contextual forms. See [Foundation case treatment](https://developer.apple.com/documentation/foundation/nsstring/localizeduppercase).
- The actual hyphenation dictionary. This needs an implementation probe, not an assumed attribute mapping. Apple's [`NSParagraphStyle.hyphenationFactor`](https://developer.apple.com/documentation/appkit/nsparagraphstyle/hyphenationfactor) documents the first preferred system language. A Core Text language attribute alone must not be presented as proof that native TextKit hyphenation uses the chosen document language.

A small macOS test fixture should compare identical words at identical widths using explicit `en`, `de`, `fr`, and an unsupported dictionary, with different system preferences. Record generated line-break positions, glyph IDs, native/PDF/outline parity, and raw source. If TextKit does not honor explicit language for hyphenation, keep that requirement open and prototype a single language-aware composition backend before exposing a misleading control. Core Foundation provides locale-specific candidate positions and dictionary-availability checks; see [`CFStringGetHyphenationLocationBeforeIndex`](https://developer.apple.com/documentation/corefoundation/cfstringgethyphenationlocationbeforeindex(_:_:_:_:_:_:)). Its UTF-16 ranges must be validated before use.

Acceptance: native language selection, MCP, style inheritance, save/reopen, missing/unsupported language handling, selected-character overrides, Undo/Redo, and physically exported layout agree. Changing a language must never replace source words or detach reusable styles unintentionally.

## 2. Structured bullets and numbered paragraphs

Build lists on the paragraph command boundary. Store list identity, ordered/unordered marker style, level, and numbering restart/continuation as paragraph data. The raw editable source remains the user's words. Generated markers must be represented in the same source/display mapping used by native editing and shaping; their generated status must survive caret movement, selected-character formatting, paste, and outline conversion.

Use [`NSTextList`](https://developer.apple.com/documentation/appkit/nstextlist) and paragraph list attributes as the native interoperability boundary. Verify marker rendering in both the native text view and the production layout path before choosing it as the final shared compositor. The presence of a list attribute is not proof that the current Core Text path renders the same marker. Preserve explicit marker fonts, hanging indents, tab alignment, paragraph spacing, and inherited styles through one layout implementation.

Bound the first milestone to bullets and decimal numbering, start/restart, continuation, and a small validated nesting limit. Native controls should be contextual to selected paragraphs. Return in a list creates a new item; Return on an empty item exits it; indent/outdent and Undo each preserve paragraph identity. Reordering or deleting items recomputes display numbers without editing the source words. Mixed RTL/LTR paragraphs require marker-side and hanging-indent checks.

Acceptance fixture: a preparation checklist with nested bullets and assembly steps numbered across two text objects, including a restarted section. Exercise native input, paragraph selection, rich formatting, copying a list fragment, removing a marker, style redefinition, MCP patches, exact Undo, outlines, and PDF/raster parity. Unsupported marker types are reported rather than silently substituted.

## 3. Shared stories and linked text frames

Introduce a story object as the owner of source text, rich spans, glyph choices, paragraph/list metadata, and language defaults. Frame elements reference a story and an explicit order. Computed displayed ranges stay ephemeral; they must not become independent editable copies of the story.

One story owns one text storage/layout operation and several bounded text containers. AppKit's [`NSLayoutManager`](https://developer.apple.com/documentation/appkit/nslayoutmanager) supports a series of containers and text views. Adapt the shared composition/cache boundary so native editing, overflow indicators, physical surfaces, outlining, and export consume the same per-frame glyph ranges.

Migrate existing independent text lazily when it is linked; merely opening an old file must not reflow it. Validate same-project references, unique frame membership, acyclic ordering, bounded chain length, and clear behavior for deleting/unlinking a frame or story. Linking, unlinking, and resizing are single document Undo operations. A failed agent operation must preserve the active text selection and draft, following the existing paragraph/glyph handoff behavior.

Caret movement across frames, IME composition, text paste, case expansions, forced glyph clusters, lists, and style inheritance need native tests. An overset indicator belongs to the end of the complete story, with a navigation action to the first hidden source position. Reflow should invalidate affected story containers and linked textures, not unrelated artwork.

Acceptance fixture: a four-frame, two-column instruction insert. Increase a paragraph and change a heading style; text must flow in the declared order without lost/duplicated characters. Delete/reinsert a middle frame, undo the sequence, reopen, convert a later frame's displayed text to recoverable outlines, and compare source/display ranges across all outputs.

## 4. Page sequences, baseline grids, and production PDF

Add explicit ordered page membership instead of inferring reading order from physical Canvas positions. Frames keep their physical dimensions and can still be rearranged for design work. A document sequence owns page order, default margins, baseline-grid settings, and reusable page furniture; local exceptions remain explicit.

Export the sequence through the existing physical PDF boundary, with one page per declared frame and correct point-size media/trim/bleed boxes. Preserve page ordering, mixed physical sizes, clipped output roles, and original source. A preflight result must be reviewable before production export and must name the affected page/frame/layer and an actionable issue.

Baseline-grid alignment requires shared line placement, not a decorative grid overlay. Preview, native editing, physical faces, outlines, and PDF must use identical baseline decisions. Start with a document origin/spacing and an explicit paragraph opt-in; preserve manual baseline shifts independently.

Color management, CMYK/spot colors, font embedding permissions, and print-process separations remain distinct Phase 4 requirements. A multi-page PDF alone does not complete production publishing. PDF import as a placed reference and deeper SVG fidelity likewise stay tracked independently.

## Completion and validation order

Each milestone needs a saved model, native controls, deterministic MCP access, meaningful Undo, production-render agreement, and measured behavior on realistic documents. Complete them in the order above; language/list source semantics should stabilize before a story owner and multi-page flow depend on them.

Use the existing isolated-library workflow. Add focused core/rendering/native tests that fail on actual source loss, wrong markers or glyphs, inconsistent page flow, stale linked textures, or physical output errors. Review the final PDF with Poppler and inspect all pages. Measure a sustained edit/reflow workload with the entire relevant story visible and disclose the viewport and caching conditions. A single culled draw sample is insufficient evidence of interactive performance.

The demonstration is an original illustrated instruction booklet, with a multilingual sample page, a numbered assembly procedure, a checklist, shared typography, and precise physical page sizes. It complements the existing wordmark/dial and the developing textile demonstration. The full [implementation goal](implementation-goal.md) stays active until its complete acceptance requirements are demonstrated.
