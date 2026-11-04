Reusable physical material studies

Current delivery review: all eight authored cases and their dedicated controls
are accepted in .local/cycles-materials/diagnostics/root-final-review.json and
root-final-control-review.json. Final images use 3000x2000 pixels and a 512-sample
budget with adaptive noise threshold 0.01. Each render record retains its actual
sample count; the satin-back control finished adaptively at 224 samples.
Rejected warm-vellum and grainy-foil attempts remain in the history alongside
their accepted replacements. Acceptance covers the documented material studies;
it does not claim measured manufacturer BRDFs, calibrated cloth mechanics or
validated sew-outs. See docs/bundled-cycles.md for the installed candidate 6
engineering evidence and current delivery/report links. The historical candidate 6
test matrix predates final material acceptance; its old pending notes are not
the current review status.

The portable review is inside the authored study package at
Exports/material-review/index.html, with optics.html beside it. Its final summary
records 8/8 accepted cases, 131 retained main attempts and 97 explicit reviews;
the optical-control report retains 67 attempts and explicit reviews. The current
24 main images plus 17 controls are hash-verified in
.local/cycles-materials/diagnostics/final-current-runtime-verification.json.
Original-project restoration is recorded in the same diagnostics directory as
final-original-preservation.json. The current aggregate is
.local/cycles-app-validation/final-delivery.json; docs/bundled-cycles.md provides
clickable links to this installation's reports.

corpus.json contains eight material cases, manufacturer/supplier specification
links, original photographic reference URLs, direct pixel-review observations,
two authored geometry variants per case, and visual acceptance criteria.
Cotton explicitly compares a published approximately 1.0 mm / 600 gsm stock
with a clearly labeled 0.5 mm / 300 gsm study assumption. Woven cloth preserves
independent 0-degree and 90-degree material records: the latter rotates both
texture mappings and the anisotropic tangent, keeping UVs and repeat size fixed.

Copyrighted manufacturer photographs are links only. Their pixels are not
included in this directory or copied into the distributable project. The assets
directory contains CC0 texture maps with exact hashes and source/license URLs in
assets/provenance.json. These maps are donor appearances, not scans of the named
manufacturer materials. Every optical coefficient and unmeasured caliper is
identified as an estimate. Published paper opacity is not treated as shader alpha.
Recorded woven/knit rounds through candidate2 use the official 2K
rough_linen/cotton_jersey normal and roughness scans at their published
two-dimensional millimeter extents. Candidate3 imported the
original 4K files with max_dimension4096; LAB creates a lossless derived asset
within its existing16MP output budget. Source files remain unchanged. The state
and material references retain original/derived dimensions, hashes, precision
and the returned resampling method separately. Physical repeat and optical
coefficients remain unchanged for this resolution comparison. This revision
requires the ordinary build that advertises form_material max_dimension.
Satin uses the original official2K crepe_satin normal, roughness and anisotropy
maps; they are a separately identified CC0 donor, not a scan of Dharma silk.
The earlier towel-like fabric_pattern_07 and analytic knit maps remain as
historical evidence, not the current material donors. Thread cases now use
native thread roughness 0.8 and 0.3 with identical color and stitch programs;
they require the ordinary app build that exposes EmbroideryThread.roughness
and PhysicalAppearance.normalStrength. Do not apply these fields to older builds.

The authoring program uses the ordinary LAB app's public MCP operations. It does
not launch an app, alter application models, or write project package JSON.

Offline preparation (no running app required):
  python3 scripts/author_cycles_materials.py

After the verified ordinary app is installed and running:
  python3 scripts/author_cycles_materials.py --apply --app build/LAB.app

Render a selected case with the authored 512-sample budget:
  python3 scripts/author_cycles_materials.py --apply --render --case satin --app build/LAB.app

Target one low-resolution review view, preserving the other saved views:
  python3 scripts/author_cycles_materials.py --apply --render --case woven --view close --samples 64 --width 1200 --height 900

Final captures for visual acceptance, all eight cases and all three views:
  python3 scripts/author_cycles_materials.py --apply --render --samples 512 --width 3000 --height 2000

For a fresh checkout/checkpoint, author the current definitions and install the
reverse-side vellum artwork before capturing the final main views. Use the same
new checkpoint path for every step, with the verified ordinary app running:
  python3 scripts/author_cycles_materials.py --apply --output .local/cycles-materials-fresh
  python3 scripts/author_cycles_optics.py --output .local/cycles-materials-fresh --samples 64 --width 1200 --height 900
  python3 scripts/run_cycles_material_review.py --stage final --apply --output .local/cycles-materials-fresh
  python3 scripts/run_cycles_material_review.py --stage final-controls --apply --output .local/cycles-materials-fresh

The optics author is an active authoring/render command: it creates the registered
reverse artwork and extra optical-control scenes through MCP. Running final main
captures first on a fresh project would omit that reverse artwork from those
images. The optional curved attachment control can then be authored with
author_cycles_curved_attachment.py --apply using the same --output path. These
steps reproduce the current editable cases and controls, not the prior project's
failed iterations or its visual-acceptance decisions. Review the new actual
renders independently. The density/tie scripts below replay historical changes
and intentionally require their earlier state; they are not fresh-setup steps.

--case and --view can be repeated. A view filter limits saved-view updates and
rendering; selected case material/geometry definitions are still authored from
the current corpus. Omitted view defaults to all three. Output dimensions use
LAB's existing pixel/aspect limits. The 4:3 authored reference camera is retained;
LAB expands framing for the final 3:2 output, preserving the composition. Actual
requested samples and pixels are recorded with each new attempt and evidence note.
--no-denoise is available for a controlled comparison and is recorded explicitly.

The default output checkpoint is .local/cycles-materials. Reusing this path
resumes the same dedicated project. A different output path creates a separate
checkpoint/project. The previous project is reopened in finally, and its saved
objects, recipes, materials, notes and camera are compared before returning.
The existing user's project is never the authoring target.
An interrupted run checkpoints the protected project ID and field hashes before
opening the study. Restarting from the study restores that project first; an
unexpected unrelated active project stops the run. Re-running while deliberately
in the authored study is supported. Changed map bytes produce a new import hash,
and every used map is verified through the normal import operation on each run.
Interrupting an active render requests cancellation before project restoration.

Each case saves whole, close and grazing Studio shots. Whole shows both variants.
Cloth grazing uses the second variant's returned edge, exposing the reverse and
finite caliper. The cloth center mesh is editable project data; optical caliper
is rendered by the generic physical material shell. Caliper is not a fabricated
solid model or a calibrated mechanical constitutive model.

Rendering uses asynchronous form_render start/status/result. Each invocation
allocates a new .render folder inside the active project package’s Exports.
Numbered attempt labels remain in the checkpoint and a project-note evidence
index. The state records actual PNG, linear EXR and render.json paths plus
failures; project notes use portable relative paths. Existing evidence is never
overwritten. Specification/photograph observations are saved in project notes
and material references before rendering, so they remain available on failure.
operations.jsonl records the public app calls. Mutation, render status, project
open and error results remain complete. Repeated successful form_get_project
payloads are stored as canonical SHA256/byte size plus identity, revision and
page-completeness metadata, avoiding repeated multi-megabyte snapshots in the
append log. Exact protected field hashes remain in the restoration checkpoint.
Previously retained full-response logs and their verified compressed archives
are preserved.

The current clients require the bounded project-read API. Every open requests
view:summary. Study reads assemble all lightweight object pages and the full
materials/notes sections; original-project protection reads full scoped objects,
materials, recipes and notes plus the camera. Every page is guarded by the same
opaque revision. Separate section cursors are followed even when the byte budget
returns fewer rows than the requested limit. Missing counts, stalled cursors,
changed revisions and unrelated project identities stop the run. A partial
object summary is never used to hash the protected original or sent back as a
Project. Default full reads are not used by these clients. No bridge budget is
raised to accommodate the authored cloth data.

Each new author run captures SHA256 hashes of the installed app executable,
lab-mcp bridge, rendering helper and bundled engine provenance file once.
Every new main/detail/optics render attempt and its portable project evidence
note includes that run identity, alongside the upstream engine revision. The
report exposes these hashes when present. Historical attempts are not backfilled
with a guessed build identity; their original evidence remains unchanged.

An authored project or completed render is not visual acceptance. For every
case, compare actual app output with the linked original photo at matching
whole/detail/grazing views, record concrete discrepancies, revise project data
or generic capabilities, render another numbered attempt, and inspect again.
Only mark a case accepted after those visible comparisons support it.

Review report and explicit observations

Create/append empty pending review records and build a portable HTML report:
  python3 scripts/report_cycles_materials.py --prepare-observations

Fill .local/cycles-materials/observations.json only after inspecting the actual
PNG and original linked photograph. observations.schema.json describes each
round: case/view/attempt, exact image hash, outcome, reviewer, inspected variants,
source URLs, observations, discrepancies and next_change. Pending templates do
not count as completed reviews. The generator never writes comparison prose.

Generate the report in the project package after review:
  python3 scripts/report_cycles_materials.py --project /absolute/Study.form --output /absolute/Study.form/Exports/material-review/index.html

The report copies only actual LAB PNGs and render.json files into its own assets
directory, links manufacturer photographs without copying them, shows every
failed attempt, and preserves older rounds below each latest view. Acceptance
requires explicit valid reviews of the latest whole/macro/grazing outputs and
coverage of both variants. Stale PNG hashes and unresolved discrepancies reject
an accepted declaration. Without those reviews a case remains pending.

Additional editable optical controls

  python3 scripts/author_cycles_optics.py --app build/LAB.app --samples 64

This adds registered reverse artwork, a raised vellum front/back/underside
comparison, and a metallic reflection panel with matched off-camera printed and
blank source cards. It resumes the same project and restores the prior project.
Each call renders new evidence in project Exports; historical attempts remain.
Inside source artwork is explicitly X-reflected in canonical net coordinates,
so conventional print is readable from underneath and mirrored through the front.
The initial unreflected assignment remains documented as an authoring discrepancy.

  python3 scripts/report_cycles_optics.py --prepare-observations
  python3 scripts/report_cycles_optics.py --project /absolute/Study.form --output /absolute/Study.form/Exports/material-review/optics.html

optics-observations.schema.json describes explicit functional-control reviews.
A passed reflection/transmission control does not accept any manufacturer case.
Rebuild the main report after optics.html to include a link to these controls.

Targeted paper and matched thread details use the same editable project:
  python3 scripts/author_cycles_details.py --detail blind-relief --detail foil-highlight --samples 64
  python3 scripts/author_cycles_details.py --detail thread-highlight --detail thread-fill --samples 64

The thread detail command captures both matte and lustrous with identical
relative camera/light placement, geometry, color and diameter. The key moves to
the opposite horizontal side to demonstrate strand highlights; the oblique fill
view resolves crossing/underlay geometry. Those controls remain pending until
their actual new renders have been inspected. No source geometry is altered by
the detail command.

The satin face/back control uses one flat swatch with mirrored local camera/key
geometry. The first front lobe clipped; both key powers were reduced equally.
The first two pairs also exposed unequal environment illumination because the
floor occludes the lower hemisphere. The final pair disables environment
light; floor secondary contribution can remain, so it is a qualitative response
control, not a calibrated BRDF measurement.
  python3 scripts/author_cycles_details.py --detail satin-faces --samples 64

Prepare the ordered post-install capture plan without calling the app:
  python3 scripts/run_cycles_material_review.py --stage diagnostics

After the verified ordinary installation is released for authoring, --apply executes the
curved attachment whole/oblique/grazing views first, dense knit grazing,
cotton/vellum whole views, then the direct-light-only satin front/back control:
eight diagnostic outputs at 64 samples and 1200×900. The sequence then stops
for visible review and the native whole-Table check; it never starts final views.
After corrected contact was inspected, the
active paired satin/fill spacing changed to an authored 0.24 mm comparison;
four spatially separate editable 0.40 mm baselines and actual exported before/
after needle programs remain in the project. Running, underlay, tie and diameter
settings stayed fixed during that density comparison. A subsequent controlled
tie reduction changed two backtracking repeats to one, preserving every non-tie
command. Current corpus process values retain that one-repeat configuration.
This density is outside manufacturer spacing recommendations.
Each group restores the protected
original and any failure stops the sequence; previous outputs remain intact.

After the diagnostic discrepancies are resolved, final main evidence is a
separate explicit stage: --stage final --apply captures all 24 main views at
the 512-sample budget and 3000×2000 pixels. --stage final-controls --apply captures the additional
paper edges/finishes, paired thread/satin controls and indirect optical scenes
at that resolution and sampling budget. Adaptive sampling can finish earlier;
actual completed samples are retained in each render record. A completed sequence
never marks visual acceptance.

Extra curved-cloth attachment diagnostic (separate from the main eight cases):
  python3 scripts/author_cycles_curved_attachment.py

The default only validates/prints project data. After the shared physical
attachment mapper is installed, --apply duplicates the existing matte fill/
underlay patch and copies its editable artwork, stitch settings and thread
appearance. A 160×120 mm single-panel cylindrical cloth arch has an 80 mm bend
radius. The 80×60 mm patch is rotated 20 degrees, remains inside that panel, and
has a 0.5 mm authored caliper. Its midsurface offset is exactly half the actual
0.4 mm parent caliper plus half the patch caliper: 0.45 mm. No main-case source
is changed. Whole, oblique and grazing saved Cycles shots expose the backing,
needle-end contact and stitch crossings across about 14 mm of surface bend.
The generated rest mesh and source-derived stitch program remain project data.
Fast's rigid placement is not the visual acceptance surface for this control.

The standalone density authoring command retains the original editable source
iterations, applies the four spacing edits atomically, exports real needle JSON
through LAB, and checks exact paired command geometry (ignoring region UUIDs
only), underlay/tie counts and diameter before capturing the four detail views:
  python3 scripts/author_cycles_thread_density.py --apply
The retained baseline group is spatially separate; active shot visibility IDs
stay unchanged. Re-running cannot silently replace a missing original baseline.

The subsequent tie comparison retains complete before/after editable definitions
in project-local exported needle JSON and ordinary project history:
  python3 scripts/author_cycles_thread_ties.py --apply
It changes only two backtracking repeats to one, keeping both tie-in/off enabled
at 0.7 mm length. The resulting four diagnostic images were inspected; compact
local raised knots are acceptable for this authored noncompressing round-strand
model. No calibrated tie mechanics or validated sew-out is claimed. This command
requires the two-repeat baseline or its resumable checkpoint and will not reset
unrelated changes. The current final thread captures and matched highlight/fill
controls have passed visible review; both thread cases are accepted as documented
above. The command remains available for reproducing the retained comparison.
