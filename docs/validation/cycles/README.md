# Bundled Cycles validation

[summary.json](summary.json) is a compact, sanitized snapshot of the completed
Apple Silicon/macOS 15+ validation. It records the actual signed executable and
metadata hashes, pinned engine/dependency revisions, source snapshot hash and
the hashes of retained local evidence. It contains no user-project contents or
absolute workstation paths. The source snapshot was taken before the PR commit;
the installed build's explicit dirty-source/build metadata is retained separately
from its actual signed executable hashes.

The release regression passed 2,441 tests with zero failures and three optional
external-fixture skips. All 28 Python client/report/curved-plan checks passed.
Real renderer tests included CPU/Metal rendering, typed Metal-initialization
failure and Auto CPU recovery, curves, full-program attachment mapping and the
complete Table preparation budget.

Both full signed-bundle gates passed with network and development reads denied,
seven existing-file denial probes, empty LAB caches, 20 private libraries and 317
unchanged renderer runtime/notice files. Signature and executable/metadata hashes
matched before and after. The tests did not claim an empty Apple compiler cache.
Installed lifecycle checks passed cancellation, sampled-helper crash/recovery,
source/project/asset invalidation, destination preservation and export provenance.
Native checks covered the full 36-object Table, 64-sample Metal previews, orbit,
pause/resume and a saved Studio scene. Eleven protected original-project fields
were preserved exactly; that project's content is excluded here.

All eight material studies passed visible reference review. The current output
inventory contains 24 main views and 17 controls at 3000×2000 with a 512-sample
budget and adaptive threshold 0.01. Forty completed at 512 samples; the satin-back
control stopped adaptively at 224. Actual PNG/EXR/record hashes, runtime identities
and exact accepted-review coverage were verified for all 41 outputs. The portable
project report retains rejected attempts and later corrections. These are authored
material-family studies with documented optical/geometry estimates, not measured
manufacturer BRDFs, calibrated cloth mechanics or validated sew-outs.

Reproduction commands and installed-report pointers are in
[bundled-cycles.md](../../bundled-cycles.md). The editable corpus, licensed donor
asset provenance and capture/report scripts are documented in
[examples/cycles-materials/README.txt](../../../examples/cycles-materials/README.txt).
The normal build invokes `scripts/package-cycles.py` after verifying the pinned
engine. Runtime binaries, caches, downloaded dependency trees and local projects
are build artifacts, not committed source.

This summary records executed checks; it does not claim Developer ID notarization,
Intel distribution, or that the full private local evidence is included in the PR.
