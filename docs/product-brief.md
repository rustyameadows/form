# FORM

Project Brief | Version 0.1

A native Mac creative environment for designing and making physical things.

## 1. Vision

Form is a new kind of creative software for people who make physical products.

Where Photoshop works with images, Logic works with music, and Final Cut works with video, Form works with objects.

It combines a spatial creative canvas, intelligent product modeling, 2D design tools, material libraries, and fabrication workflows into a single integrated environment.

The central idea is simple: Start with the thing you want to make, not the software or file format required to make it.

Someone designing a clock, a lamp, a notebook, a piece of packaging, or an entire merchandise collection should be able to work in the same environment. Form understands physical dimensions, materials, components, construction methods, and manufacturing possibilities.

AI helps establish the initial object and its editable parameters. The designer then works directly with those objects using familiar, responsive creative controls.

Form should feel closer to a combination of Figma, Pixelmator, and a physical design studio than a traditional CAD application.

## 2. The central experience: The Table

The primary interface is a large, navigable 3D work surface inspired by Donald Judd’s studio tables.

Everything associated with a project can exist together in this space.

* Physical objects: Notebooks, packages, clocks, lamps, components, and product mockups at real-world scale.
* 2D objects: Artwork, SVGs, photographs, sketches, instructions, and reference materials.
* Materials: Paper, fabric, wood, plastic, ink, paint, and finish swatches.
* References: Existing commercial products, historical examples, imported 3D models, and photographic studies.
* Iterations: Earlier and newer versions of the same object, arranged beside one another.
* Variants: Different colors, materials, finishes, dimensions, and configurations of one design.

The Table should feel like a physical studio where someone has placed everything they’re working on in front of them.

Objects can be picked up, moved, rotated, duplicated, grouped, and compared. The camera can orbit, zoom, and move between an angled perspective and a straight overhead view.

The placement of an object on the table is independent of the object’s actual construction. Rearranging the workspace does not change the product’s dimensions.

Hero interaction: An agent creates a new product and the resulting 3D object appears on the Table beside the existing references and previous iterations.

## 3. Designing a product

Form begins with a product description, reference, or existing object.

A designer might say:

> “I want to make a cyanotype kit with twenty 8-by-10-inch sheets of paper, a little instruction booklet, and a custom printed folding sleeve.”

The agent interprets this as a physical product composed of three components, creates their initial geometry, and places them on the Table.

It also establishes the first set of editable product parameters.

For the cyanotype kit, these could include:

| Component | Editable properties |
| --- | --- |
| Paper stack | Width, height, sheet count, thickness, paper stock |
| Instructions | Dimensions, page count, paper, binding |
| Sleeve | Dimensions, stock, folds, closure, bleed, artwork |
| Assembly | Component positions, clearances, fit |
| Complete kit | Overall dimensions, estimated weight, materials |

The creator does not need to understand how to build the underlying parametric geometry.

The agent constructs the first model using the application’s available geometry and construction capabilities, then presents a useful control surface for editing it.

### Generated control surfaces

Each object receives controls appropriate to its construction.

A clock might have diameter, depth, bezel thickness, mounting options, dial layout, and movement dimensions.

A notebook might have page dimensions, paper count, ruling, cover material, and binding options.

A lamp might have shade dimensions, wall thickness, base geometry, materials, and component clearances.

These controls are generated from the object’s actual editable parameters, using native Mac interface components.

The important interaction: Changing a dimension or material should immediately update the object without another AI generation request.

## 4. One object, multiple representations

A product may have several representations that are connected but independently editable.

Consider a folding paper sleeve:

* In 3D, it appears as the assembled package, with thickness, folds, and materials.
* In 2D, it appears as an unfolded dieline with cut lines, scores, and artwork.
* In a render, it appears as a finished object with realistic lighting and materials.
* In production, it becomes printable artwork, cutting instructions, and assembly documentation.

All representations are derived from the same underlying product definition.

Selecting a printable face of the sleeve and choosing Edit Artwork opens a focused 2D editor.

The designer can change typography, graphics, colors, and layout while the assembled 3D package remains visible alongside it, updating live.

Editing the sleeve’s width regenerates the appropriate geometry and dieline while preserving artwork placement wherever possible.

This 2D/3D relationship is one of Form’s defining capabilities.

## 5. The native 2D editor

Form includes a capable, focused 2D design environment.

Initial editing capabilities:

* Vector shapes and paths
* Text and typography
* Imported images and SVGs
* Layers and grouping
* Fill, stroke, opacity, and color
* Alignment, guides, and snapping
* Precise dimensions and positioning
* Artwork clipping and masks
* Basic transform operations
* Print bleed, safe areas, cut and score overlays

The editor works in real-world units by default. Inches, millimeters, centimeters, and points are appropriate throughout the application.

A 2D document can exist independently on the Table or be attached to a product face, package panel, or printable sheet.

Changes made in the 2D editor appear on the corresponding 3D object in real time.

The first implementation should focus on precise vector artwork, typography, and print preparation rather than reproducing every capability of Illustrator or Pixelmator.

## 6. The product model

The foundation of Form is a modular, semantic representation of physical objects.

A product is not simply a mesh or CAD file. It consists of connected definitions:

Geometry: Shapes, dimensions, transforms, surfaces, and relationships.

Components: Individual physical parts and their assembly.

Materials: What components are made from and how they appear.

Construction: How parts are folded, joined, fitted, printed, or assembled.

Parameters: The properties a designer can directly manipulate.

Constraints: Fixed dimensions, clearances, requirements, and dependencies.

Artwork: Editable 2D graphics attached to specific surfaces or components.

Representations: Meshes, solids, 2D patterns, rendering assets, and manufacturing outputs.

The underlying system should support primitive and parametric geometry, imported meshes, and construction recipes.

For example, a folding box is defined by panels, folds, scores, tabs, and material thickness. The 3D assembled form and flat cutting pattern are generated from that construction definition.

A vase might instead be defined by a profile, revolve operation, wall thickness, and material.

The same product graph can describe very different objects without requiring a unique editor for every product category.

## 7. A continuous AI collaborator

Every Form project has a persistent agent conversation.

The agent is involved in the full creative process, from exploring an initial idea to constructing, modifying, researching, and preparing the finished product.

### Creation

The agent interprets the request, develops a proposed construction, creates initial objects, and generates their control surfaces.

This is the most reasoning-intensive phase and should support frontier models.

### Iteration

The agent can perform more involved operations such as:

> “Make another version of this clock, but try a much thinner bezel and move the hour markers inward.”

It creates a new iteration, preserves the previous version, and places the new object beside it.

### Direct changes

Simple edits are performed by the application itself.

“Change the diameter to eight inches” should directly update a known parameter. It should not require regeneration of the object.

### Continuous conversation

The project preserves the original creator conversation and its API thread or conversation identifier wherever supported.

Future creative requests should continue that conversation, preserving the context developed during creation and subsequent work.

The application may use different model capabilities for different tasks, but the experience should feel like working with one continuous collaborator.

### Open questions and decisions

The agent maintains two complementary collections.

Open Questions are things requiring resolution: an unknown clock movement diameter, an unspecified material, or a missing manufacturing detail.

Design Decisions are a living record of the project’s goals, preferences, and constraints: “The paper should feel substantial,” “The kit must contain at least 20 sheets,” or “Avoid visible plastic packaging.”

These are directly editable through the UI.

Decisions can be revised, pinned, or removed. Open questions can be resolved by the designer, researched by the agent, or satisfied by a proposed default.

When something changes, the system identifies affected components and updates or flags them as appropriate.

## 8. Iterations and variants

Form treats experimentation as a fundamental part of the design process.

Iterations are distinct generations of a design. They preserve the evolution of geometry, construction, and creative decisions.

Variants are alternate configurations of an existing design, often sharing the same geometry while changing materials, colors, graphics, or selected parameters.

Both can be displayed simultaneously on the Table.

A designer might have three generations of a clock, each with four color variants. All twelve can appear together, arranged spatially for comparison.

The application tracks the relationships between them.

Variants should share underlying assets wherever possible. A material variation should not require duplicating an entire geometric model.

## 9. Materials and Studio Library

Form maintains a persistent Studio Library independent of individual projects.

### Materials

The library contains physical materials and their visual properties.

Initial categories:

* Paper and card stock
* Plastics and 3D printing filaments
* Wood
* Metals
* Fabric
* Ink, paint, and surface finishes

Each material can contain its name, manufacturer, color, thickness, finish, texture, and other useful specifications.

Materials are reusable across projects and can be represented as swatches on the Table.

Render properties and physical properties are related but distinct. For example, paper thickness influences geometry, while roughness and texture influence its appearance.

### Studio equipment

Users can define the tools available in their studios, including printers, cutters, plotters, and 3D printers.

Each tool can have supported dimensions, materials, and relevant output formats.

Form can then use those capabilities when preparing files or recommending fabrication methods.

For example, a studio with an 11-by-17-inch printer might use that format by default for prototype proofs, while the finished product uses a different manufacturing method.

The first version can manage equipment profiles and exports without requiring direct hardware control.

## 10. Rendering Studio

Form includes a separate rendering environment for creating attractive representations of products.

The primary Table is optimized for interactive editing and spatial organization.

The Rendering Studio is optimized for presentation.

It should offer:

* Studio lighting presets
* Backgrounds and surfaces
* Camera position, focal length, and framing
* Accurate physical scale
* Good material presets
* Soft shadows and realistic reflections
* Product and collection compositions
* High-resolution image export

The material system should emphasize surfaces relevant to real manufacturing: paper fibers, uncoated stock, cardboard edges, plastic, layer-textured 3D prints, wood grain, textiles, and printed inks.

A designer should be able to take a product from the Table, choose a studio preset, and produce a polished presentation image with very little setup.

## 11. Native Mac architecture

Form is a macOS-first application built entirely around native technologies.

| Layer | Proposed technology |
| --- | --- |
| Application interface | SwiftUI and AppKit |
| Interactive 3D scene | RealityKit initially, with Metal underneath |
| Future custom rendering | Metal and MetalKit |
| 2D graphics | Core Graphics, Core Text, AppKit |
| Geometry processing | Native procedural geometry, with Open CASCADE for advanced solid operations |
| Image processing | Core Image and Metal |
| Local persistence | File packages, JSON, SQLite where useful |
| Agent integration | Model APIs with persistent conversations and structured tool calls |
| External automation | MCP interface over the same application operations |

The rendering implementation should be replaceable independently of the product model and geometry systems.

Open CASCADE is a strong candidate for the advanced geometric kernel. It can be integrated through a C++ bridge and used for solid modeling, booleans, extrusions, fillets, and CAD interoperability.

Simple procedural objects and folding constructions can be implemented before deeper kernel integration.

No proprietary CAD engine license is required for the proposed initial architecture.

### Modular project files

A Form project should appear as a single .form document in Finder but internally function as a package of independent resources.

The package contains:

* Project manifest and object relationships
* Individual parametric object definitions
* Imported and generated geometry
* Editable 2D artwork
* Material references
* Construction definitions
* Agent conversation and project history
* Decisions and unresolved questions
* Iteration and variant metadata
* Cached meshes, textures, previews, and renders

An individual object can be opened, edited, cached, regenerated, or rendered without rebuilding the entire project.

Assets can progressively load into the Table. Objects that are not being actively edited remain lightweight renderable representations.

The scene references these independent resources instead of becoming one enormous CAD document.

Geometry, artwork, studio placement, and render settings are maintained separately.

## 12. Version 0.1: The first working application

The first version should demonstrate Form’s fundamental interaction model through a complete, functional creative workflow.

It should be a real application with persistent projects and editable objects, not simply a visual prototype.

Primary demonstration project: A cyanotype kit.

The demo includes a stack of paper, an instruction booklet, and a folded paper sleeve.

### Required capabilities

#### A. The Table

A native 3D workspace with camera navigation, object placement, selection, transforms, grouping, duplication, and save/reopen support.

Support multiple objects, images, and material swatches in a single scene.

#### B. Parametric objects

A small, extensible geometry system supporting basic shapes, dimensions, thickness, materials, and object hierarchies.

Include recipes for a paper stack, booklet, folding sleeve, and a few general primitives such as boxes, cylinders, and extruded profiles.

#### C. Agent-created products

A functional agent capable of translating a product description into supported structured objects, parameter definitions, and initial layouts.

The agent can add objects to the scene, modify parameters, create variants, and flag missing information.

#### D. Generated controls

Native property inspectors populated from object parameter schemas.

Changing parameters updates geometry and the scene immediately.

#### E. 2D artwork editing

A focused editor supporting basic vector shapes, typography, imported images, and dimensional layout.

Artwork attached to a package face or sheet updates its 3D representation live.

#### F. Folding packaging

At least one actual construction recipe supporting a scored folding sleeve or folder.

The user can examine the assembled 3D package and edit or export its unfolded dieline.

#### G. Iterations and variants

Duplicate an object as an independent iteration or create material and artwork variants sharing a common underlying design.

Display multiple versions together on the Table.

#### H. Materials

An initial library of realistic material presets and a persistent user-defined Studio Library.

#### I. Rendering

A simple Rendering Studio with good lighting defaults, camera controls, and PNG export.

#### J. Production outputs

Export the cyanotype kit’s printable artwork as PDF and its package dieline as SVG.

Produce a basic component and material summary.

### The end-to-end acceptance test

A user should be able to:

1. Open Form and create a project.
2. Describe a cyanotype kit in natural language.
3. Watch its components appear as separate physical objects on the Table.
4. Select the paper stack and change its dimensions and sheet count using native controls.
5. Select the sleeve and edit its graphics in a 2D window, seeing the 3D mockup update.
6. Change the sleeve’s stock and color.
7. Ask the agent for a new version with a different folding arrangement or appearance.
8. See the original and new iteration beside one another.
9. Generate several color and material variants.
10. Produce a studio render.
11. Export the artwork and dieline needed to make a physical prototype.
12. Save the project, quit the app, reopen it, and continue the original agent conversation.

If that works, Form has demonstrated its central proposition.

## 13. Recommended development sequence

### Milestone 1: The spatial document

Build the native Mac shell, camera, Table, object selection, object transforms, asset loading, basic materials, and project persistence.

Result: A functional 3D creative workspace containing independent, persistent objects and references.

### Milestone 2: Intelligent physical objects

Establish the parametric object format, dependency updates, geometry recipes, parameter controls, and material assignments.

Result: Objects can be meaningfully edited and regenerated without direct mesh editing.

### Milestone 3: Linked 2D/3D editing

Implement editable artwork surfaces, native 2D controls, live texture updates, and the initial folding construction with its dieline.

Result: A designer can move between artwork, geometry, and construction within the same project.

### Milestone 4: Agent collaboration

Connect the AI agent to object creation, parameter manipulation, iteration creation, and project questions. Persist the project conversation.

Result: A user can describe, construct, and iteratively develop a supported product through natural language.

### Milestone 5: The creative studio

Add the material library, variants, rendering presets, production exports, and initial studio equipment profiles.

Result: A designer can take a product from concept to a physical prototype and presentation asset.

## 14. Architectural principles

The first implementation should preserve the following principles as the application grows.

Real-world dimensions are foundational. Physical scale is intrinsic to the document, not an export setting.

Objects are modular. Every component can have its own geometry, artwork, parameters, and materials.

The Table is a composition, not a monolithic model. Many independently defined objects can share one spatial workspace.

Editing should be immediate. Parameter changes, material changes, and artwork changes should be deterministic and visually responsive.

AI creates editable systems. The agent’s most important output is not a static 3D mesh. It is a useful, manipulable product definition.

Design knowledge is explicit. Construction rules, material properties, decisions, and dependencies live in structured representations that tools can operate on.

Manufacturing is an extensible capability. New construction methods, exporters, fabrication devices, and third-party engines can be added without rebuilding the core application.

The user’s studio is part of the creative environment. Available tools, preferred materials, and established workflows inform how products are designed and produced.

## 15. Beyond the first version

The architecture should eventually accommodate:

* More sophisticated folded and corrugated packaging
* Rigid two-piece boxes, inserts, and trays
* Textile patterns and cut-and-sew construction
* Surface decoration, embossing, engraving, and printing
* More capable procedural and solid modeling
* 3D scanning and image-to-3D reference ingestion
* External CAD and electronics components
* Assembly instructions and exploded diagrams
* Automated bills of materials and costing
* Supplier and manufacturing integrations
* Direct 2D/3D printer, cutter, and plotter control
* Community-developed geometry and fabrication extensions
* Shared studio libraries and collaborative projects

The next useful validation after the cyanotype kit would be a clock or small lamp. This would test whether the same architecture can support a materially different product without rebuilding the application around a new category.

---

## The product thesis

Traditional creative software is organized around the representation being edited: images, vectors, 3D geometry, video, or documents.

Form is organized around the physical thing being created.

It brings together geometry, materials, artwork, construction, references, and production in one continuous environment. AI makes it possible to establish specialized controls and workflows for objects without requiring the application to be built around a narrow product category.

The result is a creative studio where a designer can begin with an idea, develop multiple versions, understand how something might be made, and produce the assets necessary to make it.

Form is a place to design things that exist in the world.
