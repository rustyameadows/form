# Physical materiality follow-up: authored anisotropy direction

The native helper now binds mesh anisotropy to the authored UV chart. Previously,
the implicit Cycles tangent used generated coordinates and ignored UV direction.
Changing UV0 by 90 degrees therefore left the highlight unchanged. Triangle-order
checks already passed in that old helper; this evidence does not claim otherwise.

These are actual helper PNGs, copied without editing. The fixture uses a constant
anisotropy-strength texel and an unclipped area light to isolate direction.

| Helper | Original UV0 | UV0 rotated 90° | Independent scalar quarter-turn reference |
| --- | --- | --- | --- |
| Before | ![](before-uv0.png) | ![](before-uv90.png) | ![](before-quarter-reference.png) |
| Corrected | ![](after-uv0.png) | ![](after-uv90.png) | ![](after-quarter-reference.png) |

[Summary and hashes](anisotropy-summary.json) records the exact helper and verifier
identities. The old helper fails 9 of 17 comparisons. The corrected CPU and Metal
runs pass all 17 with zero byte error in their checked regions. No checked render
clips a color channel; maximum RGB is 187/255. The checks cover UV0, UV1, 90°
material rotation, nonuniform and negative texture scales, mirrored UVs/repeats,
rectangular/skewed chart metrics, triangle permutations, missing-UV fallback and
its axis pole, unchanged isotropic behavior, and longitudinal curve direction.
The old/new isotropic and curve control images also match pixel-for-pixel.

The implementation uses Cycles' `TangentNode` in UV-map mode. For a rotated
anisotropy texture, a derived affine UV chart lets upstream MikkTSpace retain the
physical metric instead of rotating an orthonormal frame incorrectly. Charts are
deduplicated, allocated only on meshes using the corresponding material, checked
for cancellation, and limited to 128 MiB of additional UV/tangent/sign storage per
job. UV0 is the default; an anisotropy texture owns its selected UV set and affine
mapping. Curves retain their longitudinal tangent. Full semantics are in
[the helper protocol](../../../../Native/LabCycles/PROTOCOL.md).

Reproduce with the pinned helper after `bash scripts/install-cycles.sh`:

```sh
python3 scripts/verify_cycles_anisotropy.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/anisotropy-check-cpu --device cpu
python3 scripts/verify_cycles_anisotropy.py \
  --helper .local/engines/cycles-3eb35f85996b/lab-cycles-render \
  --output .local/cycles/anisotropy-check-metal --device metal
```

Output directories must not already exist. Metal requires actual GPU access.
The existing `verify_cycles_mesh_normals.py` and `verify_cycles_curves.py` also
passed on CPU and Metal; their reports are retained alongside the main reports.
Raw scenes, EXRs and event streams are under `.local/cycles/validation-anisotropy-*`.

This is direction correctness evidence, not a measured BRDF match. The ordinary
LAB application was not replaced for these checks. Anisotropic highlights change
intentionally, so final paper/finish review in the updated app remains separate.

## Paper, finishes and lighting regression

The final source-stable release suite executed **2,624 tests: 2,621 passed,
3 optional performance fixtures skipped, and 0 failed**, in 663.79 seconds. All
1,085 captured source files remained unchanged. Real helper integration and the
saved full Table/attached-program diagnostics were enabled: all 1,214 strands
and 21,786 keys were retained, and the 36-object Table stayed within the existing
1 GiB transfer budget without downsampling. Python client checks passed all
30 tests. [Regression evidence](regression.json) records source, helper and log
hashes, exact target counts, retained failed attempts and the recovery-schema
budget check.

The three analytic cut-edge maps and their provenance reproduced byte-for-byte:

```sh
python3 scripts/prepare_cycles_paper_edges.py \
  --output .local/cycles-materiality-followup/reproduced-edge-assets
```

These maps are authored estimates, not measured manufacturer data. This is an
engineering checkpoint: building and verifying the updated app bundle, installed
native-control checks, and visible paper/finish acceptance remain pending.
