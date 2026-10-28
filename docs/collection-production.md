# Collection plans, BOMs and technical packets

Collection production brings explicit run quantities, attached components, source-derived consumption, portable stock declarations and cost assumptions into one native review. Open **Production jobs → Collection BOM**. Reusable blank, trim and consumable records live in **Studio Library → Textile stock & equipment → Blanks, trims & supplies**. Existing thread/fabric records retain their own identities.

This is a bounded technical review workflow. Unknown information remains visible; a captured packet is not a purchase, stock reservation, machine queue, calibrated fit assessment or manufacturing approval.

## Native workflow

1. Create a plan and add actual physical products or a managed garment size. Enter each run quantity and choose whether its attached details are included. Source sheets, shared artwork definitions and display variants do not imply extra production quantities.
2. Review the BOM. Choose **Purchased**, **Made** or **Unresolved** for an independent component's cost basis. A complete purchased component covers its descriptive raw-material references. Made components use separate material/process contributions. Retained dormant rates are not charged twice.
3. Enter explicit missing total-row quantities, rates/currencies, supply assignments and optional exclusions. Additional material/labor/setup declarations may be once per collection or per item of one named run. A rate is per the displayed quantity unit. An omitted value remains unknown, including when another input is zero.
4. Select exact existing embroidery/HTV/DTF revisions. Their archived quantity must match the required occurrences for that exact object. Reference files do not multiply the captured quantity again. Captured base/extra BOM costs need one matching collection owner; they are not automatically added on top of other rows.
5. Save the plan, then capture its reviewed technical packet. Save and Capture are separate, atomic Undo steps. Reviewing derived rows does not dirty the saved plan. Invalid active inputs stay visible; Cancel publishes nothing. Captured revisions retain their source/file bytes and remain accessible after the live source or plan is removed.

Clean saved forms follow document Undo/Redo. An independent unsaved form, including a focused field whose binding has not updated, remains a draft. Undoing a capture returns to its editable saved plan. Production records and saved Studio shots do not reset active cloth or rebuild an evicted assembly mesh; physical source edits retain their existing reset behavior.

The archive view compares current source and plan separately, opens the frozen PDF in the existing sharp PDFKit review, and exports a ZIP or a new folder. Viewport identity includes project and immutable capture ID. Read-only preflight/get/export does not finish a text draft. Invalid mutations preflight before a field handoff. A valid native/agent mutation follows the existing editor commit once.

## Physical quantities and provenance

Run quantities are integers from 1 to 100,000. Each occurrence is keyed by run and actual object, including the existing textile/material-coordinate attachment edge. A physical child cannot also be charged as a root in the same scope; use a distinct standalone component for spares. Shared artwork, `designID`, material names or SKUs do not merge distinct products.

For a managed garment size, the front/back/elastic source bindings represent one finished unit. The elastic cut includes the declared lap once. Actual cut-contour area includes supported holes/notches; it is separate from raw rectangle envelopes and allocated fabric yardage. Missing/stale source remains a review conflict or unknown quantity, never an automatically repaired pattern. Source-backed assembly variants may share pattern definitions while retaining distinct physical run quantities. The same managed size and its assembly preview cannot represent the same physical source twice.

Every row identifies its evidence:

| Evidence | Meaning |
| --- | --- |
| Computed | A calculation on identified geometry/archived commands, with an explicit formula |
| Declared | User-entered quantity, rate, consumption factor or commercial information |
| Reported | Existing user sample observations remain in their archived process source; they do not replace demand assumptions |
| Unknown | Required input is missing, conflicting or unsupported |

Computed geometry is not physically measured machine consumption. Needle-path meters include supported underlay/locks and exclude travel; planned upper thread still needs both the existing explicit factor and per-color/item allowance. Bobbin, stabilizer, time, powder and ink are separate unknowns/declarations. DTF transfer dimensions do not become ink volume or a verified white channel. HTV visible cut area does not become purchased roll usage.

Physical material units are `piece`, `m`, `m2`; duration is `min`. Millimeter source values convert explicitly to meters or square meters. Different dimensions are not silently merged or converted. Unknown, zero, excluded and not applicable remain distinct.

A complete existing one-unit material layout may be repeated by its run quantity. The scope must match its actual piece-copy identities/materials, with no duplicate coverage. Full open width supplies allocated area for folded stock; the roll length is not doubled again. Sheet allocation retains its complete declared sheet length. The initial collection route does not invent cross-unit nesting or rewrite source cut quantities into a batch. Explicit batch-layout allocation beyond those recorded identities remains open.

Separate rows retain net cut area, allocated stock area and charged length. An existing area rate and a new linear rate cannot both price the same allocation. Technical cutting SVG/PDF outputs use the established actual-size layout renderer and calibration; they contain structural cut/guide content, with no flattened source-art/ink claim.

## Cost scope, decimals and stock

New quantities/rates are complete nonnegative decimal strings: at most 12 fractional digits and no more than 1,000,000,000,000 per declared input. Exponents, whitespace, partial parses, nonfinite values and unsupported precision reject. Computed/aggregate values are bounded at 1,000,000,000,000,000,000. Arithmetic checks exact decimal-digit results, rather than trusting Foundation's calculation status alone.

Necessary division uses an explicit version 1 estimate policy: **12 decimal places, half-even**. Exact bounded integer long division determines the result. Each affected line records numerator, denominator, actual result, scale/mode/version, original inputs and whether rounding occurred. For example, one declared minute at USD 10/hour gives USD 0.166666666667 with rounding recorded. A 1/3 estimate becomes 0.333333333333. Original inputs remain unchanged. Addition/multiplication cannot silently lose precision or overflow. Display formatting is separate from these recorded values.

Known priced subtotals remain separate by declared three-letter currency code. No exchange rates are used. The complete declared estimate stays unknown when required quantities/rates/currencies or explicitly excluded required stages remain unresolved. Purchased complete components suppress separate manufacturing/raw-input costs; made components suppress their retained whole-component purchase price. Unmapped legacy process base/extra costs require one explicit owner with the same quantity/unit. Existing explicit row prices take precedence over a newly assigned stock price; assignment does not perform a currency conversion.

A stock assignment copies its complete portable snapshot. Studio edits/removal do not rewrite plans or old captures; refresh/reassign is intentional. Thread UUIDs, fabric material IDs and supply UUIDs are separate identities. Matching names/SKUs/colors do not combine inventories. Combined demand is compared once across all consistent contributors. Conflicting snapshots, widths or units make sufficiency unknown. A partially unknown demand retains its known lower bound; it is insufficient if that bound already exceeds availability, otherwise unknown. Nothing is reserved or deducted.

Manual supplies have blank/trim/consumable category, a physical unit, optional availability/price/currency, manufacturer/SKU/supplier/location/notes and optional declared width/sheet length. Known dimensions are positive, with width up to 10,000 mm and sheet length up to 100,000 mm. They do not establish equipment compatibility. Existing fabric inventory and thread stock are reused; no second inventory or automatically invented supplier data is created.

## Immutable packet

Capture retains original canonical project/source dependencies, actual referenced preset definitions, plan/declarations and chosen process revisions. Camera/runtime/history, saved Studio shots and the archive list are excluded from source comparison. Collection records are likewise excluded from Studio design comparisons. Original words, styles, glyphs, source artwork, ink/profile identity, bindings and material assignments remain recorded. Process/stock/font/source changes cannot rewrite an accepted revision.

A packet contains:

- `Collection.json`, `Source.json`, `BOM.json`, `BOM.csv`, `Assumptions.json`, `Stock.json`, `Findings.json` and frozen `Review.pdf`.
- Original assets/profiles and actual selected technical cutting files.
- Original schema-38 decoration revision/source/delivery/reference files copied byte-for-byte.
- Original schema-29 Program/Revision JSON bytes and hashes. Old embroidery archives did not store delivery files. At collection capture only, chosen DST/SVG, ordered thread sidecar and reference review are derived once from the verified archived commands/specification. They are labeled **derived at collection capture**, never original schema-29 delivery bytes. There is no live-source/font-dependent re-digitizing.
- `Revision.json` and a file/size/SHA-256 manifest, with explicit no-contact/no-deduction/no-physical-verification scope.

Every later get/export verifies the archive and copies exact stored files, including Review.pdf and all process outputs. It never recreates them with current fonts. Safe relative paths, file lengths/hashes and aggregate budgets are checked before publication. Corrupt or missing input rejects; an existing output survives failure. Copying the complete `.form` package preserves the archive. Removing references with Undo does not automatically delete large immutable assets.

The PDF is an A4 technical review with run/component schedules, source and commercial provenance, explicit assumptions/unknowns, stock comparisons, placement schematics and original garment-size declarations. A bomber schematic is a labeled reference envelope, not an inferred cutting pattern or physically verified placement. Actual-size pattern/cutting and hoop documents retain their own physical page boxes separately. Source-art RGB previews and standalone production CMYK/spot composite/plate export remain on their existing routes; this packet does not silently flatten or relabel them.

CSV quotes delimiters/newlines and neutralizes leading formula prefixes, including whitespace/control prefixes. JSON preserves the original human strings. Digests identify bytes and changes; they are not signatures, approvals or physical verification.

## MCP

No tool is added. Use `form_production_job kind:collection`:

| Command | Result |
| --- | --- |
| `list` | Saved plans and captured packets |
| `preflight` | Read-only explicit `definition` or `plan_id`; canonical plan, rows, findings, currency/stock reports |
| `save_plan` | Save a complete definition with one Undo; `plan_id` must match an included identity |
| `remove_plan` | Remove live plan, preserving old captures |
| `create` | Capture an exactly saved/reviewed `plan_id`, optional same-plan `supersedes_job_id` |
| `get` | Archived `job_id`, current-source/current-plan comparison, optional source up to 1 MB |
| `remove` | Remove a captured reference with Undo; keep referenced lineage ancestors |
| `export` | Archived ZIP/folder, optional absolute path |

```json
{
  "kind":"collection",
  "command":"preflight",
  "definition":{
    "name":"ORBITAL / Collection production",
    "runs":[{"objectID":"PRODUCT-UUID","quantity":12,"includeAttachments":true}]
  }
}
```

Use the returned canonical plan/run IDs before adding `rules`. A rule targets the exact returned row ID, with optional `costBasis`, declared missing `quantity`/`unit`, `unitPrice`/`currency`, portable `stock`, `costSourceRowID`, `excludedReason` and notes. It cannot override a computed/archived quantity. `extras` carry stable UUID, name, optional runID, quantity/unit, rate/currency and supplier/SKU/notes. `layouts` pair runID with actual layout owner objectID. `processes` pair archived jobID with embroidery/decoration kind. Unknown definition properties reject instead of disappearing.

The stock route adds `save_supply`/`remove_supply`; `list` includes optional supplies. The existing thread/equipment/assignment commands remain. Stock-only supply edits preserve project/history and active text drafts. The unchanged default production kind remains embroidery. One full collection definition is saved atomically; collection service operations are deliberately rejected inside object batches before ending input. New project metadata uses schema 45; older projects and library-only edits are not advanced merely by opening these views. Later/higher schemas and existing source guards must survive integration.

## Original NASA demonstrations

**ORBITAL / Flight systems** retains its existing 15 independently editable objects. The native quantity shortcut declares 12 midnight and 8 sage bombers, 6 standalone mission patches and 4 standalone labels. Its BOM contains 20 blanks, 80 attached details and 10 standalone components: **110 physical component occurrences**. Mission patches comprise 26 at 90 mm and 20 at 74 mm. The three source sheets contribute zero purchased units. Generic shell/lining/rib references keep unknown consumption and prices; the blank does not gain invented yardage or hardware measurements.

The original Field gathered skirt addendum uses one of each of its three study sizes. Raw panel envelopes are two each at 550×708, 570×718 and 590×728 mm. Their envelope area sums to 2.45636 m2; actual notched/holed cut area is computed separately. Declared elastic cuts are 725, 765 and 805 mm, totaling **2.295 m** with each 25 mm lap already included. Width/allocation/loss and cost remain unknown until grounded in valid layouts/declarations. These are source calculations, not validated worn fit or actual consumption.

## Bounds and validation

The initial envelope is 100 runs, 2,000 rows, 256 source objects, 256 packet files, 64 MB/file, 128 MB uncompressed packet, 100 review pages and 240,000 review characters. Source encoding has early limits of 20,000 artwork elements, 4 MB text, 200,000 source nodes and 100,000 persisted cloth vertices. Existing process/geometry limits remain stricter where applicable. Oversized or incomplete requested output rejects; nothing is silently truncated. Aggregate unit counts do not allocate one object per manufactured item.

The focused isolated scope passes **32 tests (14 core/graphics and 18 native/service)** covering strict decimals and reported division, CSV, NASA quantities, managed size/lap geometry, cost ownership, explicit required-stage exclusion, persisted stock equivalence, physical cutting exports, independent plan/source comparison, shared stock/layouts, native focused Save/Cancel/Save→Capture, exact Undo/reopen, source/stock/font deletion, copied packages, corrupt archive/destination protection and active text drafts. A deliberately evicted active assembly cache stays unrebuilt and its cloth frame/diagnostics remain exact across collection Save/Capture. Metadata refresh does not visit the print/cloth reconciler. The final isolated optimized regression passes **822 tests (562 core/graphics and 260 native-app)** with zero failures or skips. A separate optimized signed development build is prepared for integration; actual packaged acceptance remains a later gate.

`smoke_collections.py` is guarded to a disposable `.local` library and exercises the real packaged MCP workflow. `verify_collection_packet.py` independently checks Decimal arithmetic, CSV originals/escaping, hashes, ZIP contents, PDF boxes and pinned Pyembroidery decoding. All 13 declared physical fixture pages and native controls are visually reviewed. The 100-run/2,000-row optimized core preflight measures 84.84 ms median and 89.85 ms nearest-rank p95 over 12 iterations; it does not expand manufactured units or generate cloth. Final integrated native/computer-use acceptance remains required after narrow merge; the isolated baseline is commit 777be96, before later optical/presentation/CCD work.

Primary research: [NIST quantity/unit conventions](https://www.nist.gov/pml/special-publication-811/nist-guide-si-chapter-7-rules-and-style-conventions-expressing-values), [NIST message digests](https://csrc.nist.gov/pubs/fips/180-4/upd1/final), and public Foundation Decimal/AppKit/Core Text APIs. The exact division policy is independently tested; Foundation success alone is not treated as proof of exactness. Full production scheduling, purchasing, supplier catalogs, manufacturing calibration and factory-ready technical packs remain open in the governing textile brief.

## Integrated native acceptance

The optimized signed integration passes **881 tests (579 core/graphics/IPC + 302 native app)** with zero failures/skips. Packaged and actual native Save/Capture/Cancel, focused 7-unit and exact 2.125-price edits, displayed-value Undo/Redo, strict invalid inputs and the Studio twelve-decimal supply declaration pass. Native capture is one Undo step and its 110 components/80 attached details are counted once. The native six-page PDF remains sharp at 400%, mouse pan works in all four directions, and native ZIP export matches every frozen archive byte. Actual process restart restores the entire project, Studio stock and exact packet bytes. Physical-source and plan comparisons remain independent.

The guarded packaged run also verifies mixed-currency subtotals, source deletion followed by saved reopen, immutable folder/ZIP output and geometry builds 15 → 15. Independent Decimal/CSV/SHA/ZIP/PDF checks and all seven packaged review pages pass. New PDFs keep headings with their first detail; old captured PDFs remain original bytes. Five ordinary projects and Studio/font preferences remain exact. [Native acceptance evidence](evidence/collection-home-native.json). The overall goal remains active; broader manufacturing/calibration/purchasing requirements are unfinished.
