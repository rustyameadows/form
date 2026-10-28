# LAB environment UI overhaul

October 27, 2026. This pass preserves Form and the established camera contract while giving Function, Fabricate and Studio their own working structures.

## Working design

- **Function — construction bench.** Component/relationship navigation at left, spatial and flat construction review in the center, technical editing at right. Dimensions and construction assumptions remain explicit. It is not the Form Canvas with a different inspector.

  Function remains medium-independent: lamp parts/assembly and dimensional behavior, fabric pieces/seams/stitching/cloth, paper folds/closures, and exact CAD features all belong here. Each object supplies the relevant views and controls; the carton is a demonstration, not the organizing template. Do not imply electrical/mechanical simulation where only declared parameters exist.
- **Fabricate — guided preparation.** Choose the source and quantity, explicitly choose a supported process, inspect/edit the actual material declaration, prepare the physical layout/settings, then review and export. Suggestions name their source and require confirmation; unknown physical properties stay unknown. Existing dedicated preparation tools remain accessible. No machine is sent or started.
- **Studio — composition stage.** Named saved presentation scenes contain independent instances of existing products/variants and simple shelf/riser props. Instance placement/material changes do not duplicate or modify design objects. Separate camera controls and a bounded camera-motion timeline provide image and actual video output, with saved revision/provenance records.

Generated image concepts are design references, not acceptance evidence or promises of unimplemented physical simulation. The implementation uses real project geometry and artwork for previews, never a generated mockup as application content. Prompts and selected concepts are retained under `docs/design/environment-ui/`.

## Implementation and acceptance

1. Review current workflows and generate three consistent visual directions.
2. Build distinct native Function and guided Fabricate workspaces, with discoverable editing and honest material provenance. Preserve all current process routes.
3. Add durable scene/instance/camera/motion definitions and strict shared native/MCP operations. Keep existing saved shots compatible and source relationships intact.
4. Build Studio composition, camera, saved-scene and timeline UI, plus real PNG and MP4 output. Bound work, serialize GPU capture, support cancellation, preserve existing destinations and reject stale or missing sources.
5. Test source isolation, duplication/variant replacement, transforms, camera interpolation, invalid commands, Undo/Redo and save/reopen. Run the complete suite and packaged/native checks, including real mouse camera/text navigation.
6. Review actual Function/Fabricate/Studio layouts at useful window widths. Install only a verified build, preserving the latest ordinary library, then commit and push meaningful stages.

## Boundaries

Camera motion is a presentation animation, not object/cloth/mechanical simulation. Scene instances refer to current design sources; exports identify their source revision. Existing manufacturing limits remain in force: material declarations are editable assumptions until measured, and outputs require physical proof. Machine execution, a general animation editor and external model calls inside LAB are outside this UI pass.

## Status

Accepted in the installed LAB 0.5 build. The complete 1,151-test suite, packaged paper/legacy-shot/scene workflows, real PNG/MP4 output, delayed bridge acknowledgement, native layouts and mouse interactions pass. Function was reviewed on lamps and fabric seam constructions as well as paper. All 204 original source/library files are exact after the preservation checks; the retail scene is a separate new demo. See [workflow and limits](environment-workflows.md) and [native acceptance](evidence/environment-ui-native.json).
