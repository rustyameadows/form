# Physical page setup

On an unlocked independent rectangular artwork frame, **Page setup** has separate Bleed and Safe inset drafts. **Apply page setup** commits them together with one Undo. Review and output choices do not apply pending source fields or finish another text/path editor. The first workflow excludes freeform Canvas, element selections, irregular frames and linked product projections; existing export routes remain available.

Bleed is an **outward** extension of the exact trim rectangle. Safe inset is an optional **inward** rectangular guide; blank removes that declaration and zero explicitly declares zero. It is not a dieline offset, printer capability or production guarantee. Canvas shows bleed in red outside trim and safety in green inside. Source coordinates and nominal physical size stay unchanged.

Inputs accept the current physical unit or explicit mm, cm, in or pt suffixes. Untouched fields retain their exact underlying values. Clean drafts follow Undo, including a focused clean field; dirty/invalid independent drafts survive. If the document unit changes while a draft is independent, its displayed input unit retains its meaning until it is applied or reset. Invalid values remain visible and reject without writes. Bleed is finite 0–25 mm; safety must be nonnegative and leave a nonempty frame interior. A resize that would invalidate safety rejects instead of clamping it.

## Review and production PDF

**Review physical page** uses the shared vector PDFKit viewer with fit, zoom, drag/scroll pan and pinch. Trim only / Include bleed and optional crop marks are local output options. Gap and length are actual millimeters; Refresh review validates the active strings. Editing either field makes the existing proof stale and disables Export until refresh. Output notices retain font, optical-sizing, character-position and small-cap warnings from the shared export pipeline. Reference guides are optional colored sRGB overlays with a legend. Pending source/editor drafts are not committed or included by this read-only review.

**Export production PDF** independently renders applied source and output choices through the same geometry. It never exports the reference-view buffer or its trim/bleed/safe overlays. The PDF preserves vector text/paths, supported images/effects and source alpha; its background is painted once. An assigned portable ICC profile is applied to actual production colors. Declared process/spot inks require an explicit sRGB appearance-preview choice here; named ink/plate production remains the established separate workflow. Original source declarations remain unchanged, and unused ink declarations do not block a page.

PDF Media/Crop/Trim/Bleed boxes describe actual included content. Trim only includes zero bleed even when source declares bleed. Crop marks are eight independent 0.25 pt butt-capped segments outside the included bleed, with default 1 mm gap and 3 mm length plus 1 mm outer tip clearance. Gap supports 0–25 mm and length 0.1–25 mm. These are FORM defaults, not equipment requirements; no registration targets, color bars, imposition, printer nonprintable limits or PDF/X certification are supplied. A safe guide is not encoded as ArtBox.

Complete media is limited to 5080 mm per side without UserUnit scaling. Source geometry is never resized to fit. PDF effects resolution uses 36–1200 DPI independently of viewer zoom. Pre-render work caps are 5000 resolved elements, one million aggregate UTF-16 units, 16,384 rich spans, 250,000 vector nodes and 128 image declarations; full shared-story source counts conservatively for each referenced frame. Rendered images are regular project assets up to 32 MB each and 128 MB total before decoding. The review signature is bounded to 16 MB. These source/file/effect limits do not claim a fixed total process-memory ceiling.

## Existing MCP routes and compatibility

Use `form_edit_artwork` with `command: "page_setup"`, `object_id`, numeric `bleed` and/or numeric-or-null `safe_inset`. No element selection is accepted. Empty/unknown/Boolean/nonfinite/invalid-owner inputs reject before editor handoff. Valid native and MCP edits share the source operation and one Undo.

Use `form_export_artwork` with an explicit `page_output` object:

```json
{
  "object_id": "…",
  "format": "pdf",
  "page_output": {
    "area": "bleed",
    "crop_marks": true,
    "mark_gap_mm": 1,
    "mark_length_mm": 3
  }
}
```

`format: "preflight"` returns actual boxes, crop bounds and source workload without a file, input handoff or history. Its scope is source/selector/geometry validation; it explicitly leaves appearance/assets unverified until PDF rendering. It does not claim missing resources or fonts are production-ready. Selections, roles, sewing/pattern/layout/embroidery selectors, unsupported page-option keys and unimplemented ink modes reject rather than falling back. No new tool is added. All exports without `page_output` retain their original defaults and dimensions; older captured PDF bytes are untouched.

Only a stored optional `Artwork.safeInset` requires schema 49. Omission preserves legacy storage. Whole source/frame records preserve page intent; cropped element exports clear this frame-only safety declaration, and a scaled product projection does not acquire its source frame's safety claim. Guide values are excluded from physical render signatures. Exact-field metadata/history refresh preserves active cloth and evicted assembly caches; a runtime-only identity ignores only these two nonprinting page fields. Authoritative generator/product/preparation/archive/stale source guards remain exact. Real pattern, paint, geometry and physics edits retain invalidation.

The guarded `scripts/smoke_page_setup.py` is for a disposable `.local` packaged acceptance library. Integrated acceptance passes 983 optimized tests and the installed MCP workflow. Actual computer use verifies focused Apply without Tab, exact Undo/Redo, invalid draft retention, clearing safety, dirty-review export blocking, Refresh, four-direction PDF pan and native Save-panel export. Independent PDF parsing and rendered inspection verify a 200 × 150 mm trim on a 228.25 × 178.25 mm sheet, eight 0.25 pt marks, and no printed reference guides. Native and MCP decoded page content match exactly. Actual process restart preserves the entire page and prior collection project; ordinary projects/settings remain exact. [Evidence](evidence/transfer-page-native.json). This integration does not complete or restart the broader feature roadmap.

## References

The outward bleed/mark separation follows Adobe's [printer-mark guidance](https://helpx.adobe.com/indesign/desktop/print/page-set-up-and-printer-marks/set-printer-marks.html) and [bleed-area guidance](https://helpx.adobe.com/indesign/desktop/print/page-set-up-and-printer-marks/print-bleed-and-slug-areas.html). [W3C Paged Media bleed](https://www.w3.org/TR/css-page-3/#bleed) supplies the conceptual outward clipping model; it is a working draft, not a PDF conformance claim. Actual page boxes and crop strokes are independently inspected from saved PDFs.
