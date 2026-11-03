# VARIOUS / Issue 01

An original, editable 52-page quarterly magazine, **Small adjustments**. The six studio identities are fictional editorial families. Its text, models, process illustrations and layouts were authored for this LAB study; the photographs are actual native Studio stills of the authored digital objects.

The issue contains **48 numbered interior pages, four cover faces, 6,542 editorial words and 110 visual placements**. Those counts include the approved one-sentence caption correction recorded in [editorial-revision.json](editorial-revision.json). The source copy, section order, visual keys and counting policy are in [editorial.json](editorial.json). Technical figure annotations and repeated running furniture are outside the editorial word count.

Native visual/source/output acceptance is recorded in [VALIDATION.md](VALIDATION.md) and the hash-pinned [validation.json](validation.json). The final source exports contain 52 reader pages, 27 reader views and 26 imposed sides, with zero native publication preflight issues.

## Open and edit

The delivery uses two ordinary project packages:

- **`VARIOUS-Issue-01.form`** — the publication, canonical page artwork, 26 linked rich stories, two editable running masters, one generic physical assembly and saved Studio compositions.
- **`VARIOUS-Source-Portfolio.form`** — the separate original portfolio of generic folded constructions, exact CAD sources, parametric solid/part recipes and editable vector graphics used to make the issue's visual assets.

Both delivered packages were opened and verified in the same ordinary LAB app; the magazine retained its accepted source after the normal duplicate-ID import. Native opening/reader-position changes and Undo were also checked. Exact results and untouched native/export proof images are in [VALIDATION.md](VALIDATION.md).

Open a package with **File → Open** in the verified LAB app, or double-click it with LAB associated with `.form`. LAB imports an external package into its normal project library. If that project UUID already exists there, LAB creates an imported copy; the provided package itself remains unchanged.

On Canvas, open the publication navigator to browse the 27 reader views. Interior folios **1–48** correspond to logical pages **3–50**; logical pages 1, 2, 51 and 52 are the four named cover faces. Reader views include a front-cover singleton, facing page pairs and a back-cover singleton.

Edit canonical images, vectors and frames with the normal Canvas tools. Edit chapter copy through the existing linked story/source editor; the page frames share that rich source. Folios and running section names come from the two master artboards. The genuine cross-gutter image on logical pages **20–21** is one saved image element, projected into both page crops.

Select the physical object to change opening, reader position, page bend, binding and parent-sheet stock. The saved **Four independent reader positions** scene has a closed copy and three different open positions. **Binding comparison** shows saddle stitch and side staples. These are independent Studio poses of the same physical source: changing a copy's opening does not duplicate page artwork or stock.

## Physical edition

Finished trim is **8.5 × 11 in / 215.9 × 279.4 mm**. The complete issue occupies **13 folded 11 × 17 in / 431.8 × 279.4 mm parent sheets**, printed on 26 sides. The exact two-up study has **zero added bleed**; the imposed PDF retains the exact parent dimensions.

| Parent sheet, outside to center | Stock | Caliper | Printed logical pages | Ink intent |
| --- | --- | --- | --- | --- |
| 1 | Ochre uncoated, 200 gsm | 0.22 mm | 52, 1 / 2, 51 | Process K only |
| 5 | Pale sage uncoated, 110 gsm | 0.12 mm | 44, 9 / 10, 43 | Process K only |
| 9 | Powder blue uncoated, 110 gsm | 0.12 mm | 36, 17 / 18, 35 | Process K only |
| 13 | Warm yellow uncoated, 110 gsm | 0.12 mm | 28, 25 / 26, 27 | Process K only |
| Other nine parents | Warm white uncoated, 100 gsm | 0.10 mm | Remaining 36 faces | Full color |

The page pairs before and after `/` are the physical front/back left-to-right print slots. Each parent owns its stock once; both derived viewing leaves inherit it. Substrate colors are nonprinting backdrops. Colored-stock pages use explicit process-K fills, strokes and rich text, with editable black technical illustrations in place of color rasters. RGB black alone is not used as a claim of K-only output.

The canonical binding is two-wire saddle stitch, with centers **50 mm and 229.4 mm** along the fold. The generic binding declaration also supports side staples, an 8 mm edge inset and a bounded 10 mm flex region. Geometry and stock parameters remain project data rather than a built-in magazine model.

## Source portfolio and provenance

The original asset bank contains **70 originals: 33 native PNG stills and 37 editable vector originals**, reused deliberately across the 110 placements. The six families are Fold Bureau (folded paper), Matter Study (CAD ceramic forms), Signal Rooms (graphic/type studies), Common Current (lighting studies), Soft Registry (textile/repeat graphics) and Index Works (metal/connection studies).

The issue uses selected whole, detail and multiple-orientation stills from that portfolio. The wide hero was captured at 4800 × 1600 px. Whole-group plates are aspect-fitted instead of cropped through their outer objects. Source models, camera settings, source/PNG SHA256 values and the explicit placement aliases are retained in the authoring manifests and reports.

Black-only technical alternatives derive from actual source geometry: bowl wall sections, the real three-aperture slab, the cup's off-center cavity and distinct front/side/plan views, nominal recipe wireframes and native resolved folded-stock corners. Their annotations distinguish sections and nominal wireframes; small bevels and hidden-line removal are not implied by those drawings. The final editable annotation adjustments preserve every word and frame while fitting the native compositor.

## Reproduce through existing public tools

These scripts author ordinary project data through the same native MCP used for editing. They never launch a second app, send a print job, call an image model or use an API key.

| Script | Purpose |
| --- | --- |
| [author_various_visual_assets.py](../../../scripts/author_various_visual_assets.py) | Author the portfolio through generic construction/CAD/recipe/artwork tools and capture its actual native stills; emit the full asset/provenance manifest. |
| [refine_various_process_art.py](../../../scripts/refine_various_process_art.py) | Offline source-derived editable K alternatives and a guarded combined semantic manifest patch; captured PNGs remain unchanged. |
| [author_various_quarterly.py](../../../scripts/author_various_quarterly.py) | Build or verify the 52 canonical pages, shared stories/masters, mixed-stock assembly, placements, Studio poses and native PDF arrangements. |
| [magazine_physical_examples.py](../../../scripts/magazine_physical_examples.py) | Define the exact parent-sheet nesting, stock and generic binding as project data. |
| [verify_publication_ink_channels.py](../../../scripts/verify_publication_ink_channels.py) | Inspect actual PDF paint operators recursively, ICC identity and physical boxes. |
| [compact_project_package.py](../../../scripts/compact_project_package.py) | Byte-copy a stable package's current Manifest, referenced immutable Objects and complete Assets tree; omit old revisions/caches/exports without rewriting source data. |

An offline layout check needs no app or socket connection:

```sh
python3 scripts/author_various_quarterly.py \
  --plan-only --app /Applications/LAB.app --socket /tmp/unused-form-socket \
  --library .local/validation/various-reproduction-library \
  --output .local/validation/various-new-layout-plan
```

Live authoring requires an explicitly selected **already-running ordinary LAB**, its matching socket, a fresh output folder and a **disposable library under `.local/validation`**. Run each script's `--help` for the exact CLI. Generate the portfolio manifest first, then pass the selected completed manifest to the magazine author with `--assets`. Source-derived semantic/K refinements are offline manifest revisions; native changes are applied only through the guarded public authoring path.

The magazine runner rejects new project creation in the normal library. Its `--verified-existing-project-library` exception is restricted to an existing, completed checkpoint with the explicit project UUID, source snapshot, canonical source SHA and verified app hash. That resume path verifies or applies specifically declared repairs; it does not reauthor the issue over unrelated native edits. Historical repair switches require their original retained reports and hashes and are not a general-purpose update command.

## Packaging and output checks

After native review is complete and the saved source is stable, obtain its exact Manifest SHA and use the compact-copy helper with a new destination and an external certificate path. `--plan-only` reads and hashes without copying. The normal project must not be changed during the copy. The helper refuses overwrites and symlinks, preserves every copied file byte and records full SHA256 values. `--verify-report` can recheck a delivery against its certificate. It does not perform a native load or establish visual acceptance.

A handoff review should open the provided copy in LAB and verify the canonical pages/stories, stock/binding, all reader views and both saved scenes. Export separate **52-page reader pages**, **27 reader views** and **26 imposed parent sides**. The magazine script's pages/booklet composites use declared physical ink intent; reader spreads use a stock-tinted screen preview. Inspect the native page images and whole/detail Studio renders, then audit the actual composite PDF's black-only sides and exact 431.8 × 279.4 mm imposed boxes.

Digital geometry, generic ICC conversion and the stated gsm/caliper values describe this authored visual study. They do not establish a calibrated press condition or a manufactured binding proof. The accepted native review and its exact evidence are recorded in [VALIDATION.md](VALIDATION.md); a file-count or package-copy check alone does not establish that result.

For the generic model, native controls, editing/MCP contracts and output modes, see [Publications](../../../docs/publications.md), [Multi-sheet publications](../../../docs/multi-sheet-publications.md) and [Enhanced paper and print finishing](../../../docs/enhanced-paper-print-finishing-brief.md).
