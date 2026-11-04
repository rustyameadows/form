# Advanced publication studies

## Review the authored project

The handoff package target is `Advanced-Publication-Studies.form.zip` in this folder. Unzip it, then open the extracted **Advanced-Publication-Studies.form** with **File → Open** in the ordinary LAB app; importing it requires no scripts or model-generation calls. The native package is checked in byte-for-byte after save/reopen verification. The [validation record](../../docs/advanced-publication-validation.md) gives actual results, remaining review items and the retained `evidence/` manifest destinations; the authoring checklist below is a separate contract for newly generated studies.

The reviewed project contains the 128-page sewn hardcover, 96-page adhesive softcover, 64/192-page companion volumes, one- and three-volume fitted cases, an independent sewn softcover, canonical cover/edge/inset sources and saved presentation scenes. It has 505 objects (including the ordinary freeform Canvas); many are editable page/artwork sources consumed by the physical assemblies rather than loose Table products. The sewn copy shares the 96-page publication's canonical body while keeping its own binding and cover source; its actual 135° native view was separately inspected and passed.

Start in **Studio** with `Review03 / hardcover-closed`, `Review03 / hardcover-partial` and `Review03 / hardcover-spread`; the matching softcover scenes exercise the separate flexible cover. The fitted cases are `Collected volumes / single / fitted case` and `Collected volumes / three / fitted case`. `Physical detail / …` scenes isolate edges, hinge, inset, underside and corner. In Canvas, edit the existing source/regions through their linked artwork actions. In the construction inspector, core stock and wrapping stock are separate physical materials; use **Wrapping & turn-ins** for the visible cloth/paper face rather than changing printing ink to imitate it.

Proven source checks include an actual native 128-page trim edit from 140→150 mm, dependent jacket/case updates, exact Undo/Redo and restoration; four material/page-count/trim/order variants also passed and were restored. All four normal-page ink/capacity/source preflights have zero errors/warnings. Native inside-pastedown, sewn-softcover, stitching, fitted-jacket and corrected head-edge image/type views have been inspected and passed. The validation record preserves the rejected first open-case mechanism and its corrective visual rounds. The final installed-build/revised-offset rerender and handoff remain pending; preflight is not manufacturing approval.

Final targeted integration checks passed 75/75 after the ordinary-paper flex/wrap bounds and grounding repair, plus 18/18 binding/assembly geometry tests in 11.547 seconds; a separate bounded bridge/deadline/responsiveness gate passed 9/9. These complement the documented full-suite/fixture rerun rather than replacing native review. Generic implementation is complete; final visual handoff, save/reopen, package/evidence copying and PR completion remain tracked in the validation record. Gather folds/stitches follow fully turned/unturned leaf roots; a parent split by the active spread remains an idealized closed gathering, not an exact sewn-mechanics solution.

## Author another study through public MCP

These importable Python builders author ordinary project data through LAB's public MCP. They do not launch an app, start a second LAB, call an image model, print, export, or read/write private project storage. The caller supplies the active project's public `form_get_project` snapshot and a callback `call(tool_name, arguments)` returning decoded native results.

`book_studies.py` exposes `build_book_study` and `build_book_studies`. The pair contains a 128-page sewn hardcover and a 96-page adhesive softcover, each trimmed to 140 × 210 mm. The hardcover has eight independently imposed 16-page gathers; the softcover has six. White and pale colored parent stock remain independently editable from printing. Pale-yellow pastedowns/flyleaves are physical auxiliary leaves, without logical folios.

The hardcover has two constant-size rigid boards and one continuous reinforced hollowback strip. Its 0.35 mm physical strip follows a generic length-constrained neutral curve between the actual board seams. The strip retains the combined joint/spine/joint material length through opening; its source pixels remain registered in that order. The boards clear the page hinge footprint, retain a 3 mm foreedge/head/tail overhang, and carry centered pale-yellow linings with a 2 mm material rim. The 140 mm-wide, 128-page default uses 133 mm-wide boards and a fixed 2 mm hinge clearance. The 192-page stress volume uses a fixed 3.5 mm clearance. These construction dimensions do not animate with opening.

The linen wrap has actual sidewall/turn-in source pixels and a separately editable physical caliper, a metallic foil title, a blind relief mark, letterpress on the back, and a stepped recess with retained floor and inserted photographic paper. The softcover uses a finite flexible hinge and two physically folded flaps. Only controls that affect its construction remain in its project-owned recipe. These are idealized visual constructions; they do not establish a mechanical or manufacturing proof.

Both covers have one full editable canonical artwork source, a project-owned control recipe, physical dimension relationships, and nonprinting named regions/translation anchors. Text and graphics keep their physical size when registration changes. Stock colors remain material, with transparent artwork backgrounds. An optional removable dust jacket is a separate ordinary five-panel paper construction. Its full independent artboard is linked at actual size, with source regions/anchors driven by the jacket's physical controls.

New cover guide intents are explicit: series, titles and back copy retain their top-left offsets; footers and colophons follow the lower trim edge; the blind seal follows the horizontal center and lower edge; diagrams and the spine title stay centered. These anchors translate existing layers without resizing their frames, fonts or paths. The reinforced bridge has a cotton paper backing and a separate linen face, so the two real material sides remain distinct.

```python
import importlib.util
from pathlib import Path

path = Path("examples/advanced-publications/book_studies.py")
spec = importlib.util.spec_from_file_location("book_studies", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# `public_call` is supplied by the native validation runner. This module has
# no transport and cannot discover or launch an app on its own.
public_call("form_create_project", {"name": "Advanced publication studies / new run"})
project = public_call("form_get_project", {})
result = module.build_book_studies(
    public_call,
    project,
    photo_path="/absolute/path/to/a/reviewed/original-LAB-portfolio-photo.png",
    include_dust_jackets=True,
    request_log=request_jsonl_handle,
)
```

A supplied inset photo is copied into the project by `form_import_image`. Omitting `photo_path` leaves an explicitly labeled original vector study and returns **photo input pending** in the acceptance list. That result must not be presented as completed photographic-inset acceptance. Each fresh builder result returns `acceptance_pending` as an authoring checklist: review actual closed/partial/full native views; inspect the photo/hinge/turn-in/material details; exercise controls and dependencies; prove Undo/reopen; run actual print-source preflight. It does not track or override the separate evidence record for the bundled reviewed project.

New pages are created as Canvas-only canonical sources, and their physical assembly is created before page artwork is authored in public atomic batches of at most 50 edits. This avoids transient loose page meshes on the Table. The builder refuses an existing study or a changed active project. It does not silently resume or overwrite a failed partial authoring run. The caller should retain the returned identifiers, request log, source snapshot, and its normal app/library guards before native rendering and project packaging.

`test_book_studies.py` checks offline physical imposition, source ownership/registration, constant board sizes, foreedge margins, fixed neutral-strip length and connected endpoints at 0°, 15°, 45°, 95°, 135°, 150° and 180°, plus public request shapes. Its finite matrix covers the 64/128/192-page authored volumes; it does not prove every possible caliper, dimension or material. These checks are distinct from native visual acceptance. The earlier native rigid-spine attempt visibly displaced the open front board and was rejected; each newly authored construction needs its own native review rather than inheriting a pass from these tests.

```sh
PYTHONPYCACHEPREFIX=/private/tmp/form-advanced-python-cache python3 examples/advanced-publications/test_book_studies.py
```

The single-study function also accepts `page_count`, `trim_mm`, `name` and `identity_seed`. Counts are complete 16-page gathers up to 192 pages; these authored layouts support trims of at least 140 × 210 mm. Explicit default count/trim values use the same deterministic recipe/layer identities as omitted defaults. A custom name/seed gives every recipe, artwork layer and auxiliary leaf an independent identity, so the volumes can coexist in one project without source coupling.

```python
volumes = []
for count, trim in [(64, (140, 210)), (128, (150, 210)), (192, (155, 215))]:
    current = public_call("form_get_project", {})
    volumes.append(module.build_book_study(
        public_call, current, kind="hardcover", page_count=count, trim_mm=trim,
        name=f"Gathered observations / {count}", identity_seed=f"case-volume-{count}",
        photo_path=reviewed_original_photo_path,
    ))
```

All outgoing CAD scalar fields are checked against the native 256-byte expression budget. Shared derived aliases keep the case pose readable without repeating long expressions. The continuous strip uses its own reinforced stock; the rigid boards retain the full real wrapping/turn-in source margin. Offline tests cover independent imposition, unique source/control IDs, effective controls and default-payload compatibility. Native rendering remains the authority for the finished result.

`case_study.py` separately exposes `build_case_study(public_call, ordered_book_ids, public_project_state, **options)` and `reorder_case_volumes(public_call, case_record, new_ordered_book_ids)`. It reads authoritative closed-envelope inspections and keeps book IDs as live dimension references. `edge_artwork.py` exposes `build_edge_artwork(public_call, public_project_state, book_id, image_path=...)`; its head/tail/fore-edge ink sources remain independent canonical artwork. These helpers author extra project data and do not run automatically when importing this module or opening the reviewed package.

## Guarded repair of an existing authoring run

For an already-authored acceptance study, `hollowback_repair_operations(project, object_id, ...)` and `softcover_repair_operations(project, object_id)` prepare public operations without executing them. The caller must verify the live project ID, canonical source artwork/region hashes, then submit the returned operations in one `form_batch`. Repairs retain body pages, artwork/photo UUIDs, stock/finish edits, scenes, cameras and the existing declared anchor intents. New guide intents are never silently applied to old artwork. Canonical artwork may be translated by its old anchors rather than copied or scaled, so its raw artwork hash can legitimately change. `verify_artwork_translation(before, after)` checks content, style, geometry, sizes, font settings, image crops and parent/clip topology while allowing only element x/y translations, and reports both raw hashes and the actual offsets. The softcover operation removes unused controls only after replacing references to them. Retain before/after sources and prove exact Undo/Redo and reopen before reviewing new renders. A failed or unfamiliar partial construction is rejected for deliberate review.


`jacket_fit_operations(project, jacket_id, book_id)` separately prepares an ordered repair of the existing five-panel removable jacket. It retains the canonical source, editable layers, foil, stocks and physical owner IDs; direct closed-book measurements drive the jacket size. Its finite-width flex arcs turn the original 55 mm source flaps around the real cover caliper. **Call its two returned operations individually in order**, after checking the reviewed project and source hashes: configure the existing construction at its current dimensions, then update the seven dimension relationships. Each operation is atomic; `form_construction` is excluded from `form_batch`. If the second operation fails, Undo the first and verify the original hashes before retrying. Afterward, inspect the construction and use `jacket_scene_registration(inspection, book_position=(0, 0, 0))` to recover its exact normalized component offset for the scene. Keep the source Table layout separate from fitted scene placement; refresh this inspected registration after trim/caliper changes. Native fit, source-translation checks, and Undo/Redo evidence remain required.

The case builder places the outer wrapped construction at `[0, 0, 0]`: native closed-bounds grounding already includes wrapping caliper. It retains the independent lining offset and fitted book layer offsets. Existing scene copies authored with the old extra skin-height compensation should set only the outer case instance Y to `0`, leaving lining and book placements unchanged.

`finish_bare_softcover_study` is a separate explicit recovery for a reviewed existing bare assembly. It requires its object/publication/project UUIDs and the exact reviewed public snapshot SHA, then rechecks a fresh `form_get_project` before writing. It retains every existing nonempty page source, including figure plates; it authors only empty/missing page artwork. It creates one missing canonical cover and configures the existing assembly without creating another publication, page run or physical owner. The final relationships/construction/pruned-controls edit is one batch, and the result retains its before snapshot for Undo/Redo proof. If a prior timed-out request finishes after review, the live SHA guard rejects before any write; review the newer snapshot instead of retrying blindly.
