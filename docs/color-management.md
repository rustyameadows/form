# ICC output profiles

Status: source, packaged MCP, and native computer-use checks pass in the integrated schema-30 build. The complete production-color checkpoint remains open.

FORM artwork uses **sRGB** for editable HEX colors, native Canvas composition, and Table previews. A frame or shared artwork source can carry an independent **PDF output profile**. Assigning that profile preserves the source color values and the screen appearance. Export performs a conversion to the chosen output space. It does not relabel the source RGB components as CMYK.

With no layer selected, open **Color output** in the Canvas frame inspector. Choose an installed RGB/CMYK ICC profile or import a local `.icc`/`.icm` file. A linked product inherits its artwork source's assignment. **Preserve source sRGB** clears the PDF conversion. Profile assignment and removal share document Undo. The chosen bytes travel inside the project under a SHA-256 asset identity; another Mac does not need the same installed profile. Missing or mismatched profile bytes stop PDF export before replacing the destination.

The conversion applies to artwork PDF, separate production-role PDF pages, ordinary physical-face PDF, and publication PDF. A publication requires the same profile identity on every page when a profile is assigned; conflicting or missing assignments require an explicit choice before export. SVG, PNG, and JPEG remain sRGB. Technical cutting, sewing, and stitch outputs retain their separate output semantics.

Apple's [ColorSync framework](https://developer.apple.com/documentation/colorsync) supplies the color-management engine. FORM uses the public [QuartzFilter output-intent initializer and PDF-context filter](https://developer.apple.com/documentation/quartz/quartzfilter) to convert actual text, vector paths, shadings, and image samples. The converted PDF embeds an [ICC destination output profile](https://developer.apple.com/documentation/coregraphics/kcgpdfxdestinationoutputprofile). An output-intent label by itself is insufficient: the implementation probe demonstrated unchanged RGB components until the conversion filter was applied.

Installed profile names do not establish a production condition. **Generic CMYK Profile** is useful for inspecting conversion. Choose the actual profile supplied for the intended printer, press, ink, and paper when preparing production files. This milestone does not certify PDF/X compliance, overprint, named spot separations, total ink limits, a calibrated soft proof, or physical color matching. Native CMYK/spot source editing and the remaining specification requirements are still in scope.

## MCP

`form_color_profile` uses `command: list` by default to discover local supported profiles. `get` reads a source assignment; `set` imports a local profile; `clear` removes the assignment. List/get preserve an active native editing draft. Set/clear commands support atomic `form_batch` operations so a publication’s page assignments can change together.

```python
profiles = call("form_color_profile")["profiles"]
call("form_color_profile", {
    "command": "set",
    "object_id": source_or_linked_product_id,
    "profile_path": chosen_profile["path"]
})
call("form_export_artwork", {
    "object_id": source_or_linked_product_id,
    "format": "pdf", "path": "/absolute/path/printed-artwork.pdf"
})
```

ICC imports accept RGB or CMYK output-capable profiles up to 16 MB. Saved references contain a human name, model, asset filename and digest; source geometry/text/colors remain independent. PDF exports report the applied profile identity and output model. Changing only the output assignment is excluded from the Table render signature.

## Validation

Five focused core/graphics tests and four native domain tests pass. They check portable bytes, malformed and missing assets, reference integrity, source preservation, render-definition equality, shared Undo, linked-source assignment, atomic multi-page profile rollback, schema-30 package reopen, physical-page boxes, and failed-export destination preservation. The actual two-page converted PDF retains vector fills/strokes, gradient shadings, selectable embedded subset Georgia text, and images with independently inspected **four-component** image profiles. Both page dimensions and TrimBoxes remain unchanged. RGB Display P3 conversion is separately checked. The output was rendered with Poppler and visually inspected.

`scripts/smoke_color_profiles.py` passes against the packaged app in a disposable library. It refuses to mutate the ordinary library and verifies real tool discovery, linked-source assignment, source-only package writes, zero geometry rebuilds, unchanged screen pixels, Undo/Redo, actual CMYK vector paint, physical exports, and schema-30 reopen.

Native computer use assigns and clears Generic CMYK, verifies both changes directly in the saved object files before any MCP readback, and restores exact artwork/history with two document Undo actions. The linked-screen PNG remains byte-identical and geometry builds stay at4 through profile assignment; actual PDF vector paint and embedded image samples are CMYK. Native source composition and all color values remain sRGB.


## Declared CMYK and named spot inks — milestone 35

The [production-ink workflow](production-inks.md) now separates raw, profile-pinned process/spot declarations from their ColorSync-derived sRGB preview. Explicit composite PDF writes ICCBased process colors and genuine Separation resources; positive digital maps preserve opaque normal knockout and physical page boxes. Existing RGB conversion remains available. Declared ink is never silently passed through the ordinary RGB-to-profile conversion route. The initial production subset rejects images, gradients, transparency/effects and non-normal blends; overprint, trapping, screening, physical ink equivalence and PDF/X remain open. See the linked guide for schema35, exact native/MCP behavior, limits, physical proofs and pending packaged acceptance.
