# Studio thread stock and revision-linked production jobs

FORM now records reusable Studio thread stock and embroidery equipment declarations, assigns portable thread snapshots to designs, captures immutable production revisions, and creates local review packets. Open **Studio Library → Threads & embroidery equipment**, or select a configured embroidery decoration and open **Production jobs & packet…**. The same operations are available through `form_textile_stock` and `form_production_job`.

This is an initial local embroidery-production workflow. It does not connect to machines, queue work, reserve or deduct stock, infer prices, or convert user-entered approvals into verified sew-outs. Collection-wide scheduling, general fabric/ink costing, supplier purchasing, and other manufacturing-process packets remain in the full textile goal.

## Shared records and portable assignment

Studio thread records include name, color, brand, SKU, supplier, fiber/specification, location, available meters, spool length, spool price/currency, and notes. Every commercial/quantity field is optional. A price needs its declared three-letter currency; cost per meter additionally needs a positive known spool length. Blank values stay unknown. The library starts without invented thread stock or embroidery machine profiles.

Assigning a Studio thread copies its complete record into an `EmbroideryThread.stock` snapshot, including the recorded inventory and price. It sets the design thread's color/name/catalog identity. The snapshot travels with the project and its source digest. Editing or removing the Studio record does not rewrite assigned projects or captured jobs. Reassign to refresh explicitly; unlink the snapshot before freely recoloring a custom thread. Native draft assignment and MCP assignment use the same model validation. Direct assignment is one Undo and respects the decoration lock.

Studio equipment declarations include manufacturer/model, supported hoop dimensions, file extensions, descriptive needle count, notes, and an explicit user-verified-declaration flag. No address, access code, network protocol, or connection action is part of these records. Compatibility compares the selected design's hoop axes to declared capacities and checks DST support when DST is requested. It never assumes rotation. Missing declarations yield **Unknown**; insufficient dimensions or an absent declared format yield **Incompatible**. Covered values yield **Declared compatible**, with verification state stated separately. Sequential thread changes do not imply machine scheduling or physical compatibility.

## Measured lengths and explicit estimates

Needle length is calculated directly from consecutive generated **stitch** commands, using their physical 0.1 mm coordinates. Underlay and lock movements are included and separately measured. Jumps, trims, and color changes do not become sewn thread length. This is geometric needle-path length, not measured machine thread consumption.

An upper-thread consumption estimate requires both user-supplied assumptions:

`job meters per color = quantity × (needle-path meters per item × upper-thread factor + extra meters per color/item)`

The multiplier is bounded at 1–20. The allowance may explicitly be zero, but a missing allowance remains unknown. Bobbin thread, stabilizer, fabric losses, blanks, and other materials require explicit BOM entries or assumptions; they are not silently folded into this formula.

Thread cost needs estimated consumption plus the assigned spool price, length, and currency. Base-component cost, extra BOM quantities/unit costs, labor minutes, and hourly rates are independent explicit inputs. Known priced subtotals remain visible, but a complete total stays unknown while required costs or labor are unknown. Mixed currencies are retained separately without an invented exchange rate. These are indicative calculations from declarations, not vendor quotations or financial commitments.

When several palette entries use the same stock record, their estimated demand is combined before comparing it with available meters. Conflicting assigned stock snapshots make combined availability unknown. Stock sufficiency is a statement about captured declarations; nothing is deducted or reserved. User-reported sample usage is recorded separately and does not overwrite assumptions or inventory.

The default BOM scope is one selected decoration/component per job item. An attached garment is captured as placement/specification context; its purchase quantity and cost are not automatically added for every patch. Add those components explicitly when that matches the intended production run.

## Immutable revisions and user records

A captured job stores its object identity, source digest, quantity, program digest, revision digest, and user records in project metadata. Its exact needle program and complete production specification are saved as immutable, content-addressed JSON files under the project's `Production` directory. The specification captures resolved editable source artwork, object and material declarations, garment placement context, assigned thread snapshots, equipment declaration, output choices, measured usage, and explicit assumptions.

The program is not regenerated when exporting an old job. Source changes, installed-font changes, library edits, and deletion of the live object cannot silently rewrite its needle commands. Copying the complete `.form` package preserves the job and its portable assets. SHA-256 checks reject missing or altered archives instead of replacing them with a new interpretation. A failed packet preflight preserves an existing output. Unreferenced immutable files may remain after Undo, like existing object revision files; publishing job references is one project edit.

Create a new job or explicitly link it through `supersedes_job_id` for a new production revision. Lineage must refer to the same object and cannot cycle. Quantity, assumptions, equipment, and snapshots contribute to the revision digest independently of the live source digest.

Sample, quality, status, and note records carry that captured source digest, date, optional author, observations, optional outcome, and optional user-reported consumption. Quality **Pass** does not automatically change job status. **Approved** and **Completed** are explicitly user-recorded status events; they do not create machine telemetry, inventory changes, or an automatic sew-out-verification flag. Records and capture support shared Undo and autosave.

## Local review packets

Export a ZIP or a new folder. Every packet includes:

- `Job.json`, `Revision.json`, and `Estimate.json` with source/revision/program identity, declarations, assumptions, user records, and unknowns.
- `Review.pdf` with specifications, measured thread schedule, cost assumptions, declared compatibility, and user history. Its final page is an actual-size hoop drawing with 16 mm margins; needle positions keep their physical origin and scale.
- Chosen actual outputs: `Needle.dst` with ordered `Needle.threads.json`, `Needle.svg`, and/or `Program.json`. SVG and the review hoop omit travel as thread. DST retains real travel/trim/color-change semantics.
- `Manifest.json` listing each file's size and SHA-256, plus the packet digest and explicit no-contact/no-deduction/no-automatic-verification flags.

ZIP contents use fixed safe relative names without AppleDouble/resource-fork side files. All files are staged before replacing a ZIP. Existing directories are not overwritten. The report is bounded at 100 text pages, and individual immutable assets/packets have explicit byte caps. No packet submits or starts equipment.

## MCP operations

`form_textile_stock command:list|save_thread|remove_thread|save_equipment|remove_equipment|assign_thread` manages shared Studio declarations and portable assignment. `assign_thread` takes `object_id`, integer `thread_index`, and `stock_id`.

`form_production_job command:list|create|get|event|export` manages project jobs. Creation takes `object_id`, optional quantity/name/equipment/lineage, explicit output choices, and assumptions. `get` reports whether the current source matches, changed, is missing, or cannot currently be regenerated. `event` appends a user record against the archived source. Export reads the archived assets and accepts `format:zip|folder` and an optional absolute path.

## Validation

The focused schema-29 suite passes 11 tests: five core calculations/validation tests and six native-app/service tests. It checks actual needle lengths, unknown and mixed-currency costs, combined stock availability, declarations without machine assumptions, portable assignments, lock/Undo/rollback, asset hashes and corruption, user-record source guards, source deletion and complete-package portability, autosave, clean ZIP contents, physical PDF pages, and exact source/inventory preservation.

The three-page review proof was rendered with Poppler and visually inspected; its final **132 × 132 mm** page contains a **100 × 100 mm** hoop at 1:1. A separate Pyembroidery 1.5.1 reader independently matched the packet's **506 DST records, 462 stitches, and two thread passes** with ordered sidecar colors and physical bounds. See [validation](validation.md) for retained focused artifacts and later integrated acceptance. `scripts/smoke_production_jobs.py` exercises the packaged workflow in a guarded disposable `.local` library, including changed/deleted source, Studio edits/removal, samples, unknown costs, archived packet hashes, actual-size PDF, ZIP portability, reopen, and independent decoding.
