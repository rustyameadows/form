# Bundled Cycles in LAB

LAB builds the standalone Cycles C++ renderer into a private `lab-cycles-render`
helper. LAB's own scene snapshot supplies geometry, physical materials, textures,
lights and camera; no Blender application or Blender installation participates.
The first platform is Apple Silicon, macOS 15 or later, with CPU and Apple Metal.
This document records implementation and repeatable engineering gates. Material
acceptance depends on the separate visible reference reviews, not those gates.

## Current installation and reproduction

The [committed validation snapshot](validation/cycles/README.md) provides portable
test counts, executable identities and evidence hashes for code review, without
user-project contents or workstation-specific paths.

Candidate 6 is installed as the single ordinary [LAB app](../build/LAB.app).
The [current delivery record](../.local/cycles-app-validation/final-delivery.json)
is the final aggregate; the
[portable material review](</Users/rustymeadows/Library/Application Support/FORM/2E2A5127-DAEA-4130-AB9E-76D2AC68F6B6.form/Exports/material-review/index.html>)
and [optical-control report](</Users/rustymeadows/Library/Application Support/FORM/2E2A5127-DAEA-4130-AB9E-76D2AC68F6B6.form/Exports/material-review/optics.html>)
live inside the study project at `Exports/material-review/`. Their copied image
and record links stay relative when the project package moves. The material
report records eight accepted cases, 131 retained main attempts and 97 explicit
reviews; the control report retains 67 attempts and explicit reviews.
The [final preservation check](../.local/cycles-materials/diagnostics/final-original-preservation.json)
confirms all eleven protected original-project fields, including its full camera.

The [test matrix](../.local/cycles-app-validation/candidate6-test-matrix.json),
[offline bundle gates](../.local/cycles-app-validation/candidate6-provenance/gate-report.json),
[lifecycle checks](../.local/cycles-app-validation/lifecycle-round6/report.json)
and [native UI record](../.local/cycles-app-validation/native-round6/report.json)
identify the tested installation. The
[final engineering audit](../.local/cycles-app-validation/final-delivery-engineering.json)
rechecks the current source set, installed signature/runtime identities and exact
evidence hashes without launching LAB. PNG, scene-linear EXR and `render.json` are
delivered together; each current export identifies its actual runtime binaries.

The [current 41-export provenance inventory](../.local/cycles-materials/diagnostics/final-current-runtime-verification.json)
verifies all 24 main views and 17 controls at 3000×2000 with a 512-sample budget,
including corrected replacements and exact runtime/output hashes. It is separate
from the [current visible reviews](../.local/cycles-materials/diagnostics/root-final-review.json).
The [initial main-batch record](../.local/cycles-materials/diagnostics/final-main-round1-runtime-verification.json)
retains the earlier set, including its subsequently rejected vellum and foil views.
All eight cases are accepted: cotton, finished cotton, neutral vellum, woven,
satin, knit, matte thread and lustrous thread. Their final whole/detail/grazing
views and [dedicated controls](../.local/cycles-materials/diagnostics/root-final-control-review.json)
have been reviewed, including vellum transmission, off-camera reflection, paper
caliper/relief/foil, satin face/back and matched thread highlights/contact.
The foil normal/bump correction first passed its
[matched 64-sample checkpoint](../.local/cycles-materials/diagnostics/root-foil-smooth-checkpoint.json),
then all six replacement views/finish controls passed at 3000×2000 with a
512-sample budget. Final renders use adaptive sampling at noise threshold 0.01;
their records retain actual sample counts. The satin-back control completed at
224 samples under that budget, not 512.
The rejected warm vellum and grainy foil attempts remain retained. Acceptance is
for the authored material studies and their documented estimates; it does not
claim measured manufacturer BRDFs, calibrated cloth mechanics or validated sew-outs.

The candidate 6 test matrix is an immutable engineering-build checkpoint. Its
older pending-material notes describe that checkpoint and are superseded by the
current visible-review records above; they are not the current acceptance status.

Build, engineering checks and capture plans can be reproduced from the repository
root. Choose new gate output directories to preserve earlier evidence:

```sh
scripts/install-cycles.sh
LAB_BUILD_APP_PATH="$PWD/.local/cycles-candidate/LAB.app" scripts/build.sh release
python3 scripts/verify_cycles_bundle.py --bundle .local/cycles-candidate/LAB.app \
  --output .local/cycles-app-validation/offline-next-cpu --device cpu --require-app --deny-development
python3 scripts/verify_cycles_bundle.py --bundle .local/cycles-candidate/LAB.app \
  --output .local/cycles-app-validation/offline-next-metal --device metal --require-app --deny-development
python3 -m unittest discover -s scripts -p 'test_*cycles*.py' -v
python3 -m unittest discover -s scripts -p 'test_curved_attachment_plan.py' -v
python3 scripts/run_cycles_material_review.py --stage final
python3 scripts/run_cycles_material_review.py --stage final-controls
```

The last two commands only print capture plans. Add `--apply` when deliberately
running the approved stage against the already-running ordinary app; never launch
the candidate alongside it. The [material-study guide](../examples/cycles-materials/README.txt)
documents editable project data, references, variants, review records and portable
report generation. [Build instructions](#build-a-candidate-without-replacing-the-running-app),
[native/full-bundle gates](#native-and-full-bundle-gates) and
[install/rollback](#install-and-rollback) give the complete workflow.

## Pinning and packaging

| Component | Pinned identity |
| --- | --- |
| Cycles source | `3eb35f85996baa6c1b2e19bf297b22745c85e321` |
| `lib/macos_arm64` dependencies | `7d74150064b3263092281b269c6b62b891001fcb` |
| Architecture / deployment target | `arm64` / macOS `15.0` |
| Helper protocol | `1` |
| Display transform | `LAB-sRGB-v1` |
| OpenImageDenoise | `2.5.0` |
| OpenImageIO / OpenColorIO | `3.1.16.0` / `2.5.0` |
| OpenEXR / Imath | `3.4.10` / `3.2.2` |

The source lock is [engine-lock.json](../Native/LabCycles/engine-lock.json).
Upstream [Cycles source](https://github.com/blender/cycles/tree/3eb35f85996baa6c1b2e19bf297b22745c85e321)
contains its Apache-2.0 license. The dependency checkout supplies its exact version
table; packaging retains that table and complete dependency license notices.
`BUNDLED-LIBRARIES.json` identifies the actual twenty private dynamic libraries.
The large upstream dependency-notice reference also describes components of
Blender that LAB does not bundle; it is not an assertion that Blender is shipped.

`LAB-CYCLES-PROVENANCE.json` records source/dependency commits, dependency Git tree,
compiler version and compiler executable SHA-256, SDK version, CMake cache hash, helper and
bootstrap source hashes, original source archive hash, and hashes of 307 installed
runtime files. Recording rejects modifications to the pinned source/dependency
trees except the exact CMake stanza adding LAB's helper. Verification rejects
changed source sets, helper inputs, source archive, libraries, kernels or notices.
The original Cycles source archive and attribution ship in the application.

The packaged paths are:

```text
LAB.app/Contents/Helpers/lab-cycles-render
LAB.app/Contents/Frameworks/Cycles/*.dylib
LAB.app/Contents/Resources/Cycles/source/...
LAB.app/Contents/Resources/Cycles/LAB-sRGB-v1.json
LAB.app/Contents/Resources/ThirdPartyNotices/Cycles/...
```

All non-system library paths resolve relative to the helper or library itself.
Packaging includes OIDN CPU/Metal modules loaded dynamically, rewrites install
names, removes external absolute runtime search paths and signs native payloads.
The normal app build signs and verifies the complete bundle. Developer builds use
ad-hoc signatures; this workflow does not claim Developer ID notarization.

Renderer caches are under `~/Library/Caches/LAB/Cycles/<engine revision>`;
`LAB_CYCLES_CACHE_DIR` permits isolated test caches. Job geometry, converted HDR
textures, progressive frames and final working files live in the job directory,
outside the signed bundle. No first-run download is needed. Initial Metal kernel
compilation can take minutes on a completely cold machine; subsequent renders
reuse caches. Empty LAB caches do not imply that Apple's system compiler cache is
empty.

## Build a candidate without replacing the running app

Run from the repository root with Xcode command-line tools, Git LFS, CMake, Ninja,
Python 3 and the existing pinned OCCT installation available. The bootstrap uses
the repository's `.local/cad-kernel/tools/bin` CMake/Ninja when available, or PATH.
`LAB_CMAKE`, `LAB_NINJA` and `LAB_CYCLES_JOBS` override those build tools/parallelism.

```sh
scripts/install-cycles.sh
python3 scripts/package-cycles.py --verify .local/engines/cycles-3eb35f85996b
LAB_BUILD_APP_PATH="$PWD/.local/cycles-candidate/LAB.app" scripts/build.sh release
codesign --verify --deep --strict .local/cycles-candidate/LAB.app
```

Bootstrap downloads pinned source/dependencies, builds the real CPU/Metal engine,
installs `.local/engines/cycles-3eb35f85996b` and records provenance. It refuses to
replace an engine binary/library currently in use. `scripts/build.sh` verifies
the engine before packaging and refuses to replace a running target executable.
The candidate is an ordinary LAB bundle. Do not launch it alongside ordinary LAB.

For payload-only relocation investigation, without an application launch:

```sh
python3 scripts/package-cycles.py .local/cycles/relocated/LAB.app
```

That command creates the private renderer paths only; it does not create a
complete launchable application. Use the complete candidate for the final gate.

## Native and full-bundle gates

Each validation output directory must be new so earlier evidence is retained.
These scripts launch renderer helper processes, never LAB, and do not modify
projects or issue printer/motion commands.

```sh
python3 scripts/verify_cycles_native.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-native-cpu --device cpu
python3 scripts/verify_cycles_displacement.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-displacement-cpu --device cpu
python3 scripts/verify_cycles_curves.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-curves-cpu --device cpu
python3 scripts/verify_cycles_finish_layers.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-finish-factors-cpu --device cpu
python3 scripts/verify_cycles_render_lifecycle.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-render-lifecycle-cpu --device cpu
python3 scripts/verify_cycles_color.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-color-cpu --device cpu
python3 scripts/verify_cycles_mesh_normals.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/check-mesh-normals-cpu --device cpu
```

The native contract checks real pixels and PNG/EXR output, both UV
sets, vertex color, alpha-over artwork, physical masks, normal/detail/bump chains,
HDR textures, curves, cancellation and rejection of out-of-job resources. The
displacement gate starts with a two-triangle plane and an unrelated closed
polyhedron; it checks changed silhouettes, bounded refinement, explicit budget
failure and a masked zero-displacement layer restoring the original silhouette.
The curve gate checks longitudinal and circumferential physical texture repeats,
UV1, rotation invariance, tangent normal/detail response and strength-zero
restoration. It also compares reversed UV1, reflected scale, a ninety-degree map
rotation and mirrored-repeat tangent orientation against equivalent reference
normal maps. Repeat it with `--device metal` in a GPU-enabled execution context.

The finish-factor gate changes substrate roughness/metallic maps beneath a masked
finish and compares its pixels with independently authored scalar and mapped
finish references. The mask must retain its own response while the uncovered
substrate visibly changes. The lifecycle gate requires two changing frames and
increasing sample counts before a 4,096-sample job completes, then cancels it.
It separately cancels during actual displacement preparation and 50 ms after
the real OIDN entry event at 2,048 pixels. Each case must exit as cancelled and
must not publish a completed event. Repeat both gates with `--device metal`.

The color gate independently calculates constant-texture and environment
references, reads scene-linear EXR through the pinned development `oiiotool`,
and decodes PNG bytes without applying another display transform. It checks
premultiplied final EXR, straight PNG and float input textures, HDR retention,
exposure and retained live preview frames. The mesh-normal gate compares UV0/UV1
affine and mirrored tangent directions against independently authored vectors.
Repeat these on Metal too. `oiiotool` is a test reader, not a runtime requirement
of the packaged helper or the complete-bundle offline gate.

Run both complete-bundle gates with an empty LAB cache, network denied and
development dependencies inaccessible to the renderer:

```sh
/usr/bin/python3 scripts/verify_cycles_bundle.py --deny-development \
  --bundle .local/cycles-candidate/LAB.app --require-app \
  --output .local/cycles-app-validation/offline-cpu --device cpu
/usr/bin/python3 scripts/verify_cycles_bundle.py --deny-development \
  --bundle .local/cycles-candidate/LAB.app --require-app \
  --output .local/cycles-app-validation/offline-metal --device metal
```

Metal tests require a host execution context with GPU access. A restricted agent
sandbox can enumerate only CPU; that is not evidence of missing host hardware.
The bundle gate verifies the complete signature, runtime dependency closure,
actual rendering with a minimal environment, unchanged Cycles runtime/notice
hashes and no new files in those renderer subtrees. It verifies relocation without developer-library
search paths or Blender. It does not exercise the app window or user interaction.
The helper-only sandbox also denies reads beneath repository `.local/cycles`,
`.local/engines`, `.build`, `/opt/homebrew`, `/Applications/Xcode.app` and
`/Library/Developer`. Existing development files must fail explicit read probes
before the render is attempted. Signature and linkage auditing run outside that
sandbox because their tools may use Xcode. Candidate and evidence paths must sit
outside the denied directories; the exact profile and probe results are retained.

To exercise a real Metal initialization failure, the following script copies the
renderer bundle and inserts an intentional compiler error only in that copy:

```sh
python3 scripts/verify_cycles_metal_failure.py \
  --bundle .local/cycles/relocated/LAB.app \
  --output .local/cycles/check-metal-initialization
```

Both Metal and Auto must report a typed `metalInitialization` error before any
sample; CPU must render the identical scene successfully. No production fault
switch exists. Swift tests can use the intentionally failing copy to verify the
client's one visible CPU retry for Auto, and failure for explicit Metal:

```sh
export LAB_CYCLES_CACHE_DIR="$PWD/.local/cycles/swift-test-cache"
export LAB_CYCLES_TEST_HELPER="$PWD/.local/engines/cycles-3eb35f85996b/lab-cycles-render"
export LAB_CYCLES_TEST_CURVE_UV_HELPER="$LAB_CYCLES_TEST_HELPER"
export LAB_CYCLES_TEST_INIT_FAILURE_HELPER="$PWD/.local/cycles/check-metal-initialization/intentional-failure/LAB.app/Contents/Helpers/lab-cycles-render"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" \
  -c release --filter 'CyclesRenderTests|CurveTextureTests'
```

The initialization test also requires GPU access. Run `scripts/test.sh` for the
repository's ordinary regression command; a release test invocation with the same
cache/config/security arguments is useful for the expensive cloth simulations.
Passing renderer tests alone does not establish full application acceptance.

## Scene and material behavior

[PROTOCOL.md](../Native/LabCycles/PROTOCOL.md) defines the private wire format.
Swift freezes a revision, serializes millimeter geometry and camera transforms,
rebases large world translations, and writes binary buffers/textures into one job.
The helper converts millimeters to meters once. Imported materials retain UV0/UV1,
texture affine mappings/wrap modes, vertex colors and linear color factors.
Artwork alpha-composites over substrate color; physical finish masks mix material
closures. Every enabled paper finish carries its roughness/metallic factors,
including finishes without optical overrides. An omitted appearance inherits
substrate optics. Explicit finish factors replace inherited channel maps; maps
authored on the finish modulate those factors instead. Physical substrate maps
exclude baked finish coverage, so a partial-opacity finish is applied once.
Fast retains its existing combined maps. The physical shader supports at most
sixteen finish layers per face; exceeding that limit rejects rendering while
Fast remains usable. Physical appearance is generic project data, including independent
reverse surfaces, physical texture repeats and source/reference provenance.

Final-view paper relief uses adaptive, conforming longest-edge refinement of the
finish height field. A compact min/max hierarchy finds small marks between the
original cap vertices; texel-boundary and interpolation checks concentrate detail
around changing heights. Shared-edge propagation avoids both cracks and sliver
chains. The sampled height target is the smaller of a quarter source texel,
0.02 mm, and 10% of the field amplitude. When allocation meets the existing 1.15×
projected source demand, a quarter texel estimates about 0.22 output pixels
locally. A capped source pool can raise that estimate; this is not a formal
camera-space error bound. Each face is limited to 200,000 triangles,
with 400,000 allocated across the paper object's faces. Exhausting the triangle
or subdivision limit fails preparation explicitly. Zero-relief faces, ordinary
editing geometry, stock edges, and fabrication sources retain their existing
geometry. The global scene-transfer limits still apply.

`PaperReliefGeometryTests` independently samples curved boundaries, checks shared
edges and UVs, exercises narrow low relief, tests compound high-resolution finish
maps, and verifies budget failure and cancellation. A standalone curved-field
diagnostic reduced maximum sampled boundary height error from 0.08037 mm for the
former uniform cap to 0.01126 mm with 10,322 triangles and no unmatched interior
edges. A reconstruction of the authored text/foil/emboss fields at 2266×1586 used
141,704 triangles in about 0.34 seconds. The close-up's 3000×2000 final request
still shares the 7,190,235 source-pixel pool between both paper faces, so its
per-face raster remains approximately 2266×1586. Projecting its 0.01103 mm target
around the saved ring camera gives approximately 0.220–0.245 pixels at 1200×900
and 0.488–0.544 pixels at 3000×2000. A conservative 3205×2243
single-face allocation exceeded the 200,000-triangle limit and failed explicitly.
The real `PaperSurfaceRasterizer` compound text/foil/curve regression used 35,517
triangles and measured 0.001583 mm maximum curved-boundary error; all twelve
relief tests passed in 0.583 seconds in
`.local/cycles-app-validation/focused-round3c.log`. Numerical diagnostics are
recorded in `.local/cycles/validation-paper-relief-round3/report.json`. These
checks alone do not establish visual quality. The current finished-cotton main
review records a continuous embossed rim. The separate foil-grain correction and
all six replacement final views/controls have passed visible review; finished
cotton is accepted in the current material record.

Curves carry per-key millimeter UV coordinates; a transported frame supplies
the circumference coordinate. Their tangent normal maps use the selected UV
derivative and texture rotation/reflection, including mirrored-repeat parity,
because upstream Cycles' triangle normal-map node ignores curves. Geometry-specific
shader variants preserve the existing mesh path. `normalStrength` controls the
authored normal detail when present, otherwise the ordinary normal map; zero
restores the corresponding underlying surface. True texture displacement on
curves is explicitly rejected instead of silently ignored.

Needle-program strands keep each nonzero stitch separate, excluding travel.
Crossing clearance changes a local height profile rather than scaling the whole
stitch arch near a needle endpoint. Interior crossings and collinear tie retraces
retain sewing order; nearby parallel rows and shared-endpoint zigzags do not
acquire artificial layers. Eleven bridge regressions passed in
`focused-round3c.log`, including source endpoints, current cloth/assembly placement,
near-needle crossings and dense noncrossing rows. The historical saved-program
diagnostic retained 822 strands and reported 1.30410 mm maximum center height, with only two
centers above 1 mm at genuine five-layer tie bundles. The former whole-arch
solver produced 3.16970 mm and 93 centers above 1 mm on that same older program.
The current candidate 6 integrated check retains the complete 1,214-strand,
21,786-key program, and the installed curved-contact review passes whole,
oblique and grazing views. Both current thread cases also pass their three main
final views and their dedicated dense-fill and matched highlight controls; both
thread cases are now accepted in the current visible-review record.
The 822-strand numbers are preserved as a historical before/after checkpoint,
not measurements of the current authored program.

Needle endpoint placement uses the actual centered patch backing's half-caliper
top for both independent patches and cloth/assembly attachments. Candidate 4
corrected planar contact; its attached backing still uses the Fast rigid placement.
The subsequent derived-surface change maps the rendered backing, edges and stitches
through one frozen parent material chart. Fast editing/picking, saved source meshes
and manufacturing geometry remain rigid and unchanged. Installed candidate 6
verifies this rendering-only change with whole, oblique and grazing curved-patch
controls, as recorded in the evidence overview below.

The shared mapper clips physical triangles against the original parent panel's
material triangles, retaining vertical caliper walls and both UV sets. Conforming
refinement bounds normal-offset interpolation error to 0.005 mm; a separate convex
Bézier certificate bounds the complete native Catmull–Rom stitch interpolation to
0.005 mm from the mapped source curve, including points between keys. Positive
Jacobian determinants are certified over each convex cell, rather than sampled
only at vertices. Missing panel coverage, holes, overlapping/discontinuous material
charts, offset folds and exhausted budgets reject preparation explicitly.

Per attached object, derived mapping is limited to 200,000 triangles, two million
curve keys (4,097 per strand), and 16 million charged operations; a preparation
shares aggregate scene limits of two million triangles/keys and 32 million charged
operations. It freezes arrays and node-relative payloads on the main actor, then
clips and certifies in a cancellable detached task. Seven exact-source standalone
geometry regressions exercise closed-edge topology, front/back/side caliper,
interpolation/contact, UV preservation, holes, invalid charts, offset folds and
failure budgets and dense full-program work scaling. The installed functional
contact control and manufacturer material acceptance remain separate judgments.

Nonzero texture displacement uses bounded shared-edge linear tessellation before
Cycles evaluates the height field. The default target is two projected pixels,
ten subdivision levels and two million generated triangles across displaced
meshes. A budget failure asks for coarser dicing; it does not silently allocate
unbounded geometry or drop displacement. World-space millimeter amplitude is
independent of object scale. Cycles recomputes displaced normals; the same height
is not also applied as automatic bump. Explicit bump is a separate material input.

PNG previews and finals share `LAB-sRGB-v1`: unpremultiply linear RGB, apply
`2^exposure`, encode with the standard sRGB transfer curve and clamp the eight-bit
display output. There is no photographic tone map. EXR remains premultiplied
scene-linear sRGB and retains values above one. OIDN version and upstream measured
path tracing/denoising times are emitted with actual samples/device. Auto permits
one CPU retry only for typed Metal initialization failure before sampling;
explicit Metal, scene errors and out-of-memory failures remain errors.

Each atomic export folder includes PNG, EXR and `render.json`, with the upstream
Cycles revision, actual device, settings, denoiser, source/resource identities,
timings and artifact hashes. Installed candidate 6 additionally records
`runtime_provenance`: SHA-256 and byte counts of the actual LAB executable and
resolved rendering helper, the packaged build metadata and its file hash, and
the bundled engine-provenance and display-transform hashes. Those signed runtime
file identities are separate from executable hashes captured in `LABBuild.json`
before packaging/signing. The app checks the identities before and after rendering
using bounded, cancellable background reads; a change or malformed present
metadata prevents delivery. Unbundled development/test layouts report absent
metadata explicitly while still identifying both runtime executables.

This addition has six passing isolated exact-source Swift tests and seven passing
Python verifier tests in `export-provenance-check1`, followed by the passing
coordinated application regression. The installed lifecycle recovery export and
all three curved-control exports passed exact runtime and artifact hash checks in
[installed-output-consistency.json](../.local/cycles-app-validation/candidate6-provenance/installed-output-consistency.json).
Earlier
installed candidates' records identify the upstream Cycles revision without these
runtime hashes; their validation author-run records retain the exact bundle
identities separately. `scripts/verify_cycles_app.py` now requires the new fields
and compares them with the installed bundle during its final export check.

Texture and environment input encodings use Cycles' built-in identifiers
`__builtin_srgb`, `scene_linear` and `data`. They do not depend on named color
spaces in an external OCIO configuration. An explicit `srgb`, `linear` or `data`
encoding declares the numeric samples and overrides any embedded image profile;
it does not request a Display P3, calibrated gray or other ICC conversion.
This applies equally to eight-bit, sixteen-bit and floating-point input.
Higher-depth images are read numerically into straight RGBA; declared `srgb`
channels then use the exact piecewise sRGB decoding curve, including monochrome
input, and must remain finite after decoding. `linear` and `data` retain their
numeric values. Straight `rgba32f` textures explicitly
set the node's unassociated-alpha mode; temporary EXR metadata alone does not
preserve that distinction. Final EXR still uses the premultiplied render pass.
The PNG writer declares its already-straight RGB to OpenImageIO, preventing a
second division by alpha inside the encoder.

The app bundles [LAB-sRGB-v1.json](../Native/LabCycles/LAB-sRGB-v1.json), a
provenance-hashed companion describing the exact compiled transfer function,
linear primaries, white point, alpha, exposure and output encoding. It explicitly
states that it documents code and is not loaded as a runtime OCIO configuration.
OpenColorIO is present as an engine dependency; LAB does not claim to evaluate
this built-in display transform through an external OCIO file. The bundle gate
checks the companion identity and exact hash against packaged provenance.

Progressive scheduling uses Cycles `background=true` to finish at the requested
sample limit, with `headless=false` to enable its DisplayDriver. Here the driver
is LAB's offscreen CPU image sink: it creates no GUI window or OpenGL context.
The public scheduler caps work batches at 32 samples; display callbacks publish
actual completed counts and atomic PNG frames. Cycles' headless mode would
disable that driver entirely and select roughly 30-second update batches.
The pinned engine does not expose ordinary final denoising through Session
progress. LAB uses its public logging callback to forward the exact
`PathTrace::denoise` entry as a `denoising` event without changing the engine.
The Swift process client uses bounded POSIX pipe reads, so small flushed messages
arrive immediately instead of waiting for a full Foundation read buffer or EOF.

## MCP use in the ordinary running app

Use the matching installed `lab-mcp`, first inspect the actual project/context and
schemas, and substitute real IDs below. These calls target the ordinary running
app; they are not a reason to open the candidate as a second copy.

```sh
build/LAB.app/Contents/MacOS/lab-mcp --call form_get_project '{"view":"summary","limit":1}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_get_context '{}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_capabilities '{"command":"schema","tool_names":["form_render","form_material"]}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_render '{"command":"capabilities"}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_render '{"command":"configure","project_id":"PROJECT_UUID","target":"table","settings":{"renderer":"cycles","device":"automatic","samples":256,"previewSamples":32,"noiseThreshold":0.01,"denoise":true}}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_render '{"command":"start","project_id":"PROJECT_UUID","target":"table","pixels":{"width":1200,"height":900}}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_render '{"command":"status","job_id":"JOB_UUID"}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_render '{"command":"result","job_id":"JOB_UUID"}'
build/LAB.app/Contents/MacOS/lab-mcp --call form_render '{"command":"cancel","job_id":"JOB_UUID"}'
```

`configure` persists settings with Undo; `start.settings` overrides only that job.
Saved targets use `target:shot` with `shot_id`, or `target:scene` with `scene_id`.
Table requires the Table view to be open. Start returns immediately; poll status
until completed before requesting result. An optional absolute `path` must name a
new `.render` folder in this project's Exports or an existing independent output
directory. Output contains PNG, linear EXR and source/settings/resource hashes.
Changing source or saved target during the job invalidates final delivery.

A Table capture freezes the displayed mesh buffers, deformed stitch curves,
visibility, camera and lighting before waiting for external CAD/mesh preparation.
Later simulation frames or navigation do not alter that frozen revision. Authored
source changes still cancel it; saved shots and scenes still require committed
simulation sources. Physical external payload cache hits stream and verify both
original and normalized mesh files, CAD BREP/mesh files and referenced CAD material
maps against their saved hashes, including same-size replacements.

Explicit Cycles capture preparation reuses the resource hashes gathered for
provenance as an artwork cache generation. A changed generation invalidates the
dependent image/raster caches and the isolated capture controller; it does not
resynchronize the live Table or reset cloth. Required linked images, image paints,
named CAD surface artwork and fabric/assembly artwork are checked against current
files before preparation. The focused regression cases live in
`CyclesExternalAssetCacheTests`, `CyclesArtworkAssetGenerationTests` and
`CADModelCoordinatorTests.testWarmCyclesCADCacheRevalidatesExactAndDerivedSources`.

`form_material list/get` inspect existing data. `import_texture` accepts an absolute
local path and `color_space:srgb|linearSRGB|data`, stores content-addressed immutable
Assets and returns the portable `texture` object. Original import preserves exact
source bytes. Optional `max_dimension` (1–4096) requests a derived image: at most
8192 pixels per source edge and 32 megapixels, at most 16,777,216 output pixels,
with a conservative 1 GiB working-set estimate checked before pixel extraction.
Data maps retain numeric channel encoding; color maps filter in linear light
with premultiplied alpha. Supported component precision is retained and checked
after lossless encoding; unsupported conversions fail before publishing an
asset. The shared native import picker offers Original, Fit 4096, Fit 2048 and
Fit 1024. Attach the returned texture through
`create` or `update.patch.appearance.textures`. An appearance patch replaces the
whole appearance record; get it first to preserve other channels. Use
`scaleMM:{x,y}` for physical millimeters per repeat. Do not relabel assumed optical
values as measurements; store reference titles, URLs, licenses, evidence types
and notes alongside the material. The app's physical thickness remains separate
from optical appearance. Example corpus/project authoring lives under
`examples/cycles-materials` and `scripts/author_cycles_materials.py`, not in
application-specific object generators.

The native material sheet, paper stock/ply/finish sheets and embroidery thread
sheet share the same physical controls and portable image importer. Paper Apply
uses `form_paper` and commits one Undo; it preserves current manufacturing fields
and rejects a concurrent change to the optical override being edited. Thread
Apply updates the embroidery editor's local draft; Save embroidery commits its
optical roughness and appearance with the existing digitizing settings in one
Undo. Generated paper/thread surfaces expose UV0. Thread repeat coordinates are
millimeters along and around the strand; use normal/bump maps for its fine detail.
True curve displacement is not offered. The material sheet retains both UV sets
for imported meshes that supply them.

## Install and rollback

Finish regression and complete signed-candidate gates before installation. Save
work and quit ordinary LAB through its normal menu. With no LAB process running,
preserve `build/LAB.app` as `build/LAB.app.previous-<timestamp>`, then move the exact
verified candidate to `build/LAB.app`. Verify its signature and executable/helper
hashes again before reopening the ordinary path. This preserves the existing
rollback convention and compatibility `FORM.app` link without rebuilding between
the candidate gate and installation. Never launch the candidate alongside LAB.

The default `scripts/build.sh release` also preserves a timestamped prior bundle
and refuses to replace a live executable. If using that path, repeat the gate on
its actual output before accepting it. Native interaction and visual review run
after the verified candidate becomes the single ordinary installation; a failing
iteration remains a candidate for correction or rollback, not a completed release.

To roll back, quit LAB again, preserve the rejected bundle under a different
filename, and move the selected `build/LAB.app.previous-<timestamp>` back to
`build/LAB.app`. Verify its signature before opening it. Never overwrite a live
executable, delete project libraries, or launch a candidate and ordinary app
together. App bundles and project packages are separate; no project migration is
performed by the installer script itself.

## Running-application lifecycle and native checks

Open the dedicated review project, then use explicit existing shot/material IDs:

```sh
python3 scripts/verify_cycles_app.py --app build/LAB.app \
  --project-id PROJECT_UUID --shot-id SHOT_UUID --material-id MATERIAL_ID \
  --output .local/cycles-app-validation/lifecycle-next
```

The script cancels during preparation, terminates only the identified bundled
render helper after sampling starts, verifies that LAB survives and renders a new
denoised PNG/EXR pair, preserves an existing destination, and exercises source
invalidation with exact material Undo/Redo. `--switch-project-id OTHER_UUID`
also checks project changes; it returns to the review project. Optional
`--missing-asset /absolute/review.form/Assets/file` temporarily renames that one
review-project image and restores its exact bytes in `finally`, proving missing
inputs cannot commit an output. Do not use a user project for destructive fault
injection. JSON operation logs and a passed/failed report retain the actual run.

Native checks additionally exercise Fast/Rendered, navigation and picking,
pause/resume, shot recall, appearance controls, exposure, save/reopen and document
Undo/Redo. Record screenshots and the corresponding actual saved values. Native
screenshots are separate from exported reference renders: neither substitutes
for the other. Restore the user's prior project and compare its protected fields
and camera after each installation or authoring session.

## Evidence status for this implementation

Evidence is specific to the recorded binary and source hashes. A native helper
pass does not accept a newer application bundle or establish reference fidelity.
Candidate 6 is installed at the single ordinary `build/LAB.app` path. Its
[test matrix](../.local/cycles-app-validation/candidate6-test-matrix.json) records
the final-source 2,441-test full release regression (three optional performance
fixture skips, zero failures), plus focused checks. All 1,023 source files matched
the candidate manifest after testing. Earlier evidence retains the reopen-test
failure caused by comparing saved schema 31 with an in-memory schema 1 fixture,
and the passing corrected rerun.

Candidate 6 passed both complete-bundle offline CPU and Metal gates with network
and development reads denied. Its
[gate report](../.local/cycles-app-validation/candidate6-provenance/gate-report.json)
records unchanged signatures, executable/provenance hashes and 317 renderer
runtime/notice files. The exact bundle was moved into place after saving and
quitting ordinary LAB; the previous installation remains available for rollback.
The [installation record](../.local/cycles-app-validation/installed-round6.json)
and [project preservation check](../.local/cycles-app-validation/project-preservation-round6-install.json)
record the installed identities and equality of all eleven protected original
project fields, including its full camera.

Candidate 5's first installed curved-contact
control failed during preparation with “Attached surface mapping exhausted its
work budget”; it produced no samples or image. The full dense stitch program
exposed redundant boundary-root work that the smaller mapper checks did not.
The failed attempt and exact build identity remain in the
[candidate 5 native record](../.local/cycles-app-validation/native-round5/report.json).
Candidate 6 corrects that work scaling while preserving geometry, tolerance and
limits. Its integrated actual-program check retained all 1,214 strands and 21,786
keys at 1,461,529 work units under the original 16,000,000 cap. The complete
36-object Table preparation used 921,651,852 bytes under the original 1 GiB cap,
without downsampling. Both records are under
[`mapped-patch-full-program`](../.local/cycles-app-validation/mapped-patch-full-program).
The installed whole, oblique and grazing controls then rendered successfully.
Their [runtime verification](../.local/cycles-materials/diagnostics/candidate6-curved-runtime-verification.json)
checks each delivered PNG/EXR and exact runtime identity. The
[visible contact review](../.local/cycles-materials/diagnostics/root-candidate6-curved-contact-review.json)
records the backing and strands following the same arch, a finite edge with a
narrow contact shadow, seated needle endpoints and local crossing relief. This
passes the functional curved-attachment control; it does not establish calibrated
cloth mechanics or manufacturer material fidelity.

[Lifecycle round 6](../.local/cycles-app-validation/lifecycle-round6/report.json)
passed preparation cancellation, sampled-helper crash and denoised recovery,
destination preservation, project/source invalidation, missing-asset rejection,
protected-field restoration and the new installed runtime-provenance comparison.
The [candidate 6 native report](../.local/cycles-app-validation/native-round6/report.json)
also passed: the complete 36-object Table reached 64 samples on Metal, native
orbit triggered fresh preparation and completion, pause/resume worked, and the
saved “Material study / knit view” Studio scene reached 64 samples on Metal.
The [original-project preservation record](../.local/cycles-app-validation/native-round6/original-preservation.json)
confirms equality of all eleven protected fields, including the full camera.
The initial 24-image final batch, corrected replacements and dedicated controls
have completed. Current visible reviews accept all eight cases, including the
corrected neutral vellum and smooth foil finish. All six replacement finished-
cotton views and controls passed at the final resolution and sampling budget.
Rejected warm vellum and grainy foil attempts are retained. These decisions come
from actual image/reference comparison, independently of the engineering and
functional-control passes; the optical and mechanical estimate limitations remain.

Candidate 4 passed complete signed-bundle CPU and Metal gates with network and
development reads denied. The
[gate report](../.local/cycles-app-validation/candidate4-provenance/gate-report.json)
references its immutable identities and 1,017-file source manifest. Signatures,
recorded executable/provenance hashes, and all 317 renderer runtime/notice files
matched before and after the gates. The
[installation record](../.local/cycles-app-validation/installed-round4.json)
identifies the exact moved candidate and retained rollback bundle.

The [installed native report](../.local/cycles-app-validation/native-round4/report.json)
records the complete 30-object Table preview finishing at 64 samples on Metal
within the unchanged 1 GiB preparation cap, navigation and preview resumption,
bounded project reads, native texture-source replacement preserving every mapping
field, exact Undo/Redo, and restoration of the original project and camera.
[Lifecycle round 4b](../.local/cycles-app-validation/lifecycle-round4b/report.json)
passed cancellation, helper-crash recovery, destination preservation, project
and source invalidation, missing-asset rejection, and all protected-field checks.
The [first round 4 attempt](../.local/cycles-app-validation/lifecycle-round4/report.json)
remains failed: its only final discrepancy was `camera.viewportAspect`, changed
when a project switch removed the cloth contextual toolbar. The settled,
unselected Table rerun passed full camera equality; the earlier failure was not
discarded or treated as a pass.

This chat still has its pre-update long-running MCP helper and cached client
wrappers. During candidate 4 verification, a fresh helper from that installed
bundle was separately verified to match the running app's schema and build in
[fresh-helper-discovery.json](../.local/cycles-app-validation/native-round4/fresh-helper-discovery.json).
That result does not establish a host/client wrapper refresh. Authoring uses the
fresh matching packaged helper; new host wrappers require reconnecting the client.

Candidate 5 addressed the mixed geometry on curved attachments that remained
in candidate 4, where conforming stitch curves sat over a rigid backing.
The shared backing/curve mapper passed its coordinated 87-test release run
(56 renderer and 31 application tests, no failures or skips). Its
[test matrix](../.local/cycles-app-validation/candidate5-test-matrix.json)
records the exact 1,021-file source manifest and 24 passing Python client checks.
The full-program curved control subsequently exposed the work-budget failure
corrected in candidate 6, as recorded above.
Current case decisions are recorded near the top and in the visible-review file.
Historical evidence below is retained with its original scope and does not transfer
acceptance to a newer candidate.

The Python authoring, bounded-reader, lifecycle-client and report checks run
without contacting LAB. The curved attachment plan test reads the authored
control specification under `examples/cycles-materials/geometry`. The latest
rerun passed 28 checks: 25 client/report tests and three curved-plan tests,
recorded in `python-clients-round8.log` and `python-curved-plan-round8.log`:

```sh
python3 -m unittest discover -s scripts -p 'test_*cycles*.py' -v
python3 -m unittest discover -s scripts -p 'test_curved_attachment_plan.py' -v
```

The first complete candidate passed CPU and Metal with network and development
reads denied (`.local/cycles-app-validation/offline-{cpu,metal}`), following
2,352 release tests with seven skips and zero failures (`regression-final.json`).
Its installed lifecycle check then exposed absent live progress and shot-recall
resume. Those failures remain in `lifecycle-round1` and `native-round1`; frame
presence after completion was not proof of progressive delivery.

The second frozen revision passed 2,373 release tests, three existing skips and
zero failures (`regression-round2.json` and `.log`). All forty rendering tests
ran with the real helper, including Metal initialization failure and CPU recovery.
`source-round2.json` records the tested source/test hashes. Both full signed-app
gates subsequently passed in `offline2-cpu` and `offline2-metal`: each used a new
LAB cache and minimal environment, denied network plus source/build/dependency,
engine-prefix, Swift build, Homebrew and Xcode reads, and rejected all seven
existing-file probes before rendering. All 317 Cycles runtime/notice files
remained unchanged; twenty private dynamic libraries resolved inside the bundle.
The full app signature was verified before the helper run. These checks exercise
the renderer in the complete bundle, not an application window or a pristine
Apple system compiler cache.

`candidate2-provenance/identity.json` and `codesign.txt` retain the exact ad-hoc
signed identities: application SHA-256
`6cb982cc247c4d0e92ea5fa058a1ceba9211bbd8fbc081bff1d99d1e245ab89e`,
packaged renderer SHA-256
`e5984bdacd80d181c041677aec70ba8666818d1aba0d54ca2029c64b67f94279`.
The native provenance records Apple clang 21.0.0 (clang-2100.4.1.1), macOS SDK
27.2, and compiler executable SHA-256
`fc5e3cbba6ad54059295cad716aacb05ace8235f5f7a6031f1d8c15d24bd6d66`.
The Cycles/dependency commits and source archive are the pinned identities above;
the application source manifest is separate from those upstream commits. The
compiler/SDK used to build is not the macOS deployment target. No Developer ID
signature or notarization is claimed.

After installation, `lifecycle-round2/report.json` passed actual preparation
cancellation, identified-helper termination after sample 1, app survival and
recovery to a denoised PNG/EXR pair, destination preservation, project/source
invalidation, missing-asset rejection and protected-project restoration.
`native-round2/report.json` ties the ordinary app to the same signed hashes. It
records automatic shot-recall resume, visible samples 0/1/144, picking over the
rendered Table, native stock/thread optical edits with exact Undo/Redo,
manufacturing-field preservation, save/reopen and restoration of the original
project including its camera. The earlier native editor lookup failures were
resolved: all six physical-editor tests passed in `physical-appearance-ui`, and
passed again in `focused-round3c.log`.

Those integration passes did not validate every color or material response.
Later inspection found three numerical rendering defects in candidate 2:
literal OCIO `sRGB` names fell back to linear without a configuration, the PNG
encoder divided already-straight RGB by alpha again, and the temporary float
texture EXR lacked an effective straight-alpha declaration. The new helper uses
built-in input identities, the explicit PNG writer flag and explicit float
texture node alpha mode described above. Failed baselines remain in
`.local/cycles/validation-color-before-cpu`, `validation-color-firstfix-cpu`,
`validation-color-float-before-cpu` and `validation-color-cpu-v2`.

The corrected numeric gate passed fourteen cases on both CPU and Metal in
`validation-color-{cpu,metal}-v3`. It independently calculates sRGB transfer and
checks actual unlit texture and environment EXR values, display exposure, PNG
straight alpha, float texture alpha and HDR retention. Progressive PNGs are
copied when their events arrive; dedicated cases require a copy while the helper
is still running. Integer texture storage quantization is bounded explicitly;
float/numeric EXR comparisons retain a 0.00003 absolute tolerance. This avoids
mistaking half/byte texture quantization for a transfer error.

Mesh tangent normal-map rotation, negative scale, nonuniform scale and mirrored
repeat now follow the selected UV0/UV1 basis. The old helper failed the eight
transformed-map comparisons by up to seventy byte values; those failures remain
in `validation-mesh-normal-before-cpu`. Corrected CPU and Metal gates compare
against independently authored tangent vectors, including two UV-set references.
Their reports are `validation-mesh-normal-cpu-v3` and
`validation-mesh-normal-metal-v3`. Curve and finish-factor regression evidence is
retained separately; passing a mesh gate alone does not cover those paths.

The final development-prefix helper SHA-256 is
`9cecdf2d70b5b7113e5fb80656c44af911524e52e0693f1ab9fe1431bd960faf`.
Its provenance was re-recorded and verified after the native input changes.
Native contract, curve mapping/detail/strength, masked finish factors,
plane/closed-polyhedron displacement, and progressive/preparation/real-OIDN
cancellation all passed again on CPU and Metal with that helper. Masked finish
references and equivalent curve/mesh normal references have zero maximum byte
error; displacement still changes 4,582 plane and 2,984 polyhedron silhouette
pixels and the zero-displacement layer restores both baselines exactly.
`.local/cycles/validation-final-color-v3/report.json` retains every report hash,
the copied engine provenance and test-script hashes. The fresh relocated payload
is `.local/cycles/relocated-color-v3/LAB.app`; its intentionally broken-kernel
copy passed typed Metal/Auto failure and CPU success in
`validation-metal-initialization-color-v3`. This is a helper fixture, not the
next full-application gate. Packaging/signing will change the relocated helper's
hash, which the next application gate must record separately.

The newer Swift work includes high-bit-depth grayscale transport, opt-in bounded
texture resampling, adaptive paper relief and local embroidery crossing
clearance, immutable Table snapshot preparation and resource-generation
invalidation for linked artwork, effects and masks. The complete release run in
`.local/cycles-app-validation/regression-round5.json` and `.log` passed all
2,405 tests with three optional benchmark skips and zero failures.
`source-round6.json` records that source revision. All 43 LabRendering tests ran
with the real helper and the matching Metal initialization-failure fixture;
all 1,161 FormApp tests passed. Earlier focused evidence remains in
`focused-round3c.log`, including twelve relief, eleven embroidery and six native
physical-editor tests.

Candidate 3's exact validation matrix is
`.local/cycles-app-validation/candidate3-test-matrix.json`. After that complete
2,405-test run, one production file changed: `CyclesSceneManifest.swift` now
honors an explicit numeric `srgb` declaration consistently across embedded
profiles and bit depths. All 47 rendering tests then passed with no skips in
`renderer-final-b.log`, including four new regressions. This is a full regression
plus a focused regression of the final change, not a second complete-suite run.
`source-candidate3.json` records the final source revision. An independent
exact-production-method harness also passed twelve real CPU renders and two
numeric fixtures, including sRGB/Display P3 profiles, eight-/sixteen-bit inputs,
grayscale, alpha, raw/linear channels and overflow rejection in
`.local/cycles/validation-declared-encoding-fixed/report.json`.

The complete third candidate passed both isolated CPU and Metal gates in
`offline3-cpu` and `offline3-metal`. Each used a new LAB cache, minimal environment,
denied network and development-path access, and verified all seven existing-file
denial probes. All 317 renderer runtime/notice files remained unchanged, with
twenty private dynamic libraries resolved inside the bundle. Full application
signature verification and application/helper/MCP executable hashes matched
before and after the gates. These checks do not claim an empty Apple system
compiler cache or a bytewise comparison of every file in the application bundle.

`candidate3-provenance/gate-report.json` and `identity.json` retain the evidence.
The ad-hoc signed application executable SHA-256 is
`2428a38ebb0dc31bdea3cf3ee8aac2a35e9afed74733f90000236be1876123f7`;
the packaged renderer is
`245d1e61d630b53fff7468f8880b34dde9d5e59639e29b5ed1fc4ec9b2783159`.
All 1,012 recorded source entries matched the candidate's source manifest.

At the candidate 3 handoff, the material report recorded zero accepted cases out
of eight. That was a historical checkpoint, not the current acceptance count;
the current visible-review file records candidate 6 decisions. The first final
3000×2000 main batch with a 512-sample budget is complete. Its rejected warm vellum set is
retained alongside the accepted neutral replacement. Dedicated paper-edge,
cloth-reverse, strand-contact and matte/lustrous controls have been reviewed;
the final finished-cotton foil correction also passed in the current record.
Earlier renders made
before input-color fixes remain historical diagnostics. Preserve failed attempts
when regenerating the portable review report with the final reviews, exact
current image hashes and bundle identities.
The saved needle-program diagnostic is
`.local/cycles-materials/diagnostics/thread-fill-local-clearance-round5.json`. These
numerical results predate the installed candidate 3 reference-render review;
its signed-app gates are recorded above. Actual reference comparison remains
required.

The subsequent declared-encoding check found a separate high-depth Swift
serialization defect: an embedded Display P3 profile changed sixteen-bit color
while the same eight-bit numeric `srgb` input correctly used its declaration.
The retained failure is
`.local/cycles/validation-declared-encoding-profile/report.json`. The corrected
serializer reads numeric channels, unpremultiplies, applies exact sRGB decoding
and rejects decoded overflow. Its production-method standalone replay passed
twelve real CPU renders, independent grayscale transfer-boundary and alpha
checks, and finite-input overflow rejection in
`.local/cycles/validation-declared-encoding-fixed/report.json`. P3 eight-bit and
sixteen-bit inputs now produce identical PNG RGB `[204, 102, 51]`; declared
`linear` and `data` controls remain unchanged. This patch and its four new Swift
tests were added after the 2,405-test run. The complete LabRendering rerun then
passed all 47 tests with no skips or failures in
`.local/cycles-app-validation/renderer-final-b.log`. The PNG assertions read
numeric samples; that reader also matched an independent PNG decoder exactly
across 24 retained final/progressive images. `candidate3-test-matrix.json`
records the full baseline and this subsequent verification separately;
`source-candidate3.json` records the final source identity. The native helper
and its provenance are unchanged.

Candidate 3 subsequently passed the CPU and Metal bundle gates above and was
installed at the single ordinary LAB path. Installed native review found a
concrete complete-Table preparation failure: the 29-object study exceeded the
1 GiB render transfer budget (`native-round3/table-progress.png` and `.txt`).
Physical maps were decoded separately for each material, reverse surface and
finish, while the manifest reused only identical `CGImage` object instances.

The follow-up uses immutable image sources whose SHA-256 is verified against the
actual encoded bytes. A preparation scope reuses decoded sources, and a strict
256 MiB LRU retains reusable sources between preparations only after their
current files are verified again. The manifest shares equal verified bytes only
when their declared color/data encoding matches; independent UV coordinates,
repeat, offset, rotation and channel selection stay on each binding. Arbitrary
revision strings are not trusted as content identities. Replacing a payload's
image revokes its verified identity. Final maps retain full precision/resolution
and the existing 1 GiB transfer limit. Overridden substrate maps are resolved
before serialization, so unused color/roughness/metallic/emission files consume
no budget; base normal/detail, artwork, finish masks and emission fallbacks stay
in the resolved shader.

The first focused follow-up passed two renderer tests and thirteen app tests in
`.local/cycles-app-validation/texture-dedup-focused.log`, including eight native
editor tests. Eighteen independent decodes of one 2048-square sixteen-bit map
now transfer one unchanged 64 MiB resource instead of 1.125 GiB. The read-only
complete-Table diagnostic passed with all 29 objects, 30 renderables, four curve
groups and 75,798 triangles: 152 texture references resolved to 61 resources,
using 895,795,692 of 1,073,741,824 budget bytes before dead-map elimination.
`texture-dedup-project.json` records that snapshot revision and design digest.
The final rerun also records the exact captured atomic manifest hash and time;
it copies that manifest and its immutable object files into a temporary directory
while reading original immutable assets, so authoring may continue independently.
Run this optional external-project diagnostic with `LAB_CYCLES_TEST_PROJECT` and
`LAB_CYCLES_PROJECT_BUDGET_REPORT`; without a project path it explicitly skips.
The associated native import fix preserves an existing channel's authored UV,
physical repeat, offset, wrap and rotation when replacing its image source.

Candidate 4's records above cover this texture-budget follow-up's regression,
build, bundle gates and installed Table/lifecycle verification. Candidate 6's
records additionally cover the corrected full-program curved attachment and
installed export identities. Manufacturer material cases still require
current whole/close/grazing renders with comparison to the original references
and explicit review of paper relief, fabric microstructure, strand placement
and matte/lustrous separation. Optical estimates remain labelled as estimates.
Preserve prior failures and do not declare reference acceptance from test counts,
render completion or packaging alone.
