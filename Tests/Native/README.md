# Standalone GProp regression

These C++ files are compiled by `scripts/verify_cad_gprop_cancellation.py`, outside the SwiftPM targets. They include the real C ABI adapter to exercise its private task/publication path without adding a production diagnostic API.

```sh
python3 scripts/verify_cad_gprop_cancellation.py \
  --old-prefix .local/engines/occt-8.0.1 \
  --prefix .local/engines/occt-8.0.1-form-gprop2 \
  --output .local/validation/gprop-native-fresh
```

The prefixes must be distinct and are read-only. The runner generates six analytic BReps and retains all commands, hashes, timing, failures and outputs in a new directory. Add `--fixture path/to/model.brep` for a dense saved model; it gets the same cancellation and numerical controls. No model or fixture is simplified and numerical epsilon remains `1e-9`.

The proof triggers cancellation at active GProp poll 50, forwards the actual production context atomic, and independently covers volume/publication and surface quadrature. It requires `FCAD_CANCELLED`, no partial publication, unchanged source and prior accepted info, nested/null/thread scope restoration, and successful publication on a different native thread afterward to prove the global gate was released.

For every fixture, old-library, patched-null-probe and patched-production-probe runs must have identical raw bits for all 26 doubles: volume/area, both centers and both full inertia matrices. Complete serialized BRep bytes must also match, while original input files and both engine prefixes remain unchanged. The production variant counts/forwards its installed atomic probe, rather than testing only an unused null callback. Finite controls are evidence for those shapes, not a universal numerical or hard deadline guarantee.
