# Advanced publication validation

Completed native review: November 3, 2026. Nine rounds retain rejected iterations, corrected constructions and the final ordinary-app render review. Native trim/dependencies, material/page-count/order variants, exact Undo/Redo, save/reopen and original-project preservation passed. Rendering approximations and the deferred production phase remain explicit below.

The implementation follows [the book rendering handoff](book-publication-rendering-handoff.md), [acceptance plan](advanced-publication-implementation-plan.md) and [generic API contract](advanced-publication-contract.md). Books, covers, edge artwork, jackets, cases and scenes are project-authored data. The application contains shared physical operations and editors, without example-specific geometry branches. Native authoring and captures used the ordinary LAB app through existing public MCP; no external model-generation service was called.

## Automated checks

| Check | Actual result | Primary log |
| --- | --- | --- |
| Full integrated suite | 1,259 tests: 1,258 passed; one new schema round-trip fixture failed because ISO8601 encoding retains whole seconds while the fixture used fractional current timestamps. | `/private/tmp/lab-publication-acceptance-tests.log` |
| Corrected fixture class | `OnePassSchemaClassificationTests`: 6/6 passed after fixing fixture timestamps to whole seconds. Production serialization/schema assertions remain intact. A second full-suite run after this fixture correction is not recorded here. | `/private/tmp/lab-publication-schema-fixture-tests.log` |
| Final bridge/deadline/responsiveness gate | 9/9 passed: five actual stream-reading tests, three bounded-deadline tests and the original unchanged 100-edit/300-object responsiveness test. Actual AF_UNIX transport retained a 4,433,293-byte JSON response; exact 8 MiB acceptance and one-byte-over rejection remained enforced. | `/private/tmp/lab-publication-bridge-tests.log` |
| Final bounds/integration repair gate | 75/75 passed in 21.340 seconds. Covers actual curved/wrapped ordinary-paper bounds and grounding; shared neutral-curve/Core/mesh behavior; parameter dependencies; native wrapping; material-only review stamps; existing planar packaging and layered-source validation. | `/private/tmp/lab-publication-final-bounds-tests.log` |
| Final binding/assembly geometry gate | 18/18 passed in 11.547 seconds. Covers actual parent fold height, rigidly following fully turned/unturned leaf roots, retained caliper, body-trim adhesive height, gathered fiber, edge/source pixels, binding poses and shared panel geometry. | `/private/tmp/lab-publication-final-binding-tests.log` |
| Focused publication/schema/rendering coverage | 372 tests passed, including the shared model, native controls, source/stock rendering, typography and dependency paths. This run overlaps the full suite; counts are not additive. | `/private/tmp/lab-publication-schema-tests.log` |
| Existing responsiveness gate | `FormCoreTests.testManyObjectEditsStayLocal` passed unchanged: 100 edits among 300 objects still satisfy the original measured-edit threshold of less than 2 seconds. The reported 3.035-second test duration also includes setup of all 300 objects. | Full integrated log above |
| Bulk authoring | Actual 100-page publication with rich story and physical assembly: 100 artwork replacements took 0.748 seconds, with one native preparation callback. All six bulk-replacement tests passed, including rejection/rollback and source semantics. | Full integrated log above |
| Neutral-curve reuse | One cold solve: 4.111 ms. Thirty-five subsequent identical numeric resolutions: 0.139 ms total. The cache test retains coordinate/fit-flag identity and rechecks every material caliper. These measurements describe profile resolution, not viewport FPS or held-slider latency. | `SheetPanelNeutralCurveCacheTests` in the full integrated log |
| Offline project-data authoring | 28 offline tests passed: 19 `test_book_studies.py` and nine `test_case_study.py` tests: public request shapes and actual native artwork-kind/expression limits; canonical ownership; semantic anchors; fixed strip length/board dimensions; effective controls; guarded repairs and recovery without repainting existing pages. | `examples/advanced-publications/test_book_studies.py` |

The full run also passed the new wrapped-material review tests, native wrapping adapter, advanced sheet controls, physical source-stock rendering, trim/dependency, neutral-curve, schema and existing dense-Canvas regressions. The final 75-test gate rechecked the ordinary-paper repairs; the separate nine-test bridge gate checks bounded, linear response accumulation and its real Unix-socket path. Counts overlap and must not be added together. Tests establish behavior and regression coverage; actual native renders remain the visual authority.

## Native project and source preservation

The acceptance project is `DCF5F48D-BCBA-460B-B015-2D1A1D4E8BF2`. Its original 128-page sewn hardcover and 96-page adhesive softcover use 140 × 210 mm logical pages. Mixed white/colored parent stocks, pale-yellow auxiliary leaves and printed cover artwork remain distinct data.

The hardcover repair retained its physical owner, canonical cover `244408D5-7EFB-4D9B-B01B-3D131D220C62`, photographic insert `768814F4-ABD3-4B88-B846-2CB29D44E543`, original artwork layer IDs, declared guide intents and material edits. The raw cover artwork hash changed because those existing anchors intentionally translated layers. The retained proof establishes:

- Before artwork SHA: `f7683c1d34cc2c422ef31aa7ceac274f48c157da752e7f48f3c69806f00e8b1e`.
- After artwork SHA: `4ac78ac2aa2050833f03d552d9b2678f60c2ce7bebf52fa0548378c218c91d8d`.
- Unchanged content/style/geometry/topology SHA, excluding only element x/y: `92f0ecd4d3ade50336ee79c4ba42fea351345fe7ea5765cc85a652cf26594951`.
- Recorded translations: back-cover layers −6.5 mm X; front-cover layers −15.5 mm X; spine title −11 mm X. Text, fonts, sizes, paths, image crops and parent/clip relationships are preserved.
- Separately recorded physical change: the recognized inset-seat expression now centers the same photograph on the corrected board width. Its source UUID, crop, stock, depth and dimensions remain intact.
- Public Undo and Redo restored the exact respective objects and recipes. See `hollowback-repair-proof.json` and its before/after snapshots.

The explicit bare-softcover recovery retained all 96 existing nonempty page sources and authored zero missing pages in the actual run. It added one canonical cover and configured the existing physical owner; it did not create another document, page run or assembly. Its return record and request log are retained as `softcover.json` and `softcover-resume-requests.jsonl`.

The final project contains 505 objects (including the ordinary freeform Canvas), including an independent sewn softcover `05A884E7-1E10-42CB-886A-B43077C9C4C8` and cover source `F4302D50-195F-47D2-AA0F-C6DD3EF3E839`. It shares the original 96-page publication's canonical body artwork while retaining its own binding and cover dependencies. This authoring result is recorded in `sewn-softcover.json`; its actual 135° native variant view was inspected and passed in Round 06. The original adhesive softcover retains its separate 0°/95°/180° captures.

## Native changes and print-source checks

An actual native Publication trim input changed all 128 hardcover pages from 140 to 150 mm wide. Cover registration changed by translation only, keeping the same content/style/topology hash above. The removable jacket's panel width and single-volume case's dependent depth both grew by exactly 10 mm. Public Undo and Redo restored exact page/object/publication states, and a final Undo restored the reviewed 140 mm construction. This is recorded in `native-trim-proof.json`, with `before-native-trim.json` and `after-native-trim.json`.

`parameter-variant-proof.json` records four separate public-MCP exercises, each followed by exact Undo and restoration of reviewed source state:

| Variant | Actual exercised change | Verified dependency/source result |
| --- | --- | --- |
| Core, wrapping and body stock | Hardcover core 2.4→3.1 mm; wrap 0.12→0.18 mm; one parent stock +0.04 mm | Three-volume case width 43.570→45.230 mm; cover content/style/topology unchanged, with recorded translations. |
| Page count | 128→132 logical pages, 32→33 physical parents | Case width grew 43.570→43.770 mm; original pages/recipes/parents restored by Undo. |
| Largest-volume trim | 192-page volume 155 × 215→165 × 225 mm | Case height grew 224.840→234.840 mm; centered/bottom/left artwork followed its declared semantic anchors without resizing type/graphics. |
| Volume order and fit | Reversed the three actual source IDs; clearance 1.8→2.8 mm, volume gap 0.8→1.4 mm | Order references and dependent offsets updated; case artwork retained content/style/topology with recorded translations; exact Undo restored all sources. |

All four actual normal-page ink/capacity/source preflights returned `can_export:true`, `for_print:true` and an empty issue list: **zero blocking errors and zero warnings**. Each retained `substrate_is_printed:false` and `stock_color_encoded_in_pdf:false`.

| Publication | Pages / physical parents | Retained report |
| --- | --- | --- |
| Original sewn hardcover | 128 / 32 | `preflight-95D43B98-5DA8-41F6-AA59-E2C05304A4AE.json` |
| Adhesive softcover | 96 / 24 | `preflight-653D36F1-A8C7-4F5D-986E-4A9021808301.json` |
| Smaller sewn volume | 64 / 16 | `preflight-6A07C575-E9AC-4758-A3E4-6000FAAF6BFA.json` |
| Larger sewn volume | 192 / 48 | `preflight-EC519271-66AD-42E8-878E-9EDB70BAFAC4.json` |

These reports establish the normal logical pages' ink, text capacity and source checks for the selected physical editions. They do not substitute for inspecting exported PDF pages, checking cover/jacket/case production files, or proving a real print/bindery result. The sewn-softcover copy shares its body's publication and has a separately inspected native variant capture; it is not a second independent page run.

## Meaningful native iterations

All listed captures are actual 1,500 × 1,000 RealityKit output from LAB. Each `.render/` directory includes its PNG and `render.json`, with camera/lighting/instance pose, source-design hash, resource hashes and PNG SHA. Local evidence is under `.local/validation/advanced-publication/`.

The checked-in handoff destination is `examples/advanced-publications/evidence/`; the ordinary-app-authored package target is `examples/advanced-publications/Advanced-Publication-Studies.form.zip`. The artifacts below are checked in. The package was copied byte-for-byte from the ordinary app after save/reopen; `package-copy-proof.json` records all 1,588 file hashes. `manifest.json` indexes the retained evidence.

| Iteration / question | Actual local artifacts | Handoff artifacts under `evidence/` | Result at this checkpoint |
| --- | --- | --- | --- |
| Initial hardcover, closed / 95° / 180° | `round-01-hardcover-{closed,partial,spread}.render/` | Same three directory names | **Rejected open construction:** partial opening detached the front board; full opening produced excessive asymmetric left overhang. Closed/detail views established the initial foil, stock, page strata and photo inset. |
| Linen and foil, fixed camera | `round-01-corner-relief.render/`, `round-02-corner-texture.render/`, `material-round-02.json` | Same directories and JSON | Material-only comparison retained camera, light, geometry, artwork and caliper. Linen depth 0.009→0.04 mm, scale 0.65→0.75 mm, roughness 0.92→0.82; foil roughness 0.23→0.12. Woven surface and brighter foil became visible. The whole-book bounds extend outside these intentional close-up frames. |
| Corrected hardcover, closed / 95° / 180° | `round-03-hardcover-{closed,partial,spread}.render/`, `round03-scenes.json` | Same directories and JSON | Captured after the constant-board, continuous length-constrained hollowback repair. Opening poses share active leaf 34; partial/full poses use 4 mm bend. No framing warnings in these whole-object captures. Subsequent detail reviews are recorded below. |
| Adhesive softcover with flaps, closed / 95° / 180° | `round-03-softcover-{closed,partial,spread}.render/` | Same three directory names | Captured as a separate flexible construction, active leaf 26. No framing warnings in the whole-object outputs. The sewn construction has a distinct later native review. |
| Three materially different volumes and fitted cases | `round-04-three-case.render/`, `round-04-single-case.render/`, `cases.json`, `case-scenes.json`, `set-volumes.json` | Same directories and JSON | Actual one- and three-volume case renders exist. The ordered set uses 64/128/192 pages, with 4/8/12 independently imposed 16-page gathers. The 64-page volume is 140 × 210 mm, original 128-page volume 140 × 210 mm, and 192-page volume 155 × 215 mm. The 192-page construction has its own fixed 3.5 mm hinge clearance. Final fit/interaction acceptance remains in progress. |
| Hardcover edge / hinge / inset / underside / corner | `round-05-hardcover-{edges,hinge,inset,underside,corner}.render/`, `detail-scenes.json`, `edge-artwork.json` | Same directories and JSON | Native inset, underside, outer corner and hinge captures were inspected and passed, with no fatal discrepancy in independent review. Close-up framing metadata reports the complete object extending outside the image; this is not a whole-object framing proof. Later inside-corner/head-image checks are recorded below. |
| Inside pastedown, sewn softcover and stitching | `round-06-{inside-pastedown,sewn-softcover,stitching}.render/`, `supplement-scenes.json` | Same directories and JSON | Actual views inspected and passed: inside lining at 180°, independent sewn softcover at 135°, and 180° stitching review. Binding movement remains idealized as described below. |
| Removable jacket fit | `round-06-removable-jacket.render/`, `round-07-fitted-jacket.render/`, `jacket-fit-proof.json`, `fitted-jacket-scene.json` | Same directories and JSON | Revised physical jacket/source fit was inspected and passed in Round 07. The final installed-build Round 09 rerender also passed with a fresh native component registration; the earlier imperfect review is retained alongside its correction. |
| Head-edge image registration | `round-06-head-image-registration.render/`, `round-07-head-image.render/`, `round-08-head-registration.render/`, `final-head-scene.json` | Same directories and JSON | Corrected negative-Z Round 08 camera visibly shows image bands/type registered across real body-leaf edges, while pale-yellow auxiliary leaves remain untouched. Earlier cameras did not establish that view and are retained as iteration evidence. |
| Canonical repair and recovery | `before-hollowback-repair.json`, `after-hollowback-repair.json`, `hollowback-repair-proof.json`, `softcover.json`, `softcover-resume-requests.jsonl` | Same filenames | Hardcover source translation and exact object/recipe Undo/Redo proven; all 96 nonempty softcover pages retained. These are source/data proofs, separate from native UI gesture and final reopen acceptance. |
| Native trim and project-data variants | `native-trim-proof.json`, `parameter-variant-proof.json`, before/after snapshots | Same filenames | Actual native trim plus four public-MCP parameter variants passed and restored reviewed source dimensions; exact source/Undo proofs described above. |
| Physical publication preflight | Four `preflight-<publication-id>.json` files above | Same filenames | All four have zero errors/warnings and keep substrate color separate from printed ink. |
| Independent sewn softcover | `sewn-softcover.json` | Same filename | Independent physical and cover owners authored; actual Round 06 variant view inspected/pass. |
| Final test checkpoint | Acceptance, fixture and bridge logs named above | `tests/acceptance-tests.log`, `tests/schema-fixture-tests.log`, `tests/bridge-tests.log` | Copied with the original full-suite fixture failure and corrected class result intact; no fabricated all-pass full run is presented. |
| Final ordinary-paper bounds repair | `/private/tmp/lab-publication-final-bounds-tests.log` | `tests/final-bounds-tests.log` | 75 targeted tests passed. Off-origin curves and a finite half-turn wrapped flap share true caliper/skin bounds and grounding with their deformed geometry. |
| Final binding/assembly geometry | `/private/tmp/lab-publication-final-binding-tests.log` | `tests/final-binding-tests.log` | 18 targeted tests passed; actual parent/body heights and fully turned/unturned gathering attachment are retained. |

The rejected rigid-spine approach was replaced by a generic cubic neutral-curve primitive and project-authored expressions, not by a named book renderer. The reinforced strip retains real J/spine/J material length, with a cotton paper backing and linen face. Rigid board sizes remain constant during opening. Offline pose checks cover a finite authored 64/128/192-page matrix; they do not prove every caliper or construction, mechanical behavior, gravity/contact or manufacturing tolerances.

Gather fold ribbons use each real parent leaf height, and the adhesive uses body trim height rather than enclosure/auxiliary extent. Fully turned or fully unturned parent folds and their stitch paths rigidly follow the actual resolved leaf roots, retaining their physical caliper and neutral length. A parent split by the active viewing spread remains an idealized closed gathering: the current page-opening model does not define a length-preserving mechanical fold there. The renderer does not stretch a ribbon to bridge incompatible endpoints, and the evidence does not claim exact sewn-book mechanics.

The final ordinary-paper repair uses the same physical curved/wrapped envelope for closed measurements and grounding, including off-origin panels and explicit components. It no longer substitutes undeformed rectangular corner bounds for a curved surface or omits wrap caliper. This matters to the editable jacket/case workflow as well as unrelated signs, folders and packaging. Existing paper, standalone single-root sources and historical optional-field behavior remain covered by the 75-test gate.

## Handoff requirement audit

The required generic capability paths are implemented: physical-size linked cover art and guides; real layered cores/wrap/turn-ins/recesses; flexible covers/flaps; stock distinct from ink; gathered signatures and adhesive/sewn/staple bindings; canonical three-edge artwork; dependent jackets/cases; captured native controls and typed public MCP; and transactional source/Undo/persistence. The latest audit found no additional confirmed missing implementation requirement. Final installed-build comparisons and ordinary-app save/reopen are complete. The reviewed project, test logs, source/Undo proofs and native UI captures are included in the handoff. An independent read-only review found no visible blocker in the final hardcover/softcover opening and hinge views.

Production dielines, press imposition/creep compensation, tooling and verified manufacturing tolerances were explicitly deferred by the original handoff. A collision/gravity/contact solver, arbitrary-construction mechanical simulation or calibrated press proof is not asserted by the implemented idealized rendering model.

## Final installed-build and persistence review

Round 09 re-rendered hardcover 95°/180°, its hinge close-up, softcover 95°/180°, the one- and three-volume cases and the fitted jacket using the final ordinary LAB renderer. All eight PNGs and their native `render.json` records are retained. Root and independent review found no newly visible blocker: balanced cover margins and readable active spreads remained; flexible covers stayed visually distinct; layered hinge/cloth/endpaper relationships and fitted case gaps remained coherent.

`native-ui/canvas-cover-guides.png` shows the actual canonical artwork with construction regions, linked 3D preview and live dimension relationships. Narrow joint/spine labels follow their long axis and remain inside their own guide. `native-ui/studio-three-volume-case.png` shows the saved case scene opened through the ordinary Studio thumbnail strip. The native trim edit and public material/construction variants above verify source-preserving mutations; wrapping adapters and stale-field behavior also have native AppKit regression coverage. A physical held-slider FPS/latency measurement is not claimed.

`final-reopen-proof.json` verifies exact equality of all objects, publications, recipes, materials, source camera and Studio presentation after closing and reopening the saved document: **505 objects, four publications, 23 scenes**. The initial large-document open completed but exceeded the MCP helper's former 30-second response window; a subsequent public read verified the actual persisted result. The helper now gives only valid saved-project opening a bounded 180-second preparation window. The final nine bridge/deadline tests pass in 7.878 seconds; ordinary edits remain at 30 seconds.

`user-preservation-proof.json` verifies **all 496 original files in nine pre-existing projects are byte-identical**. `package-copy-proof.json` verifies the checked-in `.form` package is an unmodified native copy, including its assets and saved scenes. Test counts overlap and are not additive.

No physical print, bindery test, machine command or manufacturing approval is represented by this evidence.
