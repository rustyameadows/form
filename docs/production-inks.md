# Process CMYK and named production inks

Milestone 35 adds real, profile-pinned ink declarations to the project palette and a bounded opaque-vector PDF pipeline. Source geometry, words, rich spans, styles, list markers, exact glyph choices, shared stories, components and physical links remain editable. The complete production-color specification remains open: this checkpoint does not implement transparent spot compositing, image separations, overprint, trapping, screening or PDF/X certification.

## Declare an ink intentionally

Assign the intended **CMYK ICC profile** in the frame's **Color output** section first. Profiles are local user choices; FORM copies the actual bytes into the project, addressed by SHA-256. An installed profile's name does not establish a printer, paper or ink match. The bundled Generic CMYK profile is a conversion study, not a calibrated production condition.

In the shared palette, choose **Set production ink…** or **Edit ink…**. Process CMYK stores four source components; the native fields show percentages. A named spot stores its exact colorant name, tint, four-component alternate appearance and profile identity. The alternate controls composite preview; it does not assert a physical match to an ink. Two swatches may use different tints of the same exact spot name, but their alternate and profile digest must agree. `All`, `None` and the four process colorant names are reserved.

The sRGB chip is derived through ColorSync from the declared values/profile. Screen, Table, SVG and raster previews use that approximation. Editing a HEX value cannot silently replace a production declaration. **Convert to RGB preview** explicitly removes the declaration while retaining its current preview. Referenced ink swatches cannot be deleted or structurally detached until that conversion is explicit. Assigning another swatch is an intentional paint change.

Save commits an active numeric field before reading the declaration. Declaration, conversion and assignment use the same document Undo as native and MCP edits. Palette-only changes preserve unchanged object source files; actual preview-color changes invalidate the affected appearance, while metadata-only intent changes with identical RGB appearance do not rebuild the physical preview.

## Choose the output

The frame's Color output section, and a publication's export section, offer one production-ink output picker and Preflight:

| Output | Encoded result |
| --- | --- |
| RGB appearance preview | sRGB appearance, with an explicit notice that source ink declarations are omitted |
| CMYK + named-spot composite | Actual four-component ICCBased paints and real PDF `/Separation` color spaces |
| Positive digital ink maps | One same-size grayscale page for every process/used spot colorant, for every source page |

Production output uses the physical frame or ordered publication pages, with MediaBox, CropBox, TrimBox and BleedBox. Selected Canvas artwork must have explicit bounds; an unselected infinite workspace cannot become a physical ink page. Ink-map labels live in PDF page-label metadata and the export report, preserving the actual-size artwork without extra printed margins. Maps are page-major: Cyan, Magenta, Yellow, Black, then exact spot names in sorted order.

The flat opaque subset supports vector fills, expanded strokes, live booleans, shared shaped text/list/glyph outlines, affine placement and nested geometric masks, including compound holes. Original text is not rewritten into stored outlines. Raw process components are written unchanged, and a spot tint is written as its actual Separation operand. Composite alternates use the same embedded ICC profile; assigning output metadata alone would not create this behavior.

Each opaque paint uses **normal knockout**. On the maps it paints zero into every other ink, including where a zero-tint spot or a white-alternate spot covers earlier artwork. A spot whose alternate looks white still has a real named map. This is not an overprint preview, physical ink coverage estimate, RIP proof, screening instruction or ink-equivalence calculation. A map's black means the requested digital tint, not a measured deposit of ink.

Preflight blocks images, gradients, partial layer/fill/stroke/background opacity, active blur/shadow, non-normal blends, unsupported masks, unresolved glyphs, missing fonts, overset text, unavailable profile bytes and profile conflicts. Partial opacity is not substituted for a named-ink tint. Every output page and used declaration must use the same verified CMYK profile. The full plan is prepared before an atomic file replacement, so rejection leaves an existing destination intact.

Ordinary PDF routes refuse to flatten declared ink from a physical face or publication. Only inks actually used by visible print artwork trigger this guard; an unused palette entry, mask paint or excluded technical branch does not. Fabric-yardage PDF also refuses declared ink until repeat/colorway-aware production output exists; export the source tile explicitly instead. SVG/raster yardage remain labeled RGB previews. Cutting-layout fabric layers and archived embroidery needle/thread review remain technical references; they do not claim to encode source print inks.

Work budgets are 200 source pages, 100,000 vector paints, 1,000 resulting PDF pages, two million serialized path segments and 512MB output. A larger job must be divided explicitly. No printer, press or embroidery device is contacted.

## MCP

No additional tool is introduced. `form_swatch` accepts `print_ink` on create/update; JSON components and tint use 0–1. Its returned swatch uses the stored `printInk` property. Omit `print_ink` to preserve an existing declaration, or send null to convert explicitly to the RGB preview.

```python
reference = call("form_color_profile", {
    "command": "set", "object_id": frame_id,
    "profile_path": chosen_local_cmyk_profile
})["pdf_output_profile"]

swatch = call("form_swatch", {
    "command": "create", "name": "Studio orange / 50%",
    "print_ink": {
        "kind": "spot", "spotName": "Studio Orange", "tint": 0.5,
        "components": {"cyan": 0, "magenta": 0.65, "yellow": 1, "black": 0.05},
        "profile": reference
    }
})["swatch"]
call("form_swatch", {
    "command": "assign", "object_id": frame_id,
    "element_ids": [shape_id], "swatch_id": swatch["id"]
})
call("form_export_artwork", {
    "object_id": frame_id, "format": "pdf", "ink_output": "preflight"
})
call("form_export_artwork", {
    "object_id": frame_id, "format": "pdf", "ink_output": "composite",
    "path": "/absolute/path/colorants.pdf"
})
```

Use `kind: "process_cmyk"` with four components, no spot name and tint 1 for process paint. `ink_output` also accepts `plates` and `preview`. `form_export_publication` takes the same modes with a publication ID; it preserves physical page order. An explicit output mode cannot be combined with embroidery, sewing-pattern, cutting-layout or fabric-yardage selectors. A preflight response reports actual colorants, physical/plate page counts, verified profile, bounded paint count and element-specific rejection reasons. Exports never mutate the source.

Ink declarations require schema 35; older RGB palettes remain readable without migration. `Artwork.requiresInkOutput` is a derived, non-Codable guard, not a stored document flag. It is excluded from document equality and render definitions, so source persistence, Undo and cache identities do not acquire runtime output state.

## Validation and remaining acceptance

The isolated full suite passes **574 tests**: 414 core/graphics and 160 native-app tests, including 18 production-ink regressions. Coverage includes declaration validation, exact component serialization, same-name conflicts, legacy decoding, atomic rollback, explicit conversion/deletion, source-file/Undo integrity, components/stories, unused/mask/boolean paint detection, RGB-only selections, physical publication order, guarded source/yardage PDF routes, and focused native CMYK Save followed by exact Undo. The native editor was rendered in a hidden test window and visually reviewed; this does not replace packaged computer-use acceptance.

The actual writer's **180×120mm** composite and six ink-map pages, each with **3mm bleed**, were parsed independently with pypdf and rendered by Poppler. Checks inspect real ICCBased/Separation/function resources, profile digest, raw CMYK operands, explicit knockout state, 0/25/50/75/100% tint samples, overlapping inks, nested even-odd masks, an actual Georgia O counter and a white-alternate spot. The [physical proof](images/production-inks-proof.png) and [native editor](images/production-ink-editor.png) come from those outputs; no mockup or external image/model call is involved.

`scripts/smoke_production_inks.py` is the syntax-checked packaged workflow and refuses to mutate an ordinary library. Packaged MCP, native mouse/keyboard acceptance and final combined integration regressions are recorded below. The full color/2D/3D/textile goal stays active.

## Primary references

Adobe's [PDF 1.7 / ISO 32000-1 reference](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/PDF32000_2008.pdf), sections 8.6.6.4 and 8.6.7, specifies Separation tint transforms, special names and knockout/overprint behavior. FORM writes the bounded vector subset directly because Apple's public color-space creation API does not author a named Separation space. [Core Graphics ICC color spaces](https://developer.apple.com/documentation/coregraphics/cgcolorspace/init(iccdata:)) and [ColorSync](https://developer.apple.com/documentation/colorsync) supply profile validation and preview conversion. [Quartz color management](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_color/dq_color.html) explains source/destination spaces; profile assignment, conversion and actual source ink numbers remain distinct.

For a reproducible independent check, run `scripts/verify_production_inks.py` after the guarded packaged smoke. It requires pypdf, Pillow and Poppler, reads the smoke report and outputs, and renders only into a temporary folder. It verifies the actual embedded profile digest, Separation tint transforms, raw CMYK tokens, knockout state, physical page boxes and independently sampled ink maps. It does not connect to FORM or equipment.

## Packaged and native release acceptance

The combined optimized ink and physical-document-review release passes **670 tests: 469 core/graphics and 201 native app**, with zero failures or skips. `smoke_production_inks.py` passes against the packaged 59-tool bridge in an isolated library. The independent verifier passes real ICC/Separation resources, unchanged raw components, physical trim/bleed, spot-tint maps, normal knockout and white-alternate ink. The actual native preflight and Save panel produce a production PDF with those raw CMYK and named-spot resources. Twelve saved palette updates in the linked color-card fixture measure 19.39 ms median and 24.44 ms p95; these are local editing measurements.

Native Save commits every current percentage even while its field is focused. Real keyboard and pointer acceptance verifies Cyan 15.5% and named-spot tint 62.5%, each saved on disk before any MCP read, with one history entry. A single native Undo restores the complete prior project. Invalid 300% remains visible with a finite-range error, and Cancel preserves source/history exactly. Four regression tests invoke the actual SwiftUI Save/Cancel button path, including focused spot names, untouched raw precision, invalid values and reserved names. The camera and existing geometry remain unchanged.

The five ordinary projects and Studio file compare exactly before/after validation. Hardware remains untouched. The broader color, garment, publication and production requirements remain active.
