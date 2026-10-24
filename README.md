# FORM

A native Mac creative environment for designing and making physical things.

Form brings geometry, materials, artwork, construction, references, and production into one creative workspace. Start with the thing you want to make—a notebook, a package, a clock, a lamp—and develop it from an idea into an editable product and the assets needed to make it.

**Status:** Product definition. This repository currently contains the initial project documentation. Application implementation has not started.

Read the [Project Brief — Version 0.1](docs/product-brief.md) for the full vision, requirements, architecture, and acceptance workflow.

## The experience

- **The Table:** A navigable 3D studio surface where physical objects, artwork, references, material swatches, iterations, and variants sit together at real-world scale.
- **Editable physical objects:** Products carry dimensions, components, materials, construction rules, constraints, and artwork. Native controls update those properties immediately.
- **Connected 2D and 3D:** Edit a package's artwork and unfolded dieline while its assembled 3D representation updates live.
- **A continuous AI collaborator:** Describe a product, establish its editable construction, explore new iterations, and preserve the project conversation, open questions, and design decisions.
- **A path to fabrication:** Use studio materials and equipment profiles to prepare artwork, dielines, component summaries, and presentation renders.

AI establishes useful, editable product definitions. Routine parameter, material, and artwork changes run directly in the application without another generation request.

## Version 0.1

The first working application will demonstrate a complete **cyanotype kit** workflow: twenty 8-by-10-inch sheets of paper, an instruction booklet, and a printed folding sleeve.

The target workflow is to:

1. Create a persistent project and describe the kit in natural language.
2. Place its separate components on the Table and edit their dimensions, sheet counts, and materials through native controls.
3. Edit the sleeve's artwork in 2D with live updates to its assembled 3D form.
4. Create iterations and color or material variants, then compare them side by side.
5. Produce a studio render, printable PDF artwork, an SVG dieline, and a basic component and material summary.
6. Save, quit, reopen, and continue the original agent conversation.

The [full brief](docs/product-brief.md#12-version-01-the-first-working-application) defines the required capabilities and end-to-end acceptance test.

## Proposed architecture

Form is macOS first and built around native technologies. The initial architecture is a proposal to guide implementation.

| Area | Proposed foundation |
| --- | --- |
| Application interface | SwiftUI and AppKit |
| Interactive 3D workspace | RealityKit initially, with Metal underneath |
| Future custom rendering | Metal and MetalKit |
| 2D graphics and typography | Core Graphics, Core Text, and AppKit |
| Geometry | Native procedural geometry and construction recipes; Open CASCADE as a candidate for advanced solid operations |
| Image processing | Core Image and Metal |
| Persistence | Modular `.form` document packages, JSON, and SQLite where useful |
| Agent integration | Model APIs with persistent conversations and structured tool calls |
| External automation | An MCP interface over the same application operations |

The product model owns geometry, components, construction, parameters, constraints, materials, and artwork. Workspace placement and rendering remain separate, so the renderer can evolve independently and individual objects can load or regenerate without rebuilding the whole project.

## Development milestones

1. **The spatial document:** Native Mac shell, Table, camera navigation, object selection and transforms, asset loading, basic materials, and project persistence.
2. **Intelligent physical objects:** Parametric definitions, dependency updates, geometry recipes, generated native controls, and material assignments.
3. **Linked 2D/3D editing:** Editable artwork surfaces, live texture updates, and a folding construction with an unfolded dieline.
4. **Agent collaboration:** Structured object creation and editing, iterations, project questions, and persistent conversations.
5. **The creative studio:** Material library, variants, rendering presets, production exports, and initial equipment profiles.

The first implementation milestone is the spatial document. Build and test instructions will be added with the application code.

## Documentation

- [Project Brief — Version 0.1](docs/product-brief.md): The initial product document, including the vision, interaction model, proposed architecture, scope, milestones, and future directions.
