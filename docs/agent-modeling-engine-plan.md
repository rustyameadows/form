# Agent modeling engine implementation plan

Status: core implementation verified; final acceptance remains partially complete. October 28, 2026.

Implementation and verification are on `codex/agent-modeling-engine`. The prior release snapshot covers 1,227 methods; the generic paper-rendering correction adds three passing regressions and 33 focused checks. The fixed-case warm benchmark meets its target at 2.027× faster aggregate median and 11.9% lower p95. All 17 fabric workflows pass, including the complete original 240-frame sewn-assembly run. The [sample audit](sample-visual-validation.md) checks all 12 shipped overviews and records remaining inside-frame limitations. See the [verification record](agent-modeling-engine-validation.md) for evidence and measurement limits. Unchecked conditions below remain open.

Make LAB's existing modeling engine fast and dependable enough for an agent to construct a model, evaluate it, inspect the result, measure it, repair it, and verify its parameters in a short repeatable loop. The user receives an editable model whose controls, construction relationships, artwork, and saved source continue to work after the agent finishes.

Build on the installed OCCT kernel, existing feature evaluator, project command engine, and RealityKit display. The next push improves that working path and makes construction knowledge authorable project content.

## Required outcome

An agent must be able to introduce a previously unseen design through LAB's supported tools using the same installed application. The agent and end user never edit application source, register a product type, or install a model-specific runtime plugin. Product names and construction choices belong in authored models and reusable examples.

Use conventional modeling operations, parameter expressions, geometry, transforms, and connections through the existing agent tool surface. Publish their schemas, units, supported fields, and concise examples through capability discovery so the agent can work from the tool descriptions. Extend this surface coherently as general capabilities become necessary.

Model definitions, exposed parameter controls, assertions, component identities, and artwork bindings are saved project content. Native controls and agent commands evaluate that same source. All evaluation and display run through LAB's installed runtime.

Dielines and sewing patterns share the same Canvas, physical source geometry, selection and editing conventions, artwork ownership, parameter validation, and assembly navigation. Cut/fold and cut/seam/stitch relationships express different material processes within that shared experience. Exact solid evaluation, rigid folding, and deforming cloth retain the calculations appropriate to their material while sharing source identity, commands, revisions, diagnostics, and publication. Fabric workflows participate in the same modeling loop.

The core loop is:

1. Submit a complete model or an atomic revision to an existing draft.
2. Evaluate affected geometry and retain the last valid result.
3. Return revision-linked diagnostics, measurements, and requested images.
4. Repair the draft using the reported feature and input context.
5. Check declared parameter cases and geometric requirements.
6. Publish the accepted revision in one Undo transaction.

## Current starting point

The implementation already has useful geometry and lifecycle machinery. Preserve it while addressing the gaps below.

| Area | Existing capability | Work this push must deliver |
| --- | --- | --- |
| Parametric geometry | Named parameter expressions, typed feature dependencies, profiles, solids, cuts, finishing, patterns, multiple outputs, and selective rebuilding | Efficient revision editing, repairable failed drafts, and parameter relationship checks |
| Evaluation | OCCT validation, cached immutable shapes, cancellation, and retention of an earlier valid result | Interactive previews that avoid archival work and expose actionable failure context |
| Agent inspection | Planning, status, topology, clearance, and rendered previews | Independent evidence requests and a concise combined evaluation report |
| Surface identity | Persistent feature/output IDs, revision-pinned face ordinals, and limited semantic face selectors | Durable authored targets and multiple named physical artwork surfaces |
| Paper construction | Registered flat artwork, panels, cut edges, folds, joins, and folded previews | Agent-authored construction topology and relationships using general operations |
| Fabric and sewn construction | Fabric repeats/colorways, sewing contours and allowances, material layouts, pattern assemblies, cloth, attached artwork, and decoration/production records | Shared parameter checks and Canvas interaction, preserved source/material coordinates, and complete textile regression coverage |
| Project integration | Guarded publication, immutable assets, save/reopen, and shared Undo | The same guarantees for revised models, surface bindings, and general constructions |

Implementation anchors: [feature graph](cad-feature-graph.md), [operation contracts](cad-operations.md), [CAD coordinator](../Sources/FormApp/CADModelCoordinator.swift), [evaluator](../Sources/FormCADModeling/CADModelEvaluator.swift), [artwork links](../Sources/FormCore/ArtworkLinks.swift), and [paper construction engine](../Sources/FormCore/PaperConstructionEngine.swift).

## Delivery sequence

### 1 Measure the loop and make previews cheap

Create a reproducible baseline harness around the real `form_cad` path before changing it. Exercise cold construction, repeated warm parameter edits, a local feature change, a failed edit followed by repair, and publication. Use fixed fixture definitions and record the app revision, hardware, build configuration, and requested display quality.

Instrument validation, exact evaluation, tessellation, render preparation, image capture, and publication separately. Report per-feature cost, rebuilt feature IDs, cache reuse, elapsed time, and retained resources. Measure tool submissions and elapsed time from an edit request to usable evidence, including asynchronous waits.

Measure real native parameter interaction as well. Record event-to-source and event-to-visible-result latency while dragging representative live controls. Report draft editing separately where CAD requires an explicit Preview. Exercise rapid changes, cancellation and superseding previews so delayed work cannot replace the latest result.

Split interactive evaluation from durable publication. `CADModelCoordinator.prepare` currently calls `stageSources` with `includeSTEP: true`, stages geometry, and copies preview assets before a review becomes ready. Keep the exact result and display buffers in a bounded review session; create durable project artifacts when publishing. Generate additional archival output only when an operation requires it. Retain source verification and commit-time revision checks.

Acceptance:

- [x] The harness records cold and warm median/p95 latency, tool submissions, cache reuse, and resource use for the same fixture cases before and after the change.
- [x] The representative warm-edit benchmark targets at least a 2× reduction in aggregate median edit-to-evidence latency with no aggregate p95 regression. Compare identical fixture definitions, display quality, evidence requests, and cache conditions; retain per-case median/p95 results alongside the aggregate.
- [x] Unrelated features reuse exact geometry. Artwork, material, camera, and canvas-arrangement changes retain geometric caches when source geometry is unchanged.
- [x] Rapid superseding edits, cancellation, and project switches keep resources bounded and prevent stale results from becoming accepted or published.
- [ ] Native mechanical, authored-construction and fabric controls have recorded real interaction measurements, and rapid changes preserve the latest requested state.

Verification status: native keyboard input, intermediate GPU frames, explicit CAD Preview, Cancel and rejection of late work pass with the production controls. Held-pointer latency is still unverified: CUA supplied mouse events with no held-button state. A human gesture reached the probe, but its original endpoint check rejected it before saving; the rebuilt probe now accepts any meaningful changed fold value and uses the corrected visible renderer. A complete saved measurement is still pending. The benchmark records cold median/p95 with one observation per case (three aggregate); RSS is sampled at case boundaries, and staged-file measurements are unavailable. These limits do not change the demonstrated warm benchmark result.

### 2 Make drafts easy to revise and failures easy to repair

Give each model review an explicit source revision. Support an atomic batch of parameter and feature edits against an expected revision, with one evaluation after the batch. Preserve the complete failed draft and allow the agent to inspect and repair it directly. Retire superseded private previews without discarding the last valid model or filling all review slots.

Carry structured evaluation failures through the coordinator. Include a diagnostic category, model and draft revision, failed feature ID/name/operation, relevant input IDs and resolved values, validation or kernel reason, and last valid revision. Supply concrete repair context such as a stale reference or violated bound; preserve the original error text for inspection.

Separate model evaluation from evidence tasks. Topology, clearance, and render currently share a mutable task/token/result slot. Give evidence requests independent identities and cancellation, all pinned to an immutable evaluated revision. A bounded evidence request should gather selected measurements, topology summaries, and standard views in one submission and return a combined report through one bounded wait/status path.

Acceptance:

- [x] An agent creates an invalid fillet, reads the structured failure, repairs that failed draft, and publishes once without resubmitting the complete model or losing the valid result.
- [x] A multi-feature patch evaluates once; stale expected revisions reject without partial mutation.
- [x] Multiple requested renders and measurements complete without cancelling one another or overwriting earlier evidence.
- [x] Reports identify the evaluated revision, output/feature IDs, units, requested checks, and image references. The agent can submit an edit plus its evidence request together.

### 3 Verify parameter relationships and model requirements

Extend the existing parameter/expression validation with authored cross-parameter requirements. Express relationships such as wall thickness fitting inside the body, a hole fitting within its mounting region, or a declared mating gap remaining positive. Add the bounded arithmetic, comparison, and conventional mathematical operations needed by the acceptance constructions, with explicit units and deterministic errors.

Add a batch validation operation using explicit named parameter cases, minimum/default/maximum cases, and selected combinations of interacting parameters. Evaluate each case independently of the accepted project model. Bound case count, runtime, and retained geometry; support cancellation and progress reporting.

Attach geometric checks to the cases: expected output/solid counts, closed-solid validity where applicable, physical dimensions, volume, declared clearance or interference, and surface-binding resolution. Return the failing parameter values, violated requirement, first failing feature, and relevant measurements. Distinguish the finite tested cases from a proof over every possible parameter value.

Reuse the same saved parameter requirements for procedural fabric and construction recipes. Sewing cases check source contour validity, allowances, seam references, material coordinates, and attachment resolution. Cloth checks retain their declared solver and preparation conditions rather than applying closed-solid criteria to a fabric surface.

Acceptance:

- [x] A fixture that succeeds at its default and fails at a boundary produces a reproducible, repairable report with the exact case values.
- [x] An agent repairs the construction and reruns the same cases successfully.
- [x] Batch validation leaves the accepted model, artwork, history, and user selection intact.
- [ ] All declared cases have explicit outcomes; cancellation or an exceeded budget cannot appear as a successful check.
- [ ] Fabric/sewing parameter cases evaluate source contours, allowances, seam references, material coordinates and attachment resolution through the shared case lifecycle.

Verification limit: aborted CAD/construction batches currently fail the whole request closed, but do not retain explicit outcomes for every unattempted case. Shared fabric expression requirements and the full fabric regression suite are implemented; a fabric source-geometry/seam/attachment case runner is not yet demonstrated.

### 4 Preserve intended targets and connect named surfaces

Extend the current feature/output identities with authored datums and geometric selectors for intended faces and edges. Resolve them against the current feature result, retaining provenance and revision context. Expose the kernel topology descriptors needed by those selectors, including normals, axes/radii, and adjacency where applicable. Reuse unique axis-based selectors where sufficient. A split, merge, missing target, or ambiguous match must produce a targeted unresolved reference rather than silently attaching to another face.

Allow models to expose multiple named planar physical artwork surfaces. Implement their boundary and local-frame mappings, with a persistent identity, producing feature/component reference, readable orientation, and an explicit source-artwork binding. Resolve these through one shared path for Canvas, Table, and model inspection. General CAD models must receive artwork without relying on a recognized recipe name or a guessed width/depth pair.

Use the existing artwork source ownership, physical units, typography, and Undo machinery. Preserve independent panel artwork and construction-wide artwork that crosses panels. Store trim, safety, and bleed intent explicitly and show how it maps into the flat construction, including overlaps requiring review.

Acceptance:

- [x] An authored object exposes at least three independently addressable surfaces with upright text, and updates correctly in Canvas and Table.
- [x] Dimension edits preserve uniquely resolvable feature targets and surface bindings. Removing a surface or creating an ambiguous match returns the affected identities and an actionable review state.
- [x] Changing a parameter preserves the intended physical artwork scale and orientation; any required placement review is explicit.
- [x] Surface edits, bindings, named resources, and source ownership survive publication, Undo/Redo, duplication, and save/reopen.
- [ ] Trim, polygon safety and bleed intent map into flat/upright construction views, with explicit collapse and overlap review.
- [ ] Inside physical-frame editing displays upright content while preserving the existing front-registered canonical source and print/export registration.

### 5 Make construction relationships authorable

Expose general planar components, cut boundaries, hinges, connections, and parameter-driven placements through the existing modeling tools. Reuse profile geometry, expressions, transforms, component identity, and the current rigid-fold calculations. Keep flat outlines and regions as authored 2D construction source; use existing profile/extrusion operations for finite-thickness panel solids. Preserve positive-volume validation for exact solid outputs while allowing the same source to generate its 2D proof.

The authored model supplies its component arrangement, hinge axes, fold values, connection targets, stock dimensions, and surface coordinates. The evaluator operates on these relationships without dispatching on a product name. Joins carry their intended connection and measurable alignment requirements. Fold-case checks report geometric overlap/interference according to the model's declared conditions.

Make the envelope and carton constructions ordinary reusable model examples on this path. Preserve existing saved paper projects with a deterministic compatibility path and explicit conversion that retains artwork coordinates, annotations, and identities. New constructions use the general authoring path.

Expose a construction's derived flat layout and named upright surface frames on the shared Canvas, using the surface resolver from milestone 4. Panel navigation selects or frames those sources. Editing upright artwork updates the flat representation and assembled Table object. Parametric controls continue to own construction geometry; the flat layout supplies a linked proof of that geometry and artwork.

Use the existing vector Canvas for sewing pieces and dielines with common tools, source navigation, physical units, selection, artwork editing, and Undo behavior. Preserve sewing-specific seam/allowance/grain/notch controls and paper-specific hinge/crease/join controls as contextual properties. Preserve fabric repeat phase, source artwork, and material coordinates through flat-to-assembled changes. Every change to these shared paths must exercise both rigid and sewn constructions.

Acceptance:

- [x] After the generic capabilities ship, an agent authors a new fold-and-glue construction through tools using the same installed build, with no product registration or application source change.
- [x] The agent changes its dimensions, inspects several fold positions and its flat layout, and checks declared joins through revision-linked evidence.
- [x] Upright panel artwork and an image spanning two panels share the intended sources across flat and folded representations; one edit has consistent Undo.
- [x] The new model saves/reopens with editable parameters and construction relationships. Existing paper projects retain their appearance, artwork, and editability.
- [ ] Declared panel-pair checks measure folded finite-thickness clearance/interference, with explicit allowances for intended hinge/glue contact.

Verification status: all four listed construction checks pass. Fold cases validate flat geometry, requested poses and declared neutral-plane anchor gaps. Exact interference between folded, finite-thickness panel solids has not been demonstrated; the connection checks do not establish collision-free folding.

### 6 Prove complete agent workflows and ship the tools

Run the real local bridge against a packaged app and an isolated project library. Keep complete model definitions and parameter cases as fixtures, with scripts that reproduce numerical checks and capture the relevant native views. For each acceptance model, retain a concise record of tool submissions, failures, repairs, timings, parameter outcomes, and final source revision.

Use five focused workflows:

| Workflow | Required proof |
| --- | --- |
| Enclosure with a fitted lid | Parameter-driven walls, openings and attachment features; measured mating gap; local repair of an intentional failed feature; dimension changes preserve intended targets |
| Curved vessel | Profile/revolution and wall construction; valid opening and solid; interacting height/radius/thickness cases; useful failure feedback and selective rebuilding |
| Previously unseen folded package | Agent-authored panel arrangement and hinges; cut/fold relationships; named upright artwork surfaces; flat/folded consistency; parameter and connection checks |
| Fabric and sewn assembly | Existing fabric repeat/colorway and sewing-piece artwork remain editable on Canvas; allowances/notches/grain, seam identities, material phase and attached decoration remain connected to the assembled cloth; preparation/Run/Stop/Reset, dimension edits, persistence and Undo remain correct |
| Reference-led organic object | Freeze an independent multi-view visual reference before modeling; author curved, blended forms and fine detail through familiar geometry operations; compare actual front, top and perspective renders against the reference and record visual mismatches alongside geometric validation |

Use additional construction briefs after the runtime is frozen to verify that success generalizes beyond the checked-in examples. New models are supplied as project content through the published tool surface. Record any missing generic capability as an engine defect and rerun the gate after addressing it.

Acceptance:

- [ ] Each workflow completes construct → evaluate → inspect → measure → repair → parameter validation → publish through agent tools.
- [x] The same installed build accepts the additional construction briefs without source edits or model-specific plugins.
- [x] Native controls can edit the resulting parameters, and save/reopen plus Undo/Redo preserve the accepted source and its bindings.
- [x] Existing geometry, cancellation, stale-publication, artwork, and project-lifecycle regressions pass. Native Canvas/Table checks confirm the rendered model and surface orientation.
- [x] Fabric repeats and colorways, sewing/curved-pattern geometry, cutting/sewing layouts, textile decoration and embroidery, garment blocks, pattern assemblies, cloth preparation/simulation/attachments, material assignments, and saved production records pass their existing relevant regressions. Native and bridge checks verify editable flat sources, assembled appearance, save/reopen, and shared Undo.
- [x] Tool descriptions and focused examples match the shipped behavior, including diagnostics and parameter validation. The benchmark demonstrates the latency target from milestone 1.
- [ ] The organic example passes a documented multi-angle visual review of silhouette, proportions, blend quality and fine detail. A valid solid alone is insufficient.

Verification status: the enclosure, curved-vessel, unfamiliar folded-construction and fabric workflows have their recorded tool and regression evidence. The organic candidate has been repaired, evaluated, rendered and committed as model data, but its complete exposed-parameter case campaign and visual acceptance are not yet demonstrated. Earlier organic renders remain recorded visual failures; a later valid solid or pending comparison does not close that gate. Native parameter checks here establish keyboard and Preview/Cancel behavior; held-pointer measurements remain open under milestone 1.

## Execution order and completion

Deliver milestones 1 and 2 first so subsequent modeling work immediately benefits from faster previews and better feedback. Build milestone 3 on that evidence/reporting path. Milestone 4 establishes the identities and mappings required by milestone 5. Run the milestone 6 workflows from the first change onward and use the final packaged run as the release gate.

Implement general geometry or authoring additions when an acceptance workflow exposes a concrete gap. Each addition must compose through the same parameter, revision, inspection, and persistence paths and work in more than its motivating example.

Keep implementation changes in small reviewable commits with the relevant regression and workflow evidence. Update this checklist and the existing capability documents as each milestone is verified. This push is complete when agents can author unfamiliar models, repair failures, validate meaningful parameter cases, and hand off persistent editable results through the installed app, with the measured iteration improvement and connected artwork behavior above.
