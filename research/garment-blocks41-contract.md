# Milestone 41 proposal: declared garment blocks and size grading

Status: approved isolated implementation contract, including the corrected raw-height source/guide model below. Baseline is the frozen milestone 40 source.

## Research and scope

The governing textile brief's section 13 asks for reusable garment constructions, numerical measurements, size charts, size-specific pieces and design propagation across sizes. It keeps predictive fit and complete garment simulation as later work.

Primary references support a clear distinction between body data and drafted garment dimensions. [NMSU's Pattern Alteration guide](https://pubs.nmsu.edu/_c/C228/index.html) treats body measurements, ease and resulting pattern measurements separately and calls for checking fit after alterations. [Utah State University's elastic-waist skirt guide](https://extension.usu.edu/sewing/research/youth-elastic-waist-skirt) identifies waist, fullest hip and desired length as inputs and describes a straight, gathered construction. Its specific fullness multipliers, pattern text and illustrations will not be copied.

The official [ISO 8559-1 abstract](https://www.iso.org/standard/61686.html) describes anthropometric measurement definitions; it does not supply a universal ready-to-wear size chart. This feature will not claim ISO conformity, reproduce a licensed standards table, or assign supplier size labels. [FreeSewing's own description](https://freesewing.eu/docs/about/) distinguishes a parametric design from the pattern drafted from measurements. [Seamly2D's official source license](https://github.com/FashionFreedom/Seamly2D/blob/develop/LICENSE) is GPL version 3. This proposal vendors no drafting software, pattern, illustration, size table or new dependency. Its geometry and sample numeric chart will be original FORM code/data.

## First reusable construction

Implement an original **Field gathered skirt block**: two straight rectangular woven panels, a turned elastic casing, a double-turn hem, and an explicitly sized elastic-cut guide. This simple construction avoids silently pretending that a folded A-line casing or shaped waistband is a plain offset. It is a limited garment block, not a fitted skirt sloper, anatomical body model, graded bodice, supplier pattern or verified fit.

Every size has independent editable front, back and elastic-guide source pieces. Front/back each have quantity one and stable four-node paths. They share ordinary matched full-length side seams; no gathered seam or lap joint is falsely represented as a zero-gap cloth constraint. The elastic lap is documented as an explicit overlap instruction, without an assembly/simulation claim.

Inputs, all millimeters:

- Body: declared waist circumference, fullest-hip circumference, waist-to-hip distance.
- Garment: finished body length and additional fabric circumference (`bodyEase`).
- Construction: side allowance, casing clear depth, casing turn-under, double-turn hem allowance, elastic width, declared elastic loop adjustment and lap overlap; optional existing project material IDs.
- Body fabric circumference = `max(waist, hip) + bodyEase`; each finished panel width is half that number. Finished body length is the declared garment length. Hip-level notches sit at casing extension + waist-to-hip distance, divided by the full raw source height; the opposing edge's fraction is reversed.
- The editable panel contour includes the full raw height: nominal body length + casing depth + turn-under + hem allowance. For the default, the actual source is 550 × 718 mm, with side allowances 10 and top/bottom allowances 0, giving a 570 × 718 mm cut. Full side sewing edges are 718 mm, including both folded extensions. Nominal waist fold y38 and hem fold y688 are explicit construction guides; the 30 mm double-turn hem is two 15 mm turns. Top turn-under y8, casing stitching y68 (25 mm insertion opening on the back), and hem first-turn y703 are separately identified. Optional stable-edge-referenced unstitched boundaries prevent blue seam lines on the raw top/bottom. A bounded straight-convex guide resolver intersects physical offset lines with actual cut contours and rejects unsupported topology or intersections.
- Declared elastic loop target = waist + loop adjustment; cut-guide length adds the lap overlap. This target is a requested trim dimension, not a prediction of the elastic's stretched or worn circumference. Casing clear depth must exceed the declared elastic width with explicit clearance.

The default study has three generic labels, **Study 01–03**, centered on original declared inputs waist 760, hip 980, waist-to-hip 200 and body length 650. Suggested initial construction values: body ease 120, side allowance 10, casing depth 30, turn-under 8, hem 30, elastic width 25, loop adjustment -20, overlap 25. The UI/PDF identifies these as editable concept measurements and asks the maker to check material behavior with a test piece. It does not assert that any person or retail size fits them.

## Size chart and propagation

A chart contains 1–12 stable size UUIDs, unique user labels, a base row and integer grade steps. Separate declared increments for waist, hip, waist-to-hip and garment length resolve each row arithmetically; explicit per-row overrides take precedence. No geometry-wide scale factor is used. The default study steps are -1, 0 and +1; original demonstration increments are 40, 40, 5 and 10 mm respectively. These are user-editable sample rules, not industry or population data.

Show body inputs, nominal finished dimensions/ease, elastic-cut target and actual source status together. Multiple sizes coexist in one Canvas/project, grouped and labeled separately. A derived comparison can align their nominal top-center references without moving the editable source pieces. Physical PDFs/SVGs identify every size and preserve existing cut/stitch/guide semantics; existing large-format, tiled, preflight and stock-layout routes continue to consume actual source geometry.

## Persisted model and safe source edits

Reserve schema 41 for optional `Project.garmentBlocks`, consisting of recipe/version, body/style inputs, chart/rules and per-size bindings. Each binding records source object ID, element ID, semantic role, stable node/edge identities and a last-generated fingerprint. Project-level references permit frames/Canvas transfers without embedding stale duplicate chart definitions in copied art. No body measurements or grading metadata belong in 3D render signatures.

Updating an eligible size preserves its element, contour, node, notch and seam UUIDs, artwork style and rigid placement/grouping. The fingerprint covers only fields regeneration owns: actual local geometry, owned manufacturing annotations and generated labels/notes. A changed path/measurement/allowance/name/note, missing source, changed topology or nonrigid inherited transform produces a clear review conflict. A single conflict blocks the entire requested update atomically. No force-overwrite switch or implicit rescaling is supplied. **Create revision** makes fresh independent generated source while retaining the edited original.

Moving/grouping/rotating/mirroring source remains normal Canvas work. A transfer remaps the corresponding project references through the existing mapping, while preserving other publication/assembly links. Ordinary duplication produces independent manual artwork; cloning a complete managed block is an explicit command with fresh size/piece/node/seam identities. Deleting a bound source leaves its chart row in a missing/review state; future update cannot silently resurrect or retarget it. Removing a chart row does not silently delete edited source. Removing a size or complete block detaches its metadata and preserves all artwork. Missing/deleted source remains a conflict and is never recreated by Update. One source piece can have at most one managed binding. Complete rigid transfers remap bindings atomically; a partial or nonrigid conflict never overwrites source.

## Native/MCP and assembly boundary

Add a dedicated **Garment blocks and sizes** native editor, opened from the Canvas sewing actions even when no piece is selected. Use string-bound physical fields, a size table, resolved-dimension comparison, conflict list and explicit **Generate / Update / Create revision** actions. Drafting/preview is read-only. One accepted action changes source plus chart in one Undo and schedules normal autosave. Undo/reopen restore the exact chart and all source links. Reuse `form_edit_artwork` for a deterministic garment-block command and the existing export tools; no top-level AI or hardware tool is needed.

Assembly 36 references source object + element + copy, and Bezier start/end UUIDs with arc fractions. Stable source identities therefore survive ordinary coordinate grading. A different size gets its own independent source/edges/seams; it never silently replaces another size in an assembly. Existing assembly source fingerprints should invalidate/rebuild from changed stitch contours. There will be no automatic mutation of cloth states, rest poses, tension or simulation settings. Full on-fold geometry, positive material snapshots and explicit seam reversal remain assembly requirements.

## Proposed verification and ownership

Own new GarmentBlocks core/controller/native/test/guide files and minimal coordinated Project/schema/reader, artwork-command, transfer/deletion and sewing-action hooks. Preserve camera, viewer and 40 behavior; stay in this isolated source tree until parent integration approval.

Tests must cover exact three-size body/finished/cut/elastic dimensions, differing waist/hip ordering, explicit overrides/grade arithmetic, physical allowances/notches/seam lengths, stable identities and rigid group/mirror transforms, rejected nonrigid/manual edits, atomic multi-size rollback, explicit revision, transfer/delete/duplicate behavior, locked-source checks, real active-field native commit, one Undo/autosave/reopen, unchanged render signatures for chart-only edits, and actual large-format/tiled vector page dimensions. Independently inspect a dimensioned physical output. Body/elastic fit, materials, sewing quality, grading across arbitrary designs and predictive drape remain explicitly unverified.
