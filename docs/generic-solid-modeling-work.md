# Generic solid modeling upgrade — active task list

Application code implements reusable tools. User models, their parameter controls, source references and scenes live in project packages. Curated library assets are copyable starting points, never substitutes for a user's editable source.

## Cleanup

- [x] Close the extra test application.
- [x] Remove its generated bundle.
- [x] Remove the project-specific native recipe, generator and tests.
- [x] Add the permanent generic-modeling rule to `AGENTS.md`.
- [x] Preserve the new project's Canvas reference in the ordinary library.
- [x] Verify preexisting library source files against the fresh backup.

## Reusable modeling tools

- [ ] Add durable project-defined solid constructions to custom recipes.
- [ ] Support parameter expressions, ordered local bindings and bounded repeated groups.
- [ ] Support tapered rounded segments and oriented ellipsoids as reusable solid primitives.
- [ ] Fuse overlapping primitives into one indexed surface, with optional planar trimming and explicit final size normalization.
- [ ] Expose these capabilities through MCP with documented limits and validation.
- [ ] Use one shared construction for Table, Studio and fabrication mesh preparation.
- [ ] Keep model geometry caches bounded by actual buffer memory.
- [ ] Preserve legacy recipes, user data, input bindings and existing camera conventions.

## Verification and installation

- [ ] Validate malformed definitions, nonfinite expressions, repeat limits, bounds and resource budgets.
- [ ] Test unrelated constructions using the same generic tools.
- [ ] Test topology, orientation, physical dimensions, determinism, changes, persistence and undo.
- [ ] Run relevant tests followed by the complete suite after final source changes.
- [ ] Build an ordinary LAB update without launching another application copy.
- [ ] Quit the running regular app, install the verified update, and relaunch only that app.

## Requested project, authored as data

- [ ] Define editable controls and the full construction through MCP.
- [ ] Model curved spatial branching, rooted base, surface relief and dense radial foliage.
- [ ] Keep finite rounded tip sizes adjustable at the 101.6 mm target height.
- [ ] Compare front, sides, back and detail against the retained Canvas reference.
- [ ] Review and refine actual Table and Studio renders.
- [ ] Verify the saved definition and reference reopen in the ordinary app.
- [ ] Save finished Studio compositions and local preview exports.
- [ ] Record actual geometry checks and remaining manufacturing qualifications; never claim printer certification from a render.
- [ ] Commit and push reusable application changes and verification evidence.
- [ ] Leave the finished project open. No printing or printer commands.
