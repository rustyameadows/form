# Paper acceptance addendum

The existing twelve-case paper project remains the baseline. Two supplementary studies close the missing screen-print and combined invitation-suite demonstrations; they are ordinary authored project data, not application object types or registered generators.

- **13 / Common ground:** a 297 × 420 mm recycled-paper poster with three editable ink groups, three screen-print assignments and coincident registration crosses in every plate. Forest, clay and ochre remain distinct source colors. Stock caliper, texture scale and texture depth use the existing generic physical controls.
- **14 / Gather:** one saved composition combines an independently authored copy of the invitation envelope, the existing real separate liner and finished invitation with a new double-sided response card. The suite envelope owns a clean inside artwork source so the vellum liner does not reveal the baseline study’s oversized inside prototype text. The original envelope stays exact. Presentation instances move these sources without rearranging or copying the original twelve objects. Letterpress, blind emboss and foil remain the invitation's existing source-linked finishes. The response card is a separate generic flat sheet. The declared rotated paper-size clearance is an assumption, not a manufactured fit or envelope-insertion simulation.

Use the one ordinary LAB app, with the accepted twelve-study project already open:

```sh
python3 scripts/extend_paper_acceptance.py \
  --app /absolute/path/to/LAB.app \
  --socket /tmp/form-501.sock \
  --seed-report /absolute/path/to/twelve-study/report.json \
  --output /absolute/path/to/acceptance-addendum \
  --render
```

The script never launches or stops an app. It requires that the active project match the supplied report, checkpoints its new object IDs and leaves the seed report's twelve cases untouched. A rerun resumes those same supplementary objects. All design changes use existing public construction, paper, artwork, scene and Undo commands; no project JSON is edited behind the app.

Poster typography uses point-sized fonts inside physical millimeter frames; per-heading SVG glyph checks reject empty/overset titles. Existing addenda receive the same source-ID-preserving typography repair on replay.

The checks cover distinct ink targets, common registration coordinates and physical SVG extents, actual packet artifact hashes, source IDs, exact Undo/Redo for dimension and finish edits, save/reopen and preservation of every pre-existing object. `--render` adds native 2000 × 1600 whole/detail captures plus decoded pixel populations for all three poster inks; Pillow is required for that decoded-image check. The ordinary source-artwork SVG in an embroidery manufacturer's packet is separately covered by `TextileProductionEditingTests` and [textile production jobs](textile-production-jobs.md).

A successful script result deliberately remains **visual review pending**. Inspect the actual poster, grain/ink close-up, full suite and invitation detail; revise the authored scene/artwork if it does not look good. Valid geometry, source metadata, file sizes and pixel counts do not establish paper texture, relief or production quality. The example JSON and replay script are inputs; captured images and native request/response records are the evidence. No machine is contacted and no press/tooling or sew-out verification is claimed.
