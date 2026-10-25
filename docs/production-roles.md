# Production roles

One artwork source can produce printable graphics and separate manufacturing geometry. Roles are explicit metadata; a layer's color never determines whether it is printed, cut, scored, stitched, engraved, or used as a guide.

## Native workflow

Select layers and open **Production role** in the inspector. Choose **Print artwork**, **Cut**, **Score**, **Stitch**, **Engrave**, or **Guide**. **Inherit** clears the local assignment; the default is print. Assigning a group sets its role and clears descendant assignments so its entire branch inherits that purpose. A non-print ancestor controls the complete branch, including older conflicting child assignments. The inspector identifies that controlling group and can select it. Change the group's role before assigning a different role to a child.

This preserves the earlier behavior of construction groups: their descendants cannot leak into printed output. The legacy `artwork` value remains a print alias. Explicit `print` assignments use schema 22; older files retain their existing rendering.

**Production overlays** in the frame inspector independently show or hide cut, score, stitch, engrave, and guide content. These are local viewing choices; they do not change saved roles, document history, or output selection. Hidden overlays cannot be picked on the canvas. Printed physical surfaces continue to exclude technical geometry and guides.

In the artwork **Export** popover, choose an output role. SVG/PDF also offer **Separate production roles**, which includes print, cut, score, stitch, and engrave while excluding guides. Empty technical roles are omitted. **Guide reference** is an explicit separate choice.

## Output behavior

- **SVG:** Millimeter dimensions and a matching physical viewBox. Each requested role gets a named SVG layer with `data-form-role`, an Inkscape layer label, and JSON role metadata. Repeated ancestor/clip/gradient IDs receive role-specific prefixes so shared compound masks remain valid across layers. Technical text is outlined for portability.
- **PDF:** One page per requested nonempty role at the same exact physical size. Document metadata records the role/page order. Page content retains original vector geometry, clipping, and transparency; technical pages do not acquire the print background. Guide pages require explicit selection.
- **PNG/JPEG:** One role at a time, at the chosen physical DPI. SVG/PDF preserve separate roles when exporting several together.
- **Selection export:** Only selected content participates. Output bounds follow visible geometry in the chosen roles; unrelated guides cannot enlarge a print selection. Ancestor transforms, group appearance, compound holes, and clipping dependencies remain intact.

Cut, score, and stitch outputs require vector geometry without images, blur, or shadows. An incompatible layer produces an error before an existing output file is replaced. Engraving may retain raster artwork. Roles describe design intent; these exports do not calculate feeds, power, tool compensation, or digitized machine stitch programs. No hardware is contacted.

## Local MCP

Assign the same roles through the shared native command engine:

```json
{"name":"form_edit_artwork","arguments":{"object_id":"FRAME_UUID","command":"production","element_ids":["GROUP_UUID"],"role":"cut"}}
```

Use `"role": null` to clear selected roots and their descendants to inherited/default print. Locked descendants block the entire group change. A conflicting role beneath a non-print ancestor is rejected with the controlling group's name. Native edits, MCP changes, linked source ownership, atomic batches, and Undo share this behavior.

Choose explicit output roles:

```json
{"name":"form_export_artwork","arguments":{"object_id":"FRAME_UUID","format":"svg","roles":["print","cut","score"],"path":"/absolute/path/package-production.svg"}}
{"name":"form_export_artwork","arguments":{"object_id":"FRAME_UUID","format":"pdf","roles":["print","cut","score"],"path":"/absolute/path/package-production.pdf"}}
```

The response includes physical dimensions, the exported `roles`, and `role_pages` with page numbers and visible element counts. Existing callers that omit `roles` retain printable-artwork export behavior. Guides are never implicitly added to production output.

## Validation

`ArtworkProductionTests` covers legacy rendering, parent gating, recursive assignment, locked/invalid rollback, transformed shared masks with compound holes, unique SVG references, PDF role ordering and physical dimensions, selection cropping, and schema-22 reopen. `ArtworkProductionEditingTests` covers native/MCP Undo, failed batches, linked source edits, real output files, failure without replacing an approved file, and native overlay picking with exact document/history preservation.

Run `python3 scripts/smoke_production_roles.py` against an isolated packaged app to create **PRESS / Separate by intent**. It exercises all five manufacturing channels, shared compound masks, linked-source-only persistence, group assignment, canonical-source locking, invalid-batch rollback, exact Undo/reopen, physical SVG/PDF/raster outputs, actual SVG IDs/metadata, and Poppler PDF dimensions. The ordinary default print-export path is checked separately.

Broader color-managed preflight, machine-specific processing, output-profile separations, and the remaining production overlays in the [implementation goal](implementation-goal.md) remain separate work.
