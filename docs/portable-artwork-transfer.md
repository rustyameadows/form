# Portable artwork transfer

Copy, Cut and Paste carry editable artwork and its closed resource graph between FORM projects. They retain existing Mac key bindings. Paste uses the existing **10 mm offset in artwork/world coordinates**, including inside a transformed destination group.

The portable record includes selected descendants, required ancestor shells and sibling masks; nested component definitions; named styles/swatches; rich text, lists, glyph/font fingerprints and optical settings; exact original image/ICC bytes; and supported complete unbound sewing pairs. References use typed, owner-scoped UUID maps. Names, notes and source words that happen to contain UUID strings remain unchanged. Source frame context travels in the record; a layer paste preserves destination frame settings. Imported complete component definitions keep their own context and dimensions and are reported as explicit new source objects.

Copy prepares and validates the complete record before taking pasteboard ownership. A failed Copy cannot delete its source through Cut. Successful Cut uses one shared Undo. Paste validates before ending an active editor, stages resources, then commits the editor and **replans against the newly committed destination**. A project-lifetime token and native frame/scope cancellation reject context changes during staging, including switching away and back to the same project. Cut verifies both the selected object and canonical owner are unlocked before publishing Copy. A lagging text draft is retained; Undo of Paste returns to those committed words. Invalid payloads, resources and initial contexts leave the current editor/caret intact. Export reads committed project source without committing pending drafts.

## MCP file route

These are commands of the existing `form_edit_artwork` tool; no new tools or camera controls are added:

```json
{"command":"transfer_export","object_id":"SOURCE_UUID","transfer_path":"/absolute/new.formart","element_ids":["LAYER_UUID"]}
{"command":"transfer_import","object_id":"TARGET_UUID","transfer_path":"/absolute/new.formart","scope_id":"OPTIONAL_GROUP_UUID","offset_x":10,"offset_y":10}
```

Export `element_ids` is optional: omission explicitly captures the complete source scope, including hidden layers. Native Copy always supplies its selection. Import accepts an optional editable group and paired physical offsets; omission means 10 mm in both axes. Import rejects `element_ids`; export rejects import-only arguments. Unknown keys and malformed IDs reject. Exports refuse an existing output, even if identical.

Both file commands require an absolute `.formart` path. Output publication never overwrites a caller's existing file or uses a staging journal's reserved filename.

The existing `command:transfer` still moves artwork between frames in one project with its original `target_object_id` and offset semantics. Portable file calls are distinct and reject inside `form_batch` before editor handoff: that batch's model rollback cannot reverse external file publication.

Imports return selected IDs, explicit component source IDs, imported/published/reused asset names, a journal location, decoder metrics, opaque provenance names and missing-font assignments. Source font metadata is preserved; no font files are copied or substitute outlines fabricated. Review unavailable faces before output.

## Bounds and formats

`FORMART1` is an uncompressed envelope: an eight-byte magic, a four-byte big-endian metadata length, JSON metadata and length/SHA-256 checked raw blobs. It has no archive decompressor. Metadata is capped at 2 MiB; elements/dependencies 2,048; component definitions 64; styles/swatches 256 each; assets 32; individual raw assets 16 MiB; total raw assets 32 MiB; hierarchy 32; component nesting 8; source-owner lookup 10,000 objects; traversal 200,000 units. The binary file cap is 34 MiB plus its 12-byte header. Counts, pending traversal and byte lengths are checked before typed decoding/copying.

Rendered raster references are limited to 32 frames, 8192 pixels/edge, 16 megapixels/frame and 32 megapixels across a transfer. Metadata checks precede bounded thumbnail decoding. ICC bytes must match their declared SHA and actual RGB/CMYK model.

Direct SVG image references use a bounded plain-vector profile: shapes/paths, groups, gradients and geometric masks; at most 2 MiB, 4096 XML elements and 20,000 decoded path nodes. Active/external content, text, images, use, filters and unsupported styles reject. Original SVG bytes are preserved; unsupported content is not silently substituted.

Direct PDF image references initially support only a flat, uncompressed, single vector page up to 256 KiB, with finite dimensions up to 1000 mm/edge. Compressed/resource-rich/active PDFs reject before CoreGraphics parsing. The public SDK exposes no bounded stream inflater or scanner cancellation; this boundary avoids claiming support for arbitrary PDF complexity. No raster substitute is generated. PDF/SVG originals used solely as import provenance remain opaque exact bytes and are not exposed to the renderer.

These bounds describe input/work/pixel budgets, not total process memory or fixed latency guarantees.

## Explicit unsupported contexts

Partial continued lists reject rather than baking visible numbers into restarts. Story frames and publication pages require a complete publication transfer that this route does not yet provide. Managed garment bindings, material-bound sewing pieces and cutting layouts reject. Half-seam transfers reject; supported complete unbound pairs retain typed edge identities. Original-file import provenance requires its complete source scope.

Legacy converted outlines keep recoverable originals as unreferenced hidden siblings. An ambiguous partial path selection rejects with a request for its complete enclosing scope. No display-name heuristic or silent inclusion of unrelated hidden content is used. Ordinary typed content is not blanket-rejected because a hidden layer exists. Nonempty destination language/output intent must match; an empty destination adopts that source intent.

A newer persistence schema rejects until its actual model is known to the receiving build. Version compatibility must advance alongside merged source fields; newer source is never deliberately stripped to fit an older model.

## Publication and recovery

Original files are read through bounded descriptors with no-follow checks. Staging uses a private directory and exclusive file creation; destination publication uses exclusive hard links. Existing bytes are verified/reused or rejected. A published pathname is **never unlinked or replaced** by this transaction.

If a race or stale document fails after some assets were published, the document remains unchanged and bounded content-addressed files may remain as **unreferenced recovery assets**. The error reports verified retained names/bytes, separately identifies externally replaced paths, and points to append-only journals. Retry reuses matching content. Only owned unpublished links are cleaned through the retained staging-directory descriptor; replacing its public directory name cannot redirect cleanup. Journals and their directory remain for diagnosis. No cleanup UI or global collector is added.

Undo also retains imported bytes for Redo/recovery. Atomic exclusive visibility and requested fsync ordering do not promise hardware power-loss durability across every filesystem.

## Validation

Tests use `NSPasteboard.withUniqueName()` and injected native publication; validation never reads or writes the human clipboard. Actual AppKit menu/key events exercise Copy→switch project→Paste, failed Cut publication, active unpublished text/caret preservation, fresh post-handoff replanning, exact one Undo, source-image deletion, resource retention and save/reopen. Failure tests inject staging errors, mid-publication collisions, foreign replacement, directory replacement and document staleness.

Core physical proofs delete the original image directory between capture and render. Independent PNG pixels, Poppler PDF pixels, PDF MediaBox/content streams and SVG geometry/embedded bytes match. A guarded packaged workflow is available as `scripts/smoke_artwork_transfer.py`; it requires `FORM_TRANSFER_TEST_LIBRARY` to exactly match an active disposable `transfer48` library below `.local/validation` and uses only file-based MCP operations.

The isolated production checkpoint passes 866 optimized tests: 587 Core/Graphics and 279 native, including 31 new transfer regressions. The real stdio helper is exercised through a private asynchronous bridge with a disposable library. Its workflow exports, deletes the original asset, imports into another project, verifies original bytes and independent component links, then checks Undo/Redo, invalid/batch rollback and saved reopening. No installed app or default socket is involved.

One optimized native image fixture measured 27.5 ms Copy and 63.2 ms Paste for a 1,212-byte bundle containing a 176-byte original PNG. This is a small fixture measurement, not a latency guarantee. The physical proof is a 200 × 150 mm composition containing a rotated group, ellipse mask, opacity, image crop and original image bytes; separate regressions and the MCP workflow cover rich text and components. [Before PNG](validation/portable-artwork-transfer/before.png), [after PNG](validation/portable-artwork-transfer/after.png), [physical PDF](validation/portable-artwork-transfer/after.pdf) and [independent verification](validation/portable-artwork-transfer/independent.json) are retained with the checkpoint.

The integrated application now passes **983 optimized tests (640 core/graphics/IPC + 343 native)**. Seven held-staging native lifecycle regressions cover frame/scope round trips, project A→B→A, Home, late target locking and an unchanged-context control. Additional regressions retain schema47 typography and schema49 destination page intent, preserve a locked Cut source/private board, and reject guide-only fast paths for real typography edits. The installed signed app passes the guarded file-based MCP export/import workflow, including deleting original image files before Paste, exact bytes/components/UUID remapping, Undo/Redo, rollback and reopen. Validation uses private pasteboards; the human clipboard is untouched. [Combined acceptance](evidence/transfer-page-native.json).
