# Character position and font-authored small caps

FORM has one **Position** control in the text font controls: Normal, Superscript and Subscript. During native text editing it acts on the selected complete characters, or on new typing at the caret. Outside text editing it acts on the selected text sources. A focused size field is committed before the position change. Formatting has native text Undo during editing and one document Undo after the edit is finished. Formatting and source-metadata refreshes preserve a live character selection when its words are unchanged, so the inspector continues to address those characters.

## Authored intent and actual appearance

Position preserves the original words, nominal point size and independent manual baseline shift. It also preserves font assignment, feature requests, dormant variable-axis values, optical policy, reusable styles, case treatment, exact glyph choices and generated list metadata. Linked text frames edit their single shared story; frame geometry remains unchanged. Recoverable text under converted outlines keeps the same source.

FORM first checks the selected face and instance for font-authored superior/inferior forms. A feature declaration alone is insufficient: actual shaped glyphs, advances, positions and bounds are compared for every eligible complete grapheme in a uniform shaping span. If the font does not cover the complete span, FORM uses geometry for that whole span. It never leaves an unsupported letter at body size among smaller letters or splits joining scripts into individually styled graphemes.

The version-one geometric fallback is explicit: **65% of nominal size**, with a **+0.35 em** superscript or **−0.15 em** subscript offset, added to the authored manual baseline. The inspector reports whether font forms or geometry are in use and explains incomplete coverage. Missing fonts retain their original assignment and the existing preview fallback. An exact glyph choice retains its recorded font/glyph identity and uses geometry; FORM does not reinterpret its glyph ID as a superior or inferior glyph.

Automatic optical sizing follows the actual rendered source point size: nominal points for font-authored forms, 65% of nominal points for geometric fallback. Physical millimeter layout and Canvas zoom do not change that optical context. Explicit/off/legacy optical policies retain their existing precedence. Font-only changes preserve stored axes and position intent; incompatible assignments remain reportable rather than silently rewritten.

Generated bullets and numbers retain the nominal marker font and align with the actual unpositioned body baseline. Raising the first word does not shrink or lift its list marker.

## Legacy features, styles and small caps

Omitting `Typography.characterPosition` preserves legacy font construction and raw vertical-position feature requests exactly. Explicit Normal suppresses vertical forms for display while keeping the raw source requests dormant. Setting the optional field to null restores legacy feature behavior. Intentionally editing raw feature type 10 clears semantic position; font-only and unrelated style edits do not. Existing font-specific vertical variants share the same Position control. There is no second competing superior/inferior control.

Small caps remain in the existing font feature controls. FORM uses actual supported lowercase/uppercase small-cap features, including applicable legacy selectors; it never manufactures them by uppercasing and shrinking text. The inspector distinguishes complete, partial, unavailable, inapplicable, work-limited and exact-glyph-overridden coverage. Unsupported characters keep their original forms and the source request remains recorded. Case conversion and exact glyph identity remain independent.

Position participates in reusable character styles, local overrides, style reset and shared publication stories. Transient rendering records separate derived appearance from nominal source values during native `NSTextView` round trips; those records are not encoded in project files. Schema **47** is required only when a non-null semantic position exists, including unused styles and hidden recoverable source. Small-cap requests use the existing feature model.

## Physical output and preflight

Native text, physical PDF, text outline conversion and SVG use the shared shaping/composition pipeline. SVG requests for live text use outlines where character forms or small caps require faithful composition, with explicit export counts and warnings; original FORM source remains editable. Publication preflight reports fallback and incomplete small-cap coverage for shared stories and independent page text. This does not install fonts, claim font portability, or change unsupported assignments.

TextKit fallback-font identity follows supplied source character indices and retained glyph/property/font evidence. This matters when Arabic shaping inserts glyphs or Indic/combining shaping hides null glyphs. Paragraph and story outlines skip actual `notShown` glyphs. If conflicting font identities cannot be resolved for a physical glyph, export fails explicitly instead of choosing a face. Genuine visible glyphs without vector outlines still require a different font or a suitable raster workflow.

Coverage work is bounded: 4,096 UTF-16 units per span, 256 complete graphemes per span, 128 UTF-16 units per grapheme, and 2,048 grapheme checks per composition call. Exceeding the position budget applies geometry to the complete span without truncating words; small caps stay requested and are reported unreviewed. The font-coverage cache is bounded to 512 entries and 2 MB. Position commands accept at most 256 unlocked text targets and one million aggregate UTF-16 units; positioned source permits at most 4,096 authored rich spans. Font/font-database invalidation clears coverage caches.

## Existing MCP routes

Use `form_edit_artwork` with `command: "character_position"`, a text selection and `position: "normal"`, `"superscript"`, `"subscript"` or null. Optional `location` and `length` are source UTF-16 values; both are required together and must enclose complete nonempty graphemes. Fractional, Boolean, partial-cluster and invalid values reject atomically. Existing `form_text_style`, `form_set_artwork` and `form_story` routes retain their source/style/story semantics; no new tool is added.

```json
{
  "object_id": "…",
  "element_ids": ["…"],
  "command": "character_position",
  "position": "superscript",
  "location": 1,
  "length": 5
}
```

The guarded `scripts/smoke_character_position.py` exercises the packaged MCP workflow only when the app reports a disposable library below `.local`. The signed integrated build passes the separate visible Position, focused typing, selected-character Undo/Redo and actual process-reopen checks. See [native evidence](evidence/character-forms-native.json) and the [physical live/outline proof](images/character-forms/physical-proof.pdf).

## Technical sources

The behavior follows measured installed-face shaping and the public [Core Text superscript attribute](https://developer.apple.com/documentation/coretext/kctsuperscriptattributename), [OpenType superior/inferior/small-cap feature definitions](https://learn.microsoft.com/en-us/typography/opentype/spec/features_pt), [NSLayoutManager glyph/font/source-index callback](https://developer.apple.com/documentation/appkit/nslayoutmanager/setglyphs(_:properties:characterindexes:font:forglyphrange:)) and [actual hidden-glyph query](https://developer.apple.com/documentation/appkit/nslayoutmanager/notshownattribute(forglyphat:)). Font-authored coverage is measured on the local font instance rather than inferred from these API declarations.
