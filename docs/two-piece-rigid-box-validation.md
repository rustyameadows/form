# Accepted separate-board workflow

November 4, 2026 · Acceptance and handoff complete

The specified separate-board workflow has passed source/geometry, ordinary-app native, actual render, construction-file and portable-package acceptance against the [specification](two-piece-rigid-box-spec.md) and [implementation plan](two-piece-rigid-box-implementation-plan.md). The implementation and accepted handoff are pushed in [PR #37](https://github.com/rustyameadows/form/pull/37), ready for review. Main is unchanged. This acceptance does not claim physical manufacturing verification.

The code checkpoint is `04da88a`; the accepted project, packets and evidence checkpoint is `672cca0`. Start with the [editable study](../examples/two-piece-rigid-boxes/README.md), [portable audit report](../examples/two-piece-rigid-boxes/proofs/packet-audit.json), [actual final views](../examples/two-piece-rigid-boxes/proofs/final/) and [PDF/SVG visual review](../examples/two-piece-rigid-boxes/proofs/packet-visuals/visual-review.md).

## Implementation and regression checks

- **323 tests passed, zero failures and zero skips** in the latest completed regression run, taking 103.203 seconds (`/private/tmp/lab-rigid-final-native-regressions.log`). The initial sandboxed attempt encountered clipboard/GPU access failures; that attempt is retained separately and is not counted as a passing run. The completed run had the required native access.
- An earlier **311-test run passed** at `/private/tmp/lab-rigid-tenth-tests.log`.
- A separate **43-test publication/cache regression run passed**, covering dense physical frames, publication layout/spreads, navigation and first-mount linked-pattern focus (`/private/tmp/lab-rigid-publication-cache-tests.log`).
- Coverage includes independent stocks and parent groups, saved optional pieces, derived dimensions, actual tape contact, staple receiving paths/access, physical wire envelopes, canonical front/reverse artwork, native candidate editing, conservative legacy adoption, independent Studio poses, production-guide acceptance, material layouts and shared texture sampling. The latest run also covers tiny-placement keys and explicit PDF page roles, four shared technical-guide/Canvas-overlay cases, and camera/subject-aware directional shadow fitting, including an actual GPU regression.
- The final review found and repaired clinch self-intersection, production guides accepted before their export-time failure, and double-counting a physical tape strip referenced by multiple joints. Clinch tests include a supported through-stack route, excessive overlapping tips, an insufficient physical bend and separated tips at different receiving heights.
- Application changes remain generic. Named construction geometry, option sets, artwork and manufacturing assumptions are data in [the CASK / COLLECT study](../examples/two-piece-rigid-boxes/README.md) and the bundled construction starter. No project-name geometry branch was added to Swift.

The earlier 18-test packet gate also passed. These runs overlap in coverage and are not cumulative test counts. Native, actual-render and fresh-export acceptance were completed separately as recorded below.

## Completed native workflow

The single ordinary LAB app was used for these operations:

1. Open **Add object → Construction starters**, choose the editable starter and create its assembly and five canonical artwork sources.
2. Change width from 180 to 200 mm, Preview and Apply, then exercise native Undo/Redo and restore 180 mm. Source IDs and physical type/element sizes survived; canonical artwork anchors moved by translation. Undo restored all five artwork sources exactly.
3. In a later native session, change the board caliper from 2 to 2.2 mm, choose the inset-floor arrangement, change paper covering to backed cloth and enable full lining. Preview, Apply and Undo/Redo retained the accepted source and its related artwork.
4. Return to a supported floor-beneath-wall arrangement and apply combined reinforcement. Public inspection of the native result resolved **32 actual staples and eight actual tape strips**.
5. Exercise assembly presentation controls and open the nonmodal assembly/section review. Export a construction packet through the native file flow.
6. Select the canonical lid title in Canvas and move it 1 mm using the native position control. The resulting affine translated it by 1 mm while retaining its 32 pt type size, element ID and source coordinates. Restore the original placement.

Local evidence includes `native-undo-redo-proof.json`, `native-applied-artwork-proof.json`, `native-round06-before-apply.json`, `native-round06-applied-project.json`, `native-round06-reinforcement-inspection.json` and `native-round06-artwork-position-proof.json` under `.local/validation/rigid-boxes/`. Native screenshots include the staged construction preview and separate section window in that directory's `evidence/` folder.

Earlier automation timeouts are retained in the evidence; they are not reported as completed isolated responsiveness benchmarks. Tool-call wall time includes automation overhead.

While the Mac was locked, a live cover-caliper edit was accepted, but the following project-read and Undo responses timed out. LAB remained running. A later authoritative read proved that Undo had already completed and the **entire project exactly matched its pre-edit snapshot**; no duplicate Undo was issued. Profiling identified repeated copying/hashing of all 1,189 cached Canvas frames through the hidden inspector's publication-layout lens, despite this project having no publications. The lens now preserves its original array when no facing-page layout applies. A dense storage-reuse regression and the 43-test run cover the correction. The timeout recovery and profiled cause remain recorded in `propagation-timeout-recovery-proof.json` and `canvas-publication-passthrough-profile.json`.

After the ordinary app was rebuilt and restarted, eight **actual accepted public parameter edits** exercised covering caliper, lining/caliper, a relocated wall-band seam, tape width, staple count/crown/end spacing, lid depth, locked overlap and finished-outside dimensions. Every revision resolved its actual pieces/attachments and ran preflight, retained source identities and physical artwork sizes, preserved unrelated objects/scenes/camera, and restored the **entire project exactly with one Undo**. Preflight retained the expected artwork-registration review flags after dimension changes; these edits do not claim production approval without that review. All eight rounds passed again on the final installed build; the latest complete edit/preflight/check/Undo timings are 11.29–12.61 seconds each, including bridge workflow overhead rather than isolated slider-drag latency (`live-parameter-propagation-proof.json`). Earlier read-only candidate cases remain in `actual-source-parameter-cases.json`.

The restarted ordinary app also passed explicit linked-pattern first-mount focus: its active 1,189-frame project fitted the chosen approximately 299 × 257 mm region at **101%**, rather than the entire 52 m frame column. `native-final-linked-focus-proof.json` and `evidence/native-final-linked-pattern-focus.png` record the result. Native fastener selection resolved the selected stable joint/fastener definition without changing objects, scenes, history or the independent Canvas target (`native-final-fastener-selection-proof.json`, `evidence/native-final-fastener-selection.png`).

The final completed save/reopen check retained all **45 objects and 26 scenes**, presentation, camera, notes and history; the before/after public-project hashes match exactly (`final-save-reopen-proof.json`). The signed ordinary build from code commit **`04da88a`** was then installed by quitting/relaunching the regular app, with no live executable replaced and no second LAB launched. Its native home opened and the entire accepted project survived restart exactly (`final-install-proof.json`).

The final installed build passed the additional native Classic-shadow and Canvas technical-overlay checks: the retained Table camera shows no false cloth-wall triangle while keeping the real ground shadow; the covering view shows its seam/turn-in marks; and the bare floor reverse shows the actual installed crown marks. Evidence is `evidence/native-final-classic-shadow-fixed.png`, `evidence/native-final-technical-wrap-guides.png` and `evidence/native-final-technical-staple-guides.png`. Review overlays remain distinct from canonical ink and printed artwork.

## Editable configurations and physical source checks

All six required families were created and retained through public MCP, with the stapled family preserved as separate bare and covered checkpoints:

| Checkpoint | Distinct construction |
| --- | --- |
| 01 | Paper covering, taped seams, both halves unlined |
| 02 | Independently lined halves; base wall band and separate face patch |
| 03 | Backed bookcloth, contrasting paper lining and visible turn-ins |
| 04A / 04B | Supported board-joint staples, first bare and then physically covered |
| 05 | Mixed paper/cloth halves, one unlined half and partial overlap with stops |
| 06 | Independent floor/wall/base/lid calipers, inset base floor and deeper lid |

Independent offline checks evaluate the saved source, actual posed stock/wire bounds, adhesive contact, tape coverage, seating contact and dimension-reference behavior. Additional cases cover maximum running clearance with locked overlap, outside dimensions held with stops, and outside dimensions held with axial shims. The [authoring checks](../examples/two-piece-rigid-boxes/verify_geometry.py) are separate from LAB's actual attachment validation.

The corner repair retained 203 saved faces, 51 piece identities and the 17-face topology of each complete cross wrap. Independent comparison across **nine configurations × four poses** confirmed unchanged tab world geometry, component envelopes and canonical crop extents. Convex tapered wing shoulders connect the existing tabs without replacing their stock, moving their world planes or enlarging the finished fit. The 16 affected technical fold guides were updated with their hinges. See `corner-repair-geometry-proof.json` and `round06-live-repair-proof.json` in the local evidence.

## Rejected edits and preservation

Seven actual public MCP edits were rejected while preserving the entire accepted project:

- Locked overlap exceeding available lid depth.
- A lid skirt reaching the base floor.
- Staples requested for the unsupported inset-floor receiving route.
- Insufficient buried receiving depth.
- Wire and edge clearance exceeding the wall caliper.
- Staple count/crown/end margins exceeding available seam length.
- A direct per-fastener short-leg override that kept the global parameter valid, but failed actual receiving-geometry validation.

`invalid-native-mcp-proof.json` records the repair messages and atomic preservation for each rejection.

The original [version-three board-box study](../examples/paper-packaging/04-two-piece-board-box.json) was imported and explicitly adopted through the public path. Actual acceptance retained all 11 panel/component IDs, saved two-ply stock and profiles, outside/inside artwork and finish targets, source identities, original clearance meaning, duplicate Studio instances, poses and camera. Stale adoption was rejected. A single Undo restored the original source, Redo restored the adopted source, and same-project save/reopen preserved the result. Declared exact legacy checks passed before and after adoption. Evidence is in `legacy-acceptance-20261104T070737Z-627034/acceptance-summary.json`.

A preservation comparison checked **2,084 files across ten pre-existing projects** and found no changed files; the final repeated comparison also found those files unchanged (`user-project-preservation-proof.json`). No printing, cutting, machine motion or heating command was sent.

## Actual render review and revisions

The original manufacturing/material references were retained under `.local/validation/rigid-boxes/references/`. Actual ordinary-app renders were reviewed at whole-object and detail views; earlier failed views remain available.

| Rounds | Finding and completed revision |
| --- | --- |
| 01–03 | Closed artwork/foil/relief appeared on the physical lid. Exploded lower pieces fell below the Table and the removed lid exceeded the initial frame. Source-owned group lift and cameras derived from actual posed bounds corrected the presentation. Closed matrices, stock, canonical artwork and source identities were preserved. |
| 04 | Closed and removed-lid renders exercised the remaining paper, cloth, bare/covered staple, mixed-half and deep-lid cases. Whole-object views exposed details requiring closer review. |
| 05 | Matched detail views examined staple undersides, the closed rim, cloth inside/outside corners, lid title and covered wall. Pale corner gaps, low-contrast small cloth text and broad material bands were identified. |
| 06 | Connected convex wing shoulders and targeted cloth secondary-ink changes were applied to the existing live sources without changing their remapped IDs. Matching corner/title/underside/rim/wall renders were captured again. Broad wall bands were investigated separately rather than hidden with geometry changes. |
| 07 | Fourteen closed/removed whole-object views across all seven checkpoints and six matching material/detail views were reviewed and accepted. They show the retained paper/cloth/lining distinctions, covered rims, readable registered foil/type, real bare staple crowns and resolved material detail. These captures predate the final directional-shadow fitting change. |
| 09 | The final installed build produced **21 fresh accepted views**: fourteen whole-object views, six detail views and one seven-checkpoint overview. Cameras match the retained comparison views. The final review found no new visual blocker after the Classic-shadow correction. |

The wall-face audit found no broad coplanar cover/board overlap: the cover's visible face was 0.20 mm from the board and its back face retained a 0.04 mm adhesive gap, matching the cleaner band construction. Shared footprint-aware tooth sampling and texture filter/anisotropy propagation removed the broad diagonal-wave appearance in the accepted round-seven cloth views. The six detail reviews include the cloth corner/inside/title, laid-paper wall/rim and bare staple underside. Evidence is `round07-case-renders.json`, `round07-detail-renders.json`, `packet-audit/round07-whole-material-review.json` and `packet-audit/round07-material-review.json`.

A later native Table inspection found a **triangular shadow artifact under Classic lighting** despite the accepted round-seven views. Matched-camera ordinary-app captures reproduced it under Classic and showed a clean result under Soft side (`evidence/native-round07-cloth-triangle-defect.png`, `native-triangle-camera-project.json`, `table-triangle-classic-v1.render/`, `table-triangle-soft-side-v1.render/`). Camera/subject-aware directional shadow fitting corrected the artifact. The completed 323-test run includes the actual GPU Classic-light regression: unoccluded-face shadow-on/off difference was **0.0**, with the ground shadow retained (`shadow-regression/shadow-comparison.json`, `classic-shadow-on.png`, `classic-shadow-off.png` in that folder). Final ordinary-app inspection at the preserved native Table camera confirmed the correction and retained ground shadow (`evidence/native-final-classic-shadow-fixed.png`).

Shared technical review overlays derive source guides, adhesive regions/exclusions and installed wire marks in the same canonical crop/reflection as the physical artwork views. Four Core/Canvas cases passed in the completed suite; they verify presentation independence and that technical marks do not become ink or final print. The final native wrap and reverse-floor inspections also passed, with actual seam/turn-in and crown marks visible in the corresponding views.

The final accepted actual-render review is `packet-audit/round09-final-view-review.json`, with fresh images under `round09-*.render`, `round09-overview-proof.json` and the retained earlier rounds. Source-only presentation and corner proofs remain in `explosion-lift-source-proof.json`, `round03-camera-proof.json`, `wall-face-audit.json` and the round-six repair records. Geometry checks and the completed visible design loops are recorded separately.

## Completed construction-file checks

The initial public packet and the later native-exported paper packet each passed an independent read-only source/artifact audit; the reports retain counts for each check category. The native packet contained 20 physical cut pieces, eight tape cuts, three material batches, 55 SVG files, two finish masks and actual-size pattern, material-layout and assembly PDFs.

Checks independently evaluated source expressions, material unions and holes; compared cut dimensions/calipers/quantities, transformed SVG contours and stock placements; checked grain/rotation and actual contour spacing; verified technical guides, registered print/foil/emboss masks and assembly dependencies; and interpreted the emitted PDF cut paths and media boxes at physical scale. Manifest file hashes and the saved source snapshot were also checked.

All seven round-six packet exports subsequently passed **8,283 independent physical/source/artifact checks**, with current source digests and intact file hashes (`final-packet-export-proof.json`, `packet-audit/round06-report.json`). Negative controls reject a two-micron band-edge defect and a missing placement label even after rehashing the manifest (`packet-audit/driver-negative-controls-round06.json`). Older captured packets were retained unchanged and correctly report stale when their accepted source differs.

The earlier exploded proof had colliding source labels. Shared numbered callouts and a separate wrapped source-ID legend replaced that layout; representative actual PDF reviews confirm clean callout/legend separation, including the 32-piece covered case. Actual-size patterns retain connected wraps, separate liners and real backing slots. The cloth print and foil/emboss mask SVGs were rendered separately: substrate color stays out of printed ink and masks retain piece-local registration. Actual PDF text retains all 164 pattern/exploded identities and all 48 stable wire-instance IDs across the seven packets. Read-only visual/text evidence and 80 rendered proof jobs are under `packet-audit/final-round06/`, including `visual-review.md` and `artifact-text-checks.json`.

That visual audit found a **real label defect** despite the physical/source checks: four 16 × 4.04 mm overlap-stop identities in checkpoint 05 truncated to `overlap-` in the material-layout PDF. A generic shared PDF/SVG fix gives tiny placements numeric keys and puts full identities on separate readable annotation-only PDF pages and SVG companions. Actual PDF/SVG, media-box, manifest and disabled-label tests passed in the 323-test run. Round-six files remain unchanged as evidence of the caught defect.

All seven fresh **round-eight packets passed 8,875 independent checks** (`packet-audit/round08-report.json`). Independent final Poppler/librsvg review also passed: all **164 placement identities** are present in actual PDF text; the **32 material PDF pages** are correctly classified as **30 physical stock pages and two annotation-key pages**. Tiny keys and full-ID legends are readable without clipping, with matching sheet context. Every MediaBox matches its declared dimensions within 0.02 pt; the mixed stop stock page remains 700 × 1000 mm while its separate key page is A4. All **30 nominal material layouts** retain exactly the prior cut geometry, all seven accepted source digests are unchanged, and all **206 registered print/mask SVG files** are byte-identical to the previously reviewed outputs. Representative fresh callout/section PDFs remain clean. Final proof PNGs and compact identity/media-box/artwork-preservation reports are under `packet-audit/final-round08/`, with acceptance recorded in `visual-review.md`.

The refreshed [portable project](../examples/two-piece-rigid-boxes/CASK-Construction-Lab.form) was copied and verified with **45 objects and 26 scenes**; its manifest digest is `14f262405e0e13b7278618d994bd73b57868fda7a7a436f519b2a0a8dc8d867d`. Final save/reopen again preserved the entire project exactly. All seven [tracked packet copies](../examples/two-piece-rigid-boxes/construction-packets) are byte-identical to the final exports and passed the same **8,875-check portable verifier** after copying. The handoff also retains 24 final proof images and the final PDF visual evidence. Package verification is recorded in [portable-package-proof.json](../examples/two-piece-rigid-boxes/proofs/acceptance/portable-package-proof.json).

## Completed acceptance and final handoff

- [x] **Completed regression gate:** latest suite passed 323 tests with zero failures/skips, including tiny-placement keys, four technical-overlay cases and actual GPU shadow fitting (`/private/tmp/lab-rigid-final-native-regressions.log`).
- [x] **Round-seven visual review:** fourteen whole-object and six detail views accepted; these images predate the later native Classic-shadow discovery and final shadow-fit correction.
- [x] **Ordinary-app restart/reopen and accepted edits:** exact 45-object/26-scene save/reopen, linked-pattern focus at 101%, native fastener selection, and eight accepted parameter/preflight/one-Undo rounds passed with the preserved project.
- [x] **All seven round-six physical/source packets:** 8,283 independent checks passed; separate visual review recorded the tiny-label defect rather than treating physical/hash checks as complete visual acceptance.
- [x] **Latest ordinary-app Classic shadow and technical overlays:** signed `04da88a` installed/restarted; preserved-camera Classic artifact corrected with the ground shadow retained; native wrap and reverse-floor technical marks verified separately from ink/print.
- [x] **Final round-nine visible review:** all 21 fresh whole/detail/overview images accepted at retained cameras with no new blocker.
- [x] **Fresh round-eight packets:** seven exports passed 8,875 independent checks and final actual PDF/SVG visual review; exact stock MediaBoxes/cuts, full-ID keyed legends, classified annotation pages and hashed companions verified.
- [x] **Portable project and evidence:** refreshed editable 45-object/26-scene package verified; seven packet copies byte-identical and independently verified again; final proof images/PDF review retained; exact save/reopen and prior-project preservation repeated.
- [x] **Final commit/PR record:** code `04da88a` and accepted handoff `672cca0` committed/pushed on `codex/two-piece-rigid-boxes`; PR #37 marked ready for review. Main remains unchanged.

## Physical and representation limits

This acceptance concerns the specified separate-board construction. Scored blanks and V-grooved board remain the specification's explicit follow-ons. Exact core-slab checks report their declared pairs; they do not silently claim a complete material/finish/wire collision simulation. Tool access and staple engagement use the supported declared rigid receiving geometry.

Stock calipers, dry adhesive layers, backing, texture scale, allowances and tool envelopes remain recorded prototype assumptions. Geometric closure and rendered fastening do not establish compression, adhesive strength, staple performance or sliding feel. No physical manufacturing sample or machine operation is claimed.
