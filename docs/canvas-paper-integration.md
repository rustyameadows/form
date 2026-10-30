# Canvas, paper faces and Studio integration

October 30, 2026. PR #14 is integrated with paper engine main `133e94e`; its original Canvas changes remain on the same shared full/split viewport implementation.

## Behavior

- Painted picking, hover and the deep layer menu respect actual paper material, including windows, cutouts, transformed panels and the reverse face. The physical clip applies before the forgiving pointer margin, so invisible art cannot capture a nearby click.
- Both paper faces and their registered dielines live together on Canvas, including a blank second face. Flat single-panel goods use **Top / Bottom**; folded constructions retain **Outside / Inside**. Choosing a side activates its existing frame. Flat-sheet entry fits the matching pair together, including when navigation happens before the native Canvas attaches.
- Merely viewing a blank face changes no model data. Its first text/vector/color/SVG/image edit creates the canonical inside source and writes the artwork in one transaction. Held edits retain their gesture generation; Escape, Undo, Redo and reopen preserve canonical IDs, finish targets and the opposite face. Physical-owner locks apply to projected editing. Independent Table selection, camera and inspector stay independent.
- Saved Studio scenes adopt the current project before recall, retain their camera and instances through view initialization, and refresh from current source. Viewport rounding does not mark a clean scene dirty. A real unsaved scene draft gets explicit Save/Discard/Cancel switching, with superseded requests rejected.
- Construction range errors identify the actual parameter and declared bounds. The observed 90 mm carton depth is below that model’s 108 mm minimum; this does not mean its panel/hinge structure is invalid. Model ranges are retained.
- Canvas panel and proof substrates use the same physical face appearance as 3D: bonded ply/profile colors, explicit tint and opacity. Authored opaque backgrounds still overlay the stock. A strict native bitmap proof normalizes tagged captures to sRGB, checks greater than 70% matching coverage at unchanged 0.025 channel tolerance, and verifies no source/history mutation.
- Paper inspectors omit unrelated sewing starter actions; loose Canvas and actual sewing artwork retain them.

## Native evidence

[Top and Bottom together](validation/canvas-paper-integration/native-card-faces.png) records the actual packaged Canvas. Side IDs and placements remain distinct and persistent; both derive their cut boundaries from the same construction.

The scene regression loads all 13 saved compositions in the original twelve-study package, checking live instance IDs and the renderer’s camera matrix/projection. Actual 240×160 viewport captures demonstrate [tuck carton](validation/canvas-paper-integration/studio-scenes/02-study.png), [hang tag](validation/canvas-paper-integration/studio-scenes/08-study.png) and [overview](validation/canvas-paper-integration/studio-scenes/00-twelve-studies.png). [Before](validation/canvas-paper-integration/studio-scenes/source-before.png) and [current source](validation/canvas-paper-integration/studio-scenes/source-current.png) prove source color refresh without changing the saved scene.

The all-scene test used full-resolution paper maps in the unoptimized native test host and took 359.923 seconds. Sampling showed active main-thread paper rasterization, not an asynchronous deadlock. That duration is not a production interaction benchmark.

## Verification

The initial clean PR #14+main gate passed 287 methods. The expanded native gate executed 346 methods; 343 passed and three fixtures failed because their fixed pan distances no longer forced viewport/extent changes, or they expected unsaved fractional dates after the repository’s ISO8601 codec. Those fixtures now derive pan from actual geometry and compare exact persisted-codec state while keeping in-memory source/Undo/Redo assertions exact. A repeated SVG reopen check received the same persisted-codec correction.

The final 49-method recheck passes with zero failures, including paired framing, linked navigation, picking, arrangement, held editing/cancellation, SVG/image import, frame caching, bounds and diagnostics. Across the expanded and corrected runs, **all 354 distinct methods pass their latest execution**. This is explicit union coverage, not a claim that a single full 346-method run was green. [Machine-readable latest results](validation/canvas-paper-integration/native-results.json), [expanded record](validation/canvas-paper-integration/expanded-native-results.json), [expanded log](validation/canvas-paper-integration/expanded-native.log) and [final recheck log](validation/canvas-paper-integration/final-native-recheck.log) retain the evidence. The larger pre-existing full-suite failures documented in the original [Canvas audit](canvas-interaction-audit.md) were not retested as a full suite here.

The final signed package also passes **12/12** native MCP paper cases in **58.84 seconds**: **74** finite parameter cases, **56** declared solid checks, exact source Undo/Redo/reopen, **12** inspected packets, **46** SVG process files, **20** PDFs and **14** finish plates. [MCP summary](validation/canvas-paper-integration/mcp-final-verified-summary.json) and [full record](validation/canvas-paper-integration/mcp-final-verified-report.json) retain requests, outcomes and binary/source provenance. An initial isolated replay omitted the controlled supplier SVG fixture; it was copied byte-for-byte and the guarded replay completed without changing model source.

Executable SHA256: `e1f6196be1660b0f95404499123f4924ab51635a43eb8ad8990ebcd50385de18`. The exact signed candidate is installed at `build/LAB.app`; all object bytes in the four existing user projects are preserved. The [native delivery record](validation/canvas-paper-integration/native-delivery.json) retains that check. The app is left on the business card with both faces visible. Existing manufacturing/finishing limits in the [paper validation report](paper-packaging-validation-report.md) are unchanged.
