# Agent modeling fixtures

These are model documents supplied to the installed app through its tool bridge.
Their geometry is not registered as an application product type.

- `loop.json` freezes the three definitions used for the before/after warm-edit benchmark. Keep the source, edited parameters, requested quality and image settings identical when comparing app builds.
- `fitted-lid.json` supplies a hollow container and a separate fitted cap, measured fit/interference requirements, bounded controls and four named planar surfaces. Its local axes let front, side and lid artwork remain upright in their physical surface coordinates.
- `curved-vessel.json` supplies an intentional parameter relationship failure at a narrow-rim/wide-body case. The acceptance script repairs the profile and its saved requirement atomically, then reruns the same cases.

Run `scripts/smoke_agent_modeling.py` with `LAB_APP_PATH` pointing to the packaged app. The script also authors an additional five-panel construction from capability data, exercises a measured fold-and-glue join and explicitly converts the two legacy paper examples without changing application code.
