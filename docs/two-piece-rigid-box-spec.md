# Two piece rigid box design and construction

November 3, 2026 · Planned work

Provide a complete native workflow for designing and configuring a two-piece setup box: a rigid base and a removable lid, with independent board construction, paper or fabric covering, optional interior lining, surface finishes, and taped or stapled joints. Generate the corresponding board layouts, covering patterns, cut files, material schedules, and assembly drawings from the same editable source.

This is a focused extension of the [packaging design specification](packaging-design-spec.md). A person must be able to complete the workflow through native controls. The requested staple option means **staples passing through board joints**.

## Starting point

The existing [two-piece board-box study](../examples/paper-packaging/04-two-piece-board-box.json) supplies ten positioned boards and an apertured insert. Its parameters relate the lid to the base, and it includes nominal clearance checks. Its wrapping demonstration uses a bonded material ply; it does not generate a continuous covering pattern, turn-ins, corner cuts, or a fastening schedule.

The required extensions are coherent base/lid subassemblies, independently stocked parts, physical covering and lining pieces, anchored joints/fasteners, finished-surface fit, native editing, and layouts of individual parts by material. See the [source audit](paper-packaging-source-audit.md) for the current representation.

Keep the insert optional. The core deliverable is a complete base and lid.

## Native workflow

Offer an editable two-piece setup-box starter and the ability to assemble the same construction using generic part and joint tools. Organize its controls around dimensions and fit, boards, joints, covering, lining, artwork/finishes, and files.

The Table shows the selected base, lid, board, seam, covering piece, or fastener. Linked views show board parts, covering patterns, lining patterns, sections and production sheets. Selecting a piece in any view identifies the same source.

Users can edit values numerically or with appropriate dimension/placement handles. Common options can apply to both halves, with explicit independent overrides for the base, lid, or selected edges. Changing an option previews affected geometry and parts before acceptance.

Provide closed, partially lifted, removed-lid and exploded views. A lid moves as one subassembly with its coverings, lining, tape and staples. Presentation poses retain the construction dimensions, flat sources and camera state.

## Dimensions and finished fit

Default to **finished usable interior dimensions of the base**, with an explicit alternative to hold finished outside dimensions. Show raw-board dimensions and flat cut sizes as derived values. The chosen dimension reference must remain visible.

| Control | Meaning |
| --- | --- |
| Base usable length, width and height | Clear space after lining and floor coverings |
| Base and lid board calipers | Independent floor/top and wall values, with optional linked defaults |
| Lid depth | Finished skirt depth; distinguish it from how far the lid overlaps the base |
| Lid overlap and seating | Closed relationship, intended contact/stop surfaces and axial headspace |
| Lateral running clearance | Gap at each opposed finished surface; label per-side versus total explicitly |
| Cover and lining calipers | Separate material thicknesses and local overlaps |
| Adhesive allowance | Editable effective bond-layer assumption where it affects dimensions |
| Insert clearance | Separate from lid fit when an insert is present |
| Dimensional tolerances | Declared allowances for the selected construction/material/process |

Derive the lid opening from the base’s **finished outside envelope** over the overlap region. For a symmetric straight-sided section, the lid’s finished clear span is the base’s finished outside span plus twice the per-side running clearance. This relationship is a design target, not a universal raw-board cut formula.

Resolve raw lid-board sizes from that target and the selected joints, inward lining and covering turn-ins. Check local seams, folded corners, tape and staple crowns; their buildup can control the minimum clearance.

Keep horizontal fit, vertical headspace, overlap and reveal distinct. The lid must not float or penetrate the base merely to satisfy a pose value. Identify the intended seating relationship and derive dependent values; conflicting locked dimensions require a specific repair.

Changing board, wrap or lining thickness must preserve the chosen dimension reference and update dependent parts. If finished exterior dimensions are locked, increased lining reduces usable capacity; if finished interior dimensions are locked, the necessary outside dimensions and lid fit grow. Never silently change the dimension reference.

Inspect closed fit and intermediate lift/removal positions against the relevant finished surfaces. Report geometric clearances and declared assumptions. Sliding force, material compression and perceived tightness require physical evaluation.

## Rigid board construction

Represent each cut board with a stable identity, material, thickness, quantity, face orientation, grain direction where relevant, contour and joint targets.

The first complete construction uses separate floor/top and wall boards. Expose wall-to-floor relationships and which walls span the ends of adjacent walls. Derive all cut sizes from the selected arrangement; do not reuse one formula for different joints.

Support independently configured base and lid construction, including differing board stocks and calipers. Show uncovered board geometry, joints and cut edges on the Table and in section.

Treat scored blanks and V-grooved constructions as separately accepted follow-ons with explicit cut/score/groove geometry, remaining material, fold relationships and process assumptions. They are outside completion of the initial separate-board workflow. Separate boards must not acquire fictitious crease lines simply to produce a single dieline.

Board layouts contain the actual independent cut pieces. The assembled box, logical part layout and stock-sheet arrangement are separate views; repacking a sheet must not move the canonical artwork or alter assembly relationships.

## Joints, edge tape and staples

A joint identifies the connected parts, their contact/overlap geometry and its attachment method. Glue, tape and staples can be combined where the construction supports them. Assign methods globally, to a half-box, to a seam group, or to individual joints.

### Adhesive

Declare the bonded faces/regions, adhesive identity or descriptive intent, coverage and effective thickness assumption. Preserve glue exclusions for artwork and finishes. A declared bond is not a strength simulation.

### Tape

Model an actual strip crossing the intended joined faces. Expose material, width, length, caliper, placement along the seam, coverage on each face, end offsets, overlaps and inside/outside placement.

Distinguish structural joint tape from visible edge binding. Allow tape beneath the covering or intentionally exposed, with the corresponding order and geometry. Tape thickness and overlaps participate in finished fit and corner buildup.

Generate a tape cutting/placement schedule with piece IDs, quantities, lengths and joint targets. Tape is not represented as a printed stripe.

### Staples through board joints

Provide a generic anchored fastener definition with crown width, wire dimensions, leg length, driving direction, position, orientation, spacing/count, end margins, entry/crown side, exit/clinched side, and clinch/termination intent. Declare required tool and clincher access. The source identifies the actual board stack or receiving regions.

Show crown, legs and relevant inside termination in uncovered and section views. Validate that the proposed staple engages the intended parts and has a supported placement/receiving geometry. A staple positioned visually across a seam is insufficient.

Not every board arrangement provides a valid route or tool access for staples. Flag insufficient receiving material, unsupported placement, exposed unintended leg ends, collisions and incompatible edge distances against declared criteria. Do not silently choose a different joint.

Declare whether staples are installed before or after covering and lining. Their path must pass through the layers present at installation. Allow exposed or subsequently covered staples, with their actual buildup retained. Changing tape to staples updates geometry, quantities, instructions and lid-fit checks. Any adhesive retained alongside the staples remains explicit.

Staple size, spacing and tool assumptions are configurable construction data. Do not reuse corrugated-carton settings or publication-binding placement rules as universal rigid-board defaults.

## Paper and fabric covering

Configure the base and lid independently as uncovered, paper-wrapped, fabric-wrapped, or a supported combination of covering pieces. Preserve mixed constructions such as a fabric lid over a paper-covered base.

Covering material has its own stock identity, caliper, face/back appearance, grain or warp/weft direction, texture scale, backing where present, and sheet/roll format. Reuse LAB’s material system; a finish color does not create a physical wrap.

Generate editable cut patterns tied to the actual assembled board surfaces. Support a complete wrap blank and a construction using a wall band with separate face patches where validated. Record which surfaces each piece covers and its assembly order.

Expose:

- Turn-in allowance by edge and the actual interior region it covers.
- Seam location, overlap, seam direction and whether it is intentionally visible.
- Corner relief cuts, folded/overlapped corner treatment and material coverage.
- Wrapping direction, paper grain or fabric pattern orientation.
- Optional separate bottom/top patches and their overlaps.
- Adhesive regions, registration guides and retained local adjustments.

Physical turn-ins and overlaps are separate from print bleed. Covering patterns must account for edge traversal and material thickness through a declared allowance method. Do not prescribe a universal allowance for all paper, fabric, backing and adhesive combinations.

Show covered board edges, interior turn-ins, corner stacks and seams in the assembled geometry. Warn about exposed unintended board, insufficient coverage, self-intersection, excessive local buildup and mismatched pattern orientation. Preserve flat-to-surface artwork correspondence as dimensions change.

Changing from paper to fabric must update material behavior and applicable construction allowances, not only surface appearance. Retain manual pattern edits where their references survive; identify affected edits for repair.

## Interior lining and unlined options

Configure the base and lid independently. Provide none, floor/top-panel only, walls only, and full interior lining, with explicit selected-region overrides.

An unlined interior displays the actual board, turned-in exterior wrap, joins and visible fastening. Disabling lining removes its pieces, thickness and quantities while preserving the covering’s turn-ins.

Lining has its own material, caliper, pattern/texture direction, edge setback, corner treatment, seams, overlaps and attachment. Define whether it covers or stops short of the turn-ins and fastening regions. A floor liner, wall band and lid-top liner can be separate editable pieces.

Include lining thickness and overlaps in usable capacity and lid opening. Generate independent liner cut patterns and quantities. Keep bonded lining distinct from a loose removable liner or fitted insert.

Re-enabling a saved lining option restores its authored configuration where references remain valid. Undo/Redo and variant switching must preserve all related sources.

## Artwork, finishes and rendering

Author outside and inside artwork on physical covering/lining pieces or supported exposed board surfaces. Provide upright face views and flat patterns with consistent orientation. Preserve actual artwork size and explicit panel/edge anchors.

Support printing, foil, emboss/deboss, surface coatings and other implemented finishes through shared material/finish assignments. Store the target surface, artwork mask and intended process. Recesses or relief affecting visible geometry must remain inspectable in the actual model.

Show glue exclusions, seams, turn-ins, cuts and fasteners when reviewing artwork placement. A logo on a lid must remain attached after resizing or opening it; changes that remove its target require repair.

Review fabric weave, paper grain, exposed board, folded corners, taped edges, staple crowns, lining and finish response at close range. Shared materials should also benefit [book covers and cases](book-publication-rendering-handoff.md). A polished render does not replace the editable construction.

## Construction files and material layouts

Export a revision-linked construction packet for both halves and any selected accessories.

| Output | Required content |
| --- | --- |
| Board cut list | Part ID/name, base/lid ownership, material, thickness, quantity, cut dimensions/contours and grain |
| Board cutting files | Actual-size nominal geometry with separate cut, score or groove channels where applicable |
| Covering patterns | Paper/fabric cut outlines, turn-ins, corner reliefs, seam/overlap guides, orientation and piece IDs |
| Lining patterns | Independent cut pieces, placement, setbacks, orientation and quantities |
| Tape schedule | Strip sizes, quantities, seam targets, side and order |
| Staple schedule | Fastener specification, count, position/orientation, joint targets, entry/exit faces, termination, tool access and installation order |
| Artwork and finish files | Registered artwork and separate finish masks, with technical guides excluded from final printing |
| Material layouts | Separate sheets/rolls by stock, quantities, grain/rotation constraints, spacing and usage |
| Assembly drawings | Exploded views, part IDs, joint details, sections, covering/lining order and finished dimensions |
| Construction manifest | Editable source snapshot, parameters, material references, assumptions, preflight results and file hashes |

Provide SVG cut/pattern outputs, dimensioned PDF proofs/instructions, and machine-readable source/schedules using the existing export foundation. Additional formats should be declared and validated individually.

Separate nominal design geometry from any tool-compensated output. Kerf, cutter/groove settings, bleed and production margins belong to explicit process settings; avoid double compensation. Staple placement marks are assembly information, not automatically drill/punch instructions.

Lay out independent pieces by material with optional grain-respecting rotations. Calculate part quantities and material area/length/count from the chosen construction; any waste allowance is explicit. Do not pack the example’s sparse canonical-net rectangle as if it were a single required blank.

Keep technical labels and registration marks independently controllable. Repacking sheets preserves piece-local artwork, finish registration and dimensions. Existing exported revisions remain unchanged; later design edits require a new packet.

Assembly instructions follow the declared construction: join boards, attach specified reinforcement, apply covering and lining in the chosen order, then review fit. Do not reuse folding-carton instructions for a separate-board box.

## Generic implementation requirements

Extend shared assembly, planar construction, material layers, surface mapping, anchored joint/fastener and layout capabilities. Store the box definition, option sets, patterns and examples as project/library data under [AGENTS.md](../AGENTS.md).

The current one-stock-per-construction representation and independent component roots need extensions or composition through independently stocked objects. Base/lid parent transforms, cross-part dimensions, local layer buildup and real covering attachment must remain source data.

Native controls and MCP share validation, persistence and Undo. Option changes update geometry, fit, artwork review and all dependent files coherently. Invalid edits retain the accepted construction and identify the affected parts.

Reuse the existing box study through an explicit, undoable adoption path. Preserve existing artwork, stock choices, source identities and scenes. Add new assumptions visibly rather than silently reinterpreting saved clearances.

## Delivery and acceptance

Implement in connected stages: board assemblies and finished dimensions; joints/tape/staples; real covering and optional lining; artwork/finish integration; complete construction files. Each stage needs native controls and inspectable source. Complete all stages before calling this box workflow finished.

Preserve at least these materially different editable configurations:

1. Paper-wrapped, taped joints, both halves unlined.
2. Paper-wrapped, independently lined base and lid.
3. Fabric-wrapped with contrasting paper lining and visible turn-in details.
4. Staples through supported board joints, reviewed uncovered and then covered.
5. Mixed paper/fabric halves with one half unlined and partial-depth lid overlap.
6. Different base/lid board calipers and a deep lid, with changed dimensions and fit.

Exercise a full native design session: choose the construction, edit board arrangement and dimensions, change wrap material, toggle lining, place tape or staples, position artwork, inspect closure and export the files. No agent-only setup steps may substitute for native operation.

Verify changes to size, caliper, covering thickness, lining, seam location, tape width, staple placement and lid depth propagate correctly. Preserve distinct running, axial and insert clearances. Reject impossible dimensions, unsupported staples and collisions without losing the accepted design.

Compare original references with actual app views closed, partially lifted, lid removed, underside, uncovered boards, exploded assembly and close-up sections. Inspect silhouette, corners, wrap/lining edges, joins, fasteners, artwork and material response; revise discrepancies and retain evidence.

Check every output’s scale, part identity, material, quantity and registration against the model. Independently review the board cut list, covering and liner patterns, tape/staple schedule and assembly order. Verify save/reopen, Undo/Redo, variant retention and invalidation of stale outputs.

Select actual materials and construction references before accepting physical allowances. Geometric fit and rendered fastening do not establish manufactured bond strength, staple performance or a desired sliding feel. Record physical sample findings separately. No printing, cutting, motion or heating command is part of this specification.

## Construction references

- [Horda rigid-box manufacturing](https://www.hordamachinery.com/machine-knowledge/how-are-rigid-boxes-made) describes distinct structural preparation, covering, turn-in and lining stages.
- [NAPCO terminology](https://napcousa.com/terminology/) defines base/lid, telescoping and covering terms; example measurements are not universal allowances.
- [TALAS bookcloth guidance](https://blog.talasonline.com/post/paper-backed-vs-starched-bookcloth) distinguishes paper backing from starch treatment, informing the separate material-construction controls.
- [Deluxe Stitcher box machines](https://www.deluxestitcher.com/machines-box) documents wire stitching and joint/access-specific equipment, including solid-fibreboard applications. It does not establish that every rigid-board joint can be stapled.
