# LAB engineering rules

## Generic application, project-authored objects

- Never add project-specific models, object categories, geometry generators, recipes, fixtures, or named examples to application code to satisfy a modeling request.
- Build objects using the app's existing generic modeling tools and MCP. Store their definitions, parameters, reference images, and presentation scenes in the project package.
- When the tools cannot express an object, upgrade the generic modeling capability first. The implementation and tests must be useful across unrelated kinds of objects. Then author the requested object as project data through those tools.
- Do not add a hard-coded application branch keyed to a project's name, recipe identifier, or object name.
- Do not open a second copy or special edition of LAB for a project. Keep a single ordinary LAB app running. Build updates without replacing a live executable; quit and relaunch the regular app when installing a verified update.
- Preserve existing user projects and camera controls. Do not send printing, motion, or heating commands unless separately authorized.

## Visual modeling acceptance

- A passing test suite, closed mesh, high polygon count, exported file, or completed checklist does not establish visual quality.
- For reference-led modeling, perform repeated visible design loops: inspect the original reference, inspect actual app renders at matching whole-object and close-up views, identify specific discrepancies, revise the model, and inspect again.
- Compare silhouette, proportions, construction, surface detail, edge character and material response from multiple angles. Keep visible evidence of each meaningful round and the resulting improvement.
- Match the requested reference fidelity before moving to handoff, packaging or declaring completion. Do not excuse a coarse model as print resolution when a larger, detailed master is required. Evaluate the detailed master and fabrication adaptation separately.
- When asked for parametric variation, test and preserve materially different configurations. Controls for growth, anatomy, composition or size must change those things; do not substitute style changes or many nearly identical views of one layout.
- Keep a consistent visual family when requested. Expose composition and growth controls without turning fixed design language into unrelated aesthetic options.
- Record the actual app work when requested, including revisions, failures, native parameter changes and variant reviews. Do not replace that evidence with a polished turntable or a narrative of work that was not captured.
- Do not mark a modeling goal complete while visible discrepancies remain or the user has rejected its quality. Continue the model and generic tool improvements needed to meet the acceptance criteria.
