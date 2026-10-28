# LAB engineering rules

## Generic application, project-authored objects

- Never add project-specific models, object categories, geometry generators, recipes, fixtures, or named examples to application code to satisfy a modeling request.
- Build objects using the app's existing generic modeling tools and MCP. Store their definitions, parameters, reference images, and presentation scenes in the project package.
- When the tools cannot express an object, upgrade the generic modeling capability first. The implementation and tests must be useful across unrelated kinds of objects. Then author the requested object as project data through those tools.
- Do not add a hard-coded application branch keyed to a project's name, recipe identifier, or object name.
- Do not open a second copy or special edition of LAB for a project. Keep a single ordinary LAB app running. Build updates without replacing a live executable; quit and relaunch the regular app when installing a verified update.
- Preserve existing user projects and camera controls. Do not send printing, motion, or heating commands unless separately authorized.
