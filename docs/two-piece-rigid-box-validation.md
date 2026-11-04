# Two-piece rigid setup box validation

November 4, 2026 · Acceptance in progress

This records completed validation against the [separate-board specification](two-piece-rigid-box-spec.md) and [implementation plan](two-piece-rigid-box-implementation-plan.md). It distinguishes source/geometry checks, native operation, actual render review and construction-file inspection. Final gates below remain open; this document does not declare the workflow finished.

## Implementation and regression checks

- **311 tests passed, zero failures** in the final completed regression run recorded at `/private/tmp/lab-rigid-tenth-tests.log`.
- Coverage includes independent stocks and parent groups, saved optional pieces, derived dimensions, actual tape contact, staple receiving paths/access, physical wire envelopes, canonical front/reverse artwork, native candidate editing, conservative legacy adoption, independent Studio poses, production-guide acceptance, material layouts and shared texture sampling.
- The final review found and repaired clinch self-intersection, production guides accepted before their export-time failure, and double-counting a physical tape strip referenced by multiple joints. Clinch tests include a supported through-stack route, excessive overlapping tips, an insufficient physical bend and separated tips at different receiving heights.
- Application changes remain generic. Named construction geometry, option sets, artwork and manufacturing assumptions are data in [the CASK / COLLECT study](../examples/two-piece-rigid-boxes/README.md) and the bundled construction starter. No project-name geometry branch was added to Swift.

The 311-test run is separate from the final 18-test packet gate; both passed. Neither substitutes for visual acceptance.

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

A preservation comparison checked **2,084 files across ten pre-existing projects** and found no changed files (`user-project-preservation-proof.json`). No printing, cutting, machine motion or heating command was sent.

## Actual render review and revisions

The original manufacturing/material references were retained under `.local/validation/rigid-boxes/references/`. Actual ordinary-app renders were reviewed at whole-object and detail views; earlier failed views remain available.

| Rounds | Finding and completed revision |
| --- | --- |
| 01–03 | Closed artwork/foil/relief appeared on the physical lid. Exploded lower pieces fell below the Table and the removed lid exceeded the initial frame. Source-owned group lift and cameras derived from actual posed bounds corrected the presentation. Closed matrices, stock, canonical artwork and source identities were preserved. |
| 04 | Closed and removed-lid renders exercised the remaining paper, cloth, bare/covered staple, mixed-half and deep-lid cases. Whole-object views exposed details requiring closer review. |
| 05 | Matched detail views examined staple undersides, the closed rim, cloth inside/outside corners, lid title and covered wall. Pale corner gaps, low-contrast small cloth text and broad material bands were identified. |
| 06 | Connected convex wing shoulders and targeted cloth secondary-ink changes were applied to the existing live sources without changing their remapped IDs. Matching corner/title/underside/rim/wall renders were captured again. Broad wall bands were investigated separately rather than hidden with geometry changes. |

The wall-face audit found no broad coplanar cover/board overlap: the cover's visible face was 0.20 mm from the board and its back face retained a 0.04 mm adhesive gap, matching the cleaner band construction. Shared footprint-aware tooth sampling and texture filter/anisotropy propagation were subsequently implemented and covered by the 311-test run. Final native verification of that latest texture/weave change and viewport-aware focus remains open below.

Source-only presentation and corner proofs are in `explosion-lift-source-proof.json`, `round03-camera-proof.json`, `wall-face-audit.json` and the round-six repair records. Actual images remain in the corresponding `round01-*.render` through `round06-*.render` directories. Passing geometry checks alone do not establish that the final materials and corners look acceptable.

## Completed construction-file checks

The initial public packet and the later native-exported paper packet each passed an independent read-only source/artifact audit; the reports retain counts for each check category. The native packet contained 20 physical cut pieces, eight tape cuts, three material batches, 55 SVG files, two finish masks and actual-size pattern, material-layout and assembly PDFs.

Checks independently evaluated source expressions, material unions and holes; compared cut dimensions/calipers/quantities, transformed SVG contours and stock placements; checked grain/rotation and actual contour spacing; verified technical guides, registered print/foil/emboss masks and assembly dependencies; and interpreted the emitted PDF cut paths and media boxes at physical scale. Manifest file hashes and the saved source snapshot were also checked.

The earlier exploded proof had colliding source labels. Shared numbered callouts and a separate wrapped source-ID legend replaced that layout; fresh final packet visual review remains required. Earlier exports were retained unchanged. Evidence is in `.local/validation/rigid-boxes/packet-audit/`, including `driver-round01.json`, `native-round06-report.json` and rendered proof pages. These completed paper-packet checks do not establish acceptance of all seven final packets.

## Outstanding final gates

- [x] **Final packet regressions:** all 18 packet tests passed with zero failures, including actual PDF/SVG identities for both narrow-piece orientations and disabled labels (`/private/tmp/lab-rigid-final-packet-tests.log`).
- [ ] **Round-seven visual review:** capture and inspect final whole-object/detail renders after the latest texture/weave and focus changes, including the affected corners, wall material and staple/section views. Record discrepancies and any further revisions.
- [ ] **All seven final packets:** export the preserved configurations, run independent artifact/source QA and inspect representative actual-size patterns, material layouts, registered artwork/masks, schedules, assembly order and numbered section/exploded drawings. Record packet digests and final results.
- [ ] **Final ordinary-app restart/reopen:** install the verified final build by quitting/relaunching the regular app; verify the saved project, canonical artwork, materially different variants, presentation poses/cameras and final native controls. Recheck existing-project preservation.
- [ ] **Portable project and PR:** preserve the editable project package and evidence handoff, verify their contents, and record the final commit/PR. Do not replace these gates with a claim based only on test success.

## Physical and representation limits

This acceptance concerns the specified separate-board construction. Scored blanks and V-grooved board remain the specification's explicit follow-ons. Exact core-slab checks report their declared pairs; they do not silently claim a complete material/finish/wire collision simulation. Tool access and staple engagement use the supported declared rigid receiving geometry.

Stock calipers, dry adhesive layers, backing, texture scale, allowances and tool envelopes remain recorded prototype assumptions. Geometric closure and rendered fastening do not establish compression, adhesive strength, staple performance or sliding feel. No physical manufacturing sample or machine operation is claimed.
