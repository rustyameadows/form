# FORM

## Textiles, Apparel & Merchandise

Product Vision & Development Brief

Extension to the Form Creative Environment | October 2026

---

## 1. Overview

Form is a native Mac creative environment for designing and making physical things.

The Textiles, Apparel & Merchandise capability extends Form into the world of fabric-based products, including clothing, accessories, decorated merchandise, embroidery, printed textiles, and sewn objects.

The ambition is to create a unified design and production environment where someone can develop an entire collection of physical products without having to assemble a workflow across numerous specialized applications.

A designer should be able to create a T-shirt graphic, place it on a garment, preview different fabrics and colors, develop an embroidered version, construct a matching tote bag, generate cutting patterns, and prepare files for the appropriate manufacturing equipment.

All of these activities happen within the same project, using the same objects, artwork, materials, and shared design context.

The central proposition: Form understands the object being made, the materials it is made from, and the processes through which it becomes physical.

The system combines traditional visual editing, dimensional product modeling, manufacturing knowledge, and AI-assisted creation.

It should be accessible enough for someone making their first piece of merchandise, while providing sufficient depth for an experienced designer developing a sophisticated product collection.

Importantly, this is not a separate fashion application. It is a new set of capabilities within Form’s existing physical-design environment.

## 2. The Opportunity

Textile product development remains fragmented across several categories of software.

A designer creating a relatively simple merchandise collection might use an image editor for graphics, a vector application for logos, a mockup generator for presentation, manufacturer-specific software for embroidery, and spreadsheets for materials, costing, and production.

Someone constructing garments introduces additional tools for pattern drafting, grading, fabric simulation, and technical documentation.

Even a single garment might incorporate multiple production processes: cut-and-sew construction, fabric printing, embroidery, patches, appliqué, hardware, and finishing.

Each process often has its own files, constraints, and software.

These workflows are particularly inaccessible to creators who understand what they want to make but are unfamiliar with professional garment development or manufacturing.

Form can bring these disciplines together around a shared physical product model.

Rather than organizing the experience around formats such as SVG, DXF, PDF, PES, or 3D meshes, Form organizes it around products and their construction.

The designer specifies what they want to make, works directly with an editable representation of it, and prepares manufacturing outputs as needed.

Target creators

Form should serve several overlapping audiences:

* Independent designers and artists: Developing merchandise, limited editions, apparel, and textile-based artworks.
* Small product brands: Building collections across garments, accessories, packaging, and related products.
* Makers and studios: Working with embroidery machines, fabric printers, vinyl cutters, sewing equipment, and other fabrication tools.
* Fashion and textile designers: Developing prints, patterns, garment concepts, material combinations, and prototypes.
* Creative businesses: Producing branded apparel, promotional merchandise, uniforms, costumes, and specialty textile goods.
* New creators: People who have a product idea but lack the technical skills traditionally needed to translate it into something manufacturable.

The software should accommodate different levels of technical expertise without requiring separate beginner and professional applications.

## 3. Product Scope

The textile system should support four broad categories of work.

### 3.1 Decorating existing products

The simplest entry point is working with an existing physical product.

Examples include:

* T-shirts and sweatshirts
* Hats and caps
* Jackets and workwear
* Tote bags
* Aprons and uniforms
* Backpacks and accessories
* Existing fabric objects and upholstery

A user selects or imports a blank product and customizes it through printing, embroidery, patches, graphics, trims, and other surface treatments.

The underlying garment does not necessarily need editable construction. It may be a supplier-provided 3D model with known dimensions and decoration zones.

This allows Form to support realistic merchandise workflows without requiring the user to construct garments from scratch.

### 3.2 Designing fabric and textile surfaces

Form should support designing the fabric itself, independently of the product it will become.

Capabilities include:

* Original textile prints
* Repeating patterns
* All-over graphics
* Engineered prints positioned for specific pattern pieces
* Colorways and material variations
* Woven and knitted visual patterns
* Surface treatments and textures
* Embellished textile panels

A fabric design might remain a standalone textile or be applied to a garment, accessory, or other physical object.

The same artwork can be reused across products, edited independently, and prepared for different printing or manufacturing processes.

### 3.3 Constructing soft goods

Form should support designing new physical objects from fabric and other flexible sheet materials.

Initial categories might include:

* Tote bags
* Pouches
* Pillow covers
* Cases and sleeves
* Simple wallets
* Fabric organizers
* Banners and flags
* Soft sculptures
* Textile accessories

The application understands that these products consist of flat pattern pieces assembled with seams, folds, closures, and other construction methods.

The system can generate both the assembled 3D representation and the flat patterns required for cutting and assembly.

This is closely related to Form’s existing folding-packaging architecture, with additional knowledge about sewing and flexible materials.

### 3.4 Designing garments from scratch

The most sophisticated capability is garment design.

Examples include:

* T-shirts and tank tops
* Shirts
* Jackets
* Pants and shorts
* Underwear and swimwear
* Dresses
* Costumes and performance garments
* Experimental fashion objects

These products require deeper modeling of garment construction, fabric behavior, sizing, fit, and body geometry.

Form should eventually allow a designer to develop a garment by describing its intended form, editing its pattern pieces, and reviewing a simulated assembled version.

The initial product can begin with preconstructed garment blocks and parametric patterns before introducing more advanced garment simulation and fitting.

## 4. The Core Experience: A Collection on the Table

The Table remains Form’s primary creative environment.

Imagine opening a project for a new merchandise collection.

The designer wants to create five T-shirts, two jackets, several hats, three patches, and a custom canvas bag.

They describe the collection to the agent, import reference images, or begin placing objects manually.

The resulting objects appear on the Table at real-world scale.

Each garment is a discrete object that can be selected, positioned, rotated, duplicated, edited, and compared with the others.

Reference photographs, fabric swatches, sketches, color palettes, embroidery samples, logos, and notes can live alongside the products.

A collection can contain dozens or hundreds of objects without requiring each object’s full editing environment to be active simultaneously.

The Table uses lightweight render representations until a designer selects an object for focused editing.

Example: Developing a jacket

A designer begins with an existing black work jacket.

They add an embroidered emblem to the left chest, a large printed graphic to the back, a custom label at the collar, and contrasting fabric on the pocket.

Form treats these as separate physical elements attached to the garment.

The embroidered emblem has thread and stitch properties.

The back graphic has a printing process and defined dimensions.

The collar label has material, dimensions, and an attachment method.

The pocket alteration involves either a decorative overlay or a change to the actual garment construction.

The user can edit each element independently.

They can then ask the agent to create three new versions of the jacket: one with a different color palette, one with an oversized back graphic, and another that replaces the embroidery with a woven patch.

The resulting versions appear beside the original.

Each version retains its relationship to the source design.

This is the central creative experience: the entire collection remains visible and manipulable while each product contains its own specialized design tools.

## 5. The Textile Product Model

Form needs a common representation that accommodates garments, fabric, patterns, decorative operations, and finished products.

The underlying product model should distinguish several kinds of information.

### 5.1 Product geometry

Defines the dimensions, shape, components, and spatial relationships of the object.

For an existing blank garment, this may be an imported 3D mesh with known sizing.

For a constructed textile object, geometry may be generated from editable 2D patterns and assembly instructions.

Geometry should use real-world dimensions throughout.

### 5.2 Materials

Defines the physical materials used in the product.

Examples include cotton jersey, canvas, denim, nylon, leather, elastic, interfacing, embroidery thread, and printed ink.

Materials have both visual and physical properties.

The initial system should support realistic appearance and basic specifications. More advanced physical behavior can be introduced as the simulation system develops.

### 5.3 Construction

Describes how the product is assembled.

For textiles, this includes pattern pieces, seams, hems, folds, darts, pockets, linings, closures, and attachment methods.

Construction information must exist independently of the resulting 3D mesh.

A designer should be able to change a pattern measurement or seam definition and regenerate the assembled representation.

### 5.4 Surface artwork

Describes graphics applied to fabric or garments.

Artwork can include vector graphics, typography, raster images, repeating patterns, and surface textures.

It is linked to specific physical surfaces, panels, or construction pieces.

The same artwork can support multiple production processes.

### 5.5 Manufacturing operations

Defines how individual design elements are produced.

Examples include embroidery, direct-to-garment printing, screen printing, sublimation, heat-transfer application, cutting, sewing, or hand embellishment.

A manufacturing operation contains process-specific parameters and references the geometry or artwork to which it applies.

### 5.6 Product configuration

Defines sizes, colorways, material combinations, component substitutions, and other variants.

Configurations should share underlying assets wherever possible rather than duplicating entire products.

### 5.7 Production information

Contains material quantities, equipment settings, manufacturing instructions, estimates, exported files, and prototype history.

A production output is connected to the exact design version and parameters that generated it.

These systems form one connected product definition while remaining modular in storage and editing.

## 6. Existing Garments and Blank Product Libraries

Working with blanks is an important early capability because it provides immediate utility without requiring garment construction tools.

Form should support a library of existing physical products.

A blank product definition can include:

* Manufacturer and product name
* SKU and available sizes
* Physical dimensions
* 3D model or reference geometry
* Fabric composition and weight
* Available colors
* Printable and embroiderable regions
* Garment construction reference points
* Supplier and purchasing information
* Cost and inventory information, when available

Users should be able to create their own blank definitions from measurements, reference photographs, and imported 3D assets.

An agent may help construct an approximate representation from imagery, but the application should distinguish estimated geometry from manufacturer-specified dimensions.

The blank remains connected to its decorations, which are authored separately.

A designer should be able to replace a blank with another similar product while preserving decoration definitions, then review placement and size differences.

The system should support multiple sizes and colors of a given blank.

For initial development, a small curated selection of well-constructed generic garments is sufficient.

Eventually, supplier catalogs or user-installed product libraries could provide large collections of actual purchasable blanks.

## 7. Surface Design and 2D Editing

Form’s existing 2D editing environment becomes the primary authoring surface for textile graphics.

A designer can select a region of a garment and choose Edit Artwork.

The application opens a focused 2D editor for that region while maintaining a live view of the corresponding 3D product.

The editor supports typography, vector graphics, raster imagery, masks, paths, alignment, layering, colors, and precise physical positioning.

Artwork is positioned in millimeters or inches rather than arbitrary screen pixels.

Placement and projection

Form needs a system for attaching artwork to physical products.

Decoration placement can be defined using:

* Flat rectangular print regions
* Surface-relative coordinates
* Garment landmarks and measurements
* Pattern-piece coordinates
* UV mappings for imported 3D garments
* Masks defining valid decoration boundaries

Changing the artwork updates the 3D preview immediately.

Moving or resizing the artwork on the 3D garment should update its position in the associated 2D editor.

Textile pattern design

The 2D editor should also support fabric design.

A user can create a motif and repeat it across a defined fabric area.

Useful pattern features include straight repeats, half-drop repeats, mirrored repeats, seamless tiling, scale controls, and colorway management.

Patterns can be previewed across fabric yardage or mapped onto finished garments.

The user should be able to specify the intended fabric width and output dimensions.

An engineered print should be positionable relative to garment pattern pieces so that motifs can align across seams or appear at deliberate locations.

Fabric artwork should remain editable independently of the product on which it is displayed.

## 8. Printing and Surface Decoration

Printing should be implemented as a family of manufacturing capabilities that share Form’s artwork engine.

The design experience remains consistent while each process introduces its own constraints and production settings.

### 8.1 Direct-to-garment printing

Form supports artwork placed directly onto finished garments.

The process definition can include:

* Printable area
* Platen dimensions
* Garment color and composition
* Image resolution at physical size
* Color profile
* White underbase requirements
* Pretreatment requirements
* Print position and registration
* Applicable printer configuration

Users can preview the finished artwork on the garment and generate appropriately sized print files.

Direct printer communication may be added for equipment with compatible software interfaces. Otherwise, Form should export files or initiate a manufacturer-software handoff.

### 8.2 Direct-to-film printing

DTF workflows involve printing artwork onto transfer film and subsequently applying it to garments.

Form should distinguish the transfer itself from its placement on the finished garment.

The system can support transfer sheets containing multiple designs, artwork nesting, white underbase preparation, and pressing instructions.

A single transfer design may be reused across multiple garments.

### 8.3 Screen printing

Screen printing introduces process-specific constraints around colors, separations, registration, and production setup.

Form should support:

* Spot-color artwork
* Color separation previews
* Individual screen outputs
* Registration marks
* Print placement specifications
* Screen count estimates
* Ink and substrate selections

The production summary can identify the number of screens and colors required.

An initial version can concentrate on spot-color graphics and basic separations rather than advanced halftone processing.

### 8.4 Sublimation and all-over fabric printing

Form should allow artwork to cover entire fabric surfaces or pre-cut panels.

The user specifies fabric dimensions, printer or service requirements, and the print layout.

For constructed objects, the artwork can be associated with the flat pattern pieces before assembly.

The 3D representation should display the assembled result.

### 8.5 Heat-transfer vinyl

Vinyl graphics are fundamentally vector cutting operations.

Form can reuse capabilities developed for plotters, Cricut-style machines, and laser or knife cutting.

It should support cut contours, mirrored output, material layering, weeding considerations, and pressing instructions.

The studio profile specifies the equipment and materials available.

### 8.6 Additional surface treatments

The architecture should also support future decoration techniques such as foil transfers, fabric painting, discharge printing, flocking, textile engraving, and other specialty finishes.

Each treatment becomes a process definition attached to artwork or a physical region.

The system should not require a separate product format for every manufacturing method.

## 9. Embroidery

Embroidery is a particularly strong candidate for deep integration because it transforms ordinary 2D artwork into a structured physical process.

Form should include a dedicated embroidery workspace.

A user selects artwork, specifies embroidery as the manufacturing method, and the system generates an initial stitch plan.

The stitch plan becomes editable.

Embroidery editor capabilities

* Running stitches
* Satin stitches
* Fill stitches
* Stitch paths and direction
* Stitch length and spacing
* Density controls
* Underlay
* Pull compensation
* Thread color assignments
* Stitch ordering
* Jump and trim handling
* Hoop placement
* Stabilizer recommendations
* Stitch-count estimates
* Production simulation

The editor should provide both a conventional 2D stitch view and a realistic material preview.

Changing the stitch angle or density updates the visualization.

At higher zoom levels, individual stitches should be visible.

The stitch geometry can also be used to create a more realistic embroidery appearance on the 3D garment.

Digitization

The agent should be able to propose an initial stitch strategy based on the supplied artwork, fabric type, and intended physical dimensions.

The underlying stitch generation should be performed by a deterministic embroidery engine.

Existing projects such as Ink/Stitch provide a possible technical foundation for digitization and machine-format generation, subject to integration and licensing review.

The application should distinguish an automatically generated stitch program from one that has been verified through physical testing.

Machine output

Form should support commonly used embroidery formats, including DST, PES, and JEF, where implemented through a compatible embroidery engine.

Machine-specific profiles determine available hoop sizes, format support, and other limits.

The architecture should accommodate direct machine control when supported, as well as export and handoff workflows.

## 10. Patches, Labels, and Applied Components

Patches should be modeled as independent manufactured objects.

An embroidered patch might contain:

* Base fabric
* Shape and dimensions
* Embroidered artwork
* Stitch definitions
* Border treatment
* Backing
* Adhesive or attachment requirements
* Material and thread specifications

The patch can exist independently on the Table or be attached to another product.

A single patch design can be reused across a jacket, hat, bag, or other garment.

Different constructions should be supported over time, including embroidered patches, woven patches, printed patches, leather patches, and appliqués.

The underlying component can generate its own manufacturing files and assembly instructions.

Form should similarly support woven labels, printed care labels, hang tags, and other small textile components.

These objects can participate in a larger garment assembly while retaining independent definitions and production outputs.

## 11. Embellishment and Mixed-Media Textiles

Form should eventually support decorative operations beyond printing and embroidery.

This is particularly important for custom apparel, costume design, fashion accessories, and highly embellished pieces.

Possible techniques include:

* Appliqué
* Beading
* Sequins
* Rhinestones and crystals
* Studs and rivets
* Lace overlays
* Decorative stitching
* Fabric layering
* Trims and ribbons
* Custom hardware
* Hand-painted treatments

Each embellishment should be represented as a physical object, repeated element, or surface operation.

For example, a rhinestone design might consist of hundreds of positioned stones with specified sizes, colors, and attachment methods.

Form could render the finished arrangement, calculate component quantities, and generate a placement guide.

For appliqué, the system might derive cut shapes, stitch boundaries, and assembly instructions from the underlying artwork.

For hand embellishment, the production output may be a detailed placement map rather than an automated machine file.

These capabilities extend Form’s concept of manufacturing beyond machines to include manual craft processes.

## 12. Textile Construction and Pattern Drafting

The next major capability is designing objects assembled from fabric.

This requires a dedicated pattern and construction system.

Like a packaging dieline, a sewing pattern describes how flat material becomes a three-dimensional object.

However, textile patterns introduce additional requirements involving flexibility, seam construction, stretch, grain, and fit.

Pattern pieces

Each piece is a dimensionally accurate 2D shape with defined properties.

These include:

* Cut outline
* Stitch line
* Seam allowance
* Grain direction
* Fabric assignment
* Cut quantity
* Orientation and symmetry
* Notches and alignment points
* Fold lines
* Darts and pleats
* Labels and annotations

Pattern pieces remain linked to the assembled product.

Sewing relationships

Form needs to understand which edges join and how.

A seam definition might identify two pattern edges, their stitch type, seam allowance, required alignment, and assembly order.

Additional construction operations include hems, binding, gathering, pleating, folding, attaching closures, and adding linings.

This becomes a reusable construction vocabulary for soft goods.

Parametric patterns

Patterns should be generated from meaningful editable parameters.

A tote bag might have width, height, depth, strap length, strap width, seam allowance, and pocket dimensions.

Changing one parameter adjusts the relevant pieces and regenerates the assembled representation.

The agent can author initial patterns using supported geometric operations and construction rules.

The user receives a tailored native control surface rather than being required to manipulate every line manually.

Pattern editing

A dedicated 2D pattern editor should support drawing and manipulating pattern geometry, adding construction features, viewing connected pieces, and checking relationships.

The user should also be able to work directly with numerical measurements.

Fabric cutting layouts

Form can organize pattern pieces within the usable width of a fabric roll.

This process should consider grain direction, rotation restrictions, repeats, pattern matching, and material utilization.

Outputs may include large-format printable patterns, tiled home-printer patterns, plotter files, cutting-machine files, and material consumption estimates.

## 13. Garment Design, Sizing, and Fit

Garment construction builds on the pattern system but introduces a more complicated relationship between fabric geometry and the human body.

The long-term objective is to allow a user to design a garment in 3D while retaining editable patterns that can actually be cut and sewn.

Garment blocks

Form should provide reusable starting constructions for common garment types.

Examples include a basic T-shirt, tank top, shirt, jacket, pants, shorts, and simple fitted garments.

The blocks are parametric and can be modified through measurements, silhouettes, and construction options.

An agent can select and customize a block or develop a new construction using the available pattern operations.

Size systems

A garment might need to exist in several sizes.

Form should support size charts, graded measurements, size-specific pattern pieces, and rules for propagating design changes across sizes.

It should be possible to preview multiple sizes without treating each as a completely separate design project.

Fit and body representation

A future fitting system can use adjustable body forms or avatars with configurable measurements.

The designer can compare garment dimensions to the body and inspect a simulated fit.

Fit-related information should include ease, stretch, garment tension, and potential areas of interference.

Cloth simulation

Realistic garment behavior requires simulation of flexible materials.

Form should eventually support cloth drape, gravity, collision, and fabric properties such as stiffness and stretch.

For the initial product, pre-modeled garments and lightweight visual approximations can support convincing presentation.

Accurate fitting and predictive drape are a later engineering investment.

The cloth simulation engine should remain modular so it can evolve independently of Form’s rendering and product-document systems.

Construction-aware design

The ultimate interaction is editing a garment in one representation and seeing the others update.

Changing a jacket’s body length should update its relevant pattern pieces.

Adjusting a sleeve pattern should affect the assembled visualization.

Moving artwork on the assembled garment should update the position on the underlying fabric pieces.

This synchronized relationship between patterns, garment construction, and surface artwork is one of the most important long-term capabilities.

## 14. Materials and the Studio Library

Form should have a persistent textile material library that operates across every project.

A material definition might include:

| Property | Examples |
| --- | --- |
| Identification | Manufacturer, name, SKU |
| Composition | Cotton, polyester, nylon, silk, blends |
| Structure | Woven, knit, nonwoven |
| Physical dimensions | Width, thickness |
| Weight | GSM or ounces per square yard |
| Appearance | Color, texture, sheen, weave |
| Behavior | Stretch, recovery, stiffness, drape |
| Production properties | Shrinkage, compatible processes, care requirements |
| Commercial information | Supplier, price, minimum order quantity |
| Studio inventory | Quantity owned, location, availability |

Not every property must be known.

The application can maintain reasonable placeholders while identifying information needed for particular manufacturing operations.

Materials may begin as generic types and later be replaced by exact supplier products.

Shared appearance and physical identity

The material selected for a product should influence both its render and its manufacturing information.

A heavyweight canvas and lightweight silk should look different and, where simulation is available, behave differently.

Thread, ink, adhesive, trim, and hardware should also use reusable library definitions.

Studio inventory

Users should be able to record the materials they actually own.

Examples include fabric yardage, thread colors, stabilizers, blank garments, zippers, elastic, transfer film, and rhinestones.

The application can distinguish between materials that are conceptually available and materials currently in the studio.

This gives the agent useful context when suggesting how to make something.

## 15. Equipment and Manufacturing Workflows

Form’s Studio settings should include the machines and production methods available to the user.

Initial equipment categories include:

* Embroidery machines
* Fabric printers
* DTG and DTF printers
* Vinyl cutters
* Heat presses
* Fabric cutting machines
* Sewing and overlock machines
* Large-format printers and plotters
* Laser cutters suitable for supported textile materials

Each equipment profile describes relevant capabilities and limitations.

For example, an embroidery machine profile might contain supported hoop sizes, needle count, format compatibility, and available communication methods.

A fabric printer might contain usable print width, supported substrates, ink system, color profile, and output workflow.

The Make workspace

Selecting a product and choosing Make opens a production-oriented view.

The user chooses the intended manufacturing operation or reviews the sequence of operations already attached to the product.

Form then assembles the appropriate production information.

For an embroidered jacket, this might include the embroidery design, garment placement, thread sequence, stabilizer specification, and machine file.

For a custom tote bag, it might include fabric printing files, cut patterns, material quantities, and sewing instructions.

Direct machine communication

Form should support three levels of equipment integration.

Export: Generate appropriate production files for another application or machine.

Handoff: Open or transfer a prepared job to a manufacturer’s software.

Direct control: Submit jobs, monitor status, and potentially adjust supported settings through a device interface.

The available functionality depends on the machine and manufacturer.

Direct control should be implemented for supported devices rather than assumed to be universally available.

Production monitoring

Where machine communication permits it, Form should display queued jobs, current activity, progress, and completion state.

For workflows involving manual operations, users can mark production steps complete and attach notes.

The project should retain a record of what was made, using which materials, settings, and design version.

## 16. AI as the Creative and Technical Collaborator

The agent remains a central part of the Form experience.

Its purpose is not simply to generate pictures or meshes. It helps establish complete, editable product definitions.

Starting a project

A user might say:

“I want a collection of heavyweight T-shirts with botanical drawings, embroidered caps, and matching canvas bags. I’d like two colorways, and everything should feel like natural, unbleached fabric.”

The agent creates the initial product collection, proposes materials, selects appropriate product templates, and presents the results on the Table.

Generating editable controls

Each product receives a control surface derived from its construction.

For a T-shirt, these may include blank selection, size, color, decoration methods, and print placement.

For a constructed bag, controls may include dimensions, fabric, handles, seams, pockets, and closures.

For a pattern, controls may include repeat type, spacing, scale, and colorway.

The user can manipulate these properties without returning to the agent.

Manufacturing knowledge

The agent should understand common production methods, relevant constraints, material compatibility, and required outputs.

It can suggest that a small detailed illustration is unsuitable for a particular embroidery process, or that a requested fabric and print method may be incompatible.

It should identify which specifications are known, assumed, or unresolved.

Persistent collaboration

Each project maintains a continuing agent conversation, preserving the context established during creation and subsequent development.

The user can return weeks later and continue working with the same collaborator and project context.

The agent can research materials, find references, propose alternatives, construct new objects, create iterations, and prepare production documents.

Design decisions and open questions

Form should maintain a living record of the project’s goals, constraints, and unresolved information.

For example:

* The garments should feel substantial rather than lightweight.
* The primary graphic must work on both a shirt and a patch.
* The collection should use no more than five thread colors.
* The jacket blank has not yet been selected.
* The bag’s final fabric weight needs confirmation.

These records are editable and tied to relevant products or components.

They provide persistent context for the agent and the application’s validation systems.

## 17. Iterations, Variants, and Collections

Textile design naturally involves numerous related versions of an object.

Form should distinguish between iterations and variants.

Iterations represent the evolution of a design.

A jacket might progress from an initial concept through several changes to its artwork, placement, and construction.

Variants represent alternate configurations of a design.

A single T-shirt might exist in black, natural, and red, with several print colors and sizes.

These configurations share common definitions while preserving their differences.

Collection management

A project should support grouping products into collections or assortments.

A collection might contain several product families, each with multiple colorways and sizes.

The user can view the collection spatially on the Table or switch to a structured assortment view.

The assortment view can show product names, variants, materials, production processes, estimated costs, and status.

The Table remains the creative environment, while structured views make larger collections easier to organize and prepare.

Variant generation

An agent request such as “Show this entire collection in black with silver embroidery” should create appropriate variations across the selected products.

These variations should reuse underlying artwork, geometry, and construction wherever practical.

## 18. Rendering and Presentation

Textile rendering should be a major strength of Form.

The Rendering Studio needs to represent materials and decoration methods convincingly.

Important visual properties include:

* Fabric weave and knit structure
* Thickness and edge behavior
* Surface roughness and sheen
* Folds, wrinkles, and drape
* Printed ink appearance
* Raised embroidery threads
* Patch thickness and borders
* Stitching and seams
* Leather, elastic, trims, and hardware
* Metallic thread, sequins, and reflective embellishments

The initial rendering system can prioritize attractive, believable materials and controlled studio compositions.

Later improvements can introduce more physically accurate textile simulation.

Rendering collections

The user should be able to create a presentation of multiple products together.

A merchandise collection might be arranged across the Table for a single overhead render, or displayed as individual product photographs using consistent lighting.

The system should support saved cameras, lighting presets, backgrounds, and export dimensions.

Variants can be rendered as product grids or comparison images.

Presentation outputs

Form should support:

* Individual product renders
* Detail images
* Collection compositions
* Colorway comparisons
* Simple product specification sheets
* Line sheets
* Process and construction diagrams

Rendered imagery should remain associated with the specific design version from which it was generated.

## 19. Production Documents, BOMs, and Costing

Form should be able to derive useful production information from the product model.

For a decorated blank garment, this includes the blank SKU, colors, sizes, decoration dimensions, materials, print or stitch files, and placement instructions.

For a constructed textile product, the outputs can additionally include pattern pieces, cutting layouts, seam definitions, trims, hardware, and assembly instructions.

Bill of materials

A BOM should identify components and materials, including their quantities and relevant supplier information.

Material consumption may be calculated from known dimensions and pattern layouts.

Embroidery thread use, ink consumption, and production time may initially be estimates.

Estimates should be distinguished from actual machine measurements or supplier quotations.

Costing

Eventually, Form can calculate indicative unit costs from materials, fabrication operations, quantities, waste, and labor assumptions.

This can help a designer compare production approaches.

For example, Form might compare the approximate implications of using a woven label, printed patch, or embroidered patch.

Actual quotes and manufacturing commitments remain distinct from estimates.

Technical packs

More sophisticated products should support automatically generated technical documentation.

A garment tech pack might contain flat drawings, measurements, size charts, materials, colorways, construction details, artwork placements, and production notes.

Because this information comes from the connected product model, updates should propagate wherever possible.

## 20. Technical Architecture

The textile capability should extend Form’s existing native macOS architecture.

It should not require a separate application or an unrelated document system.

Core systems

Application and interface: SwiftUI and AppKit for native controls, inspectors, dialogs, and editors.

3D workspace: The existing Metal-based rendering environment, with a modular scene graph and independent object assets.

2D graphics: The existing vector and typography engine, expanded with textile-specific tools.

Pattern geometry: A dedicated 2D geometric system for drafting, constraints, seam allowances, grading, and cutting layouts.

Construction graph: Structured relationships between pattern pieces, seams, components, and assembly operations.

Embroidery engine: A dedicated stitch-generation and export subsystem, potentially leveraging an existing open-source engine.

Cloth simulation: An independent subsystem introduced when realistic drape and fit become necessary.

Materials: A shared library containing visual properties, physical specifications, and inventory references.

Manufacturing: Extensible process modules responsible for preparing, validating, and exporting appropriate production outputs.

Agent integration: Structured operations for creating objects, modifying parameters, invoking specialist engines, and inspecting results.

Modularity

A garment should not be stored as one monolithic mesh containing all artwork, construction, and production information.

Its geometry, materials, patterns, artwork, decorations, and manufacturing definitions should remain independently addressable.

Changes to one component should update only the dependent resources.

This supports progressive scene loading and allows large merchandise collections to remain responsive.

Shared manufacturing abstraction

Printing, embroidery, cutting, and sewing have different technical requirements, but they can share a common concept of a manufacturing operation.

An operation has:

1. An input object or surface.
2. A selected manufacturing method.
3. Applicable materials.
4. Machine or process settings.
5. Constraints and validation.
6. Generated production outputs.
7. Optional equipment communication and job status.

Individual process modules implement their specialized behavior.

This architecture can eventually support new production methods without requiring changes to the central product representation.

Extensibility

Form should expose its operations through an internal API that also supports external agent access via MCP.

Textile-specific functions might include creating patterns, applying embroidery, changing materials, generating cut layouts, preparing print artwork, and building production packets.

The same capabilities should be accessible through direct UI interaction or agent operations.

## 21. Development Roadmap

The full textile vision should be implemented as progressive extensions of Form’s existing capabilities.

### Phase 1: Merchandise and Existing Blanks

Objective: Design and present an entire merchandise collection.

Build the fundamental experience around existing garments and accessories.

Required features:

* Import and placement of garment models
* Initial library of T-shirts, hats, jackets, and bags
* Physical dimensions and decoration regions
* Live linked 2D artwork editing
* Fabric and garment material presets
* Colorways and variants
* Placement and scale controls
* Product and collection rendering
* Print-ready artwork exports
* Basic product specifications

Result: A user can develop a credible merchandise collection containing multiple decorated products, generate presentation imagery, and prepare artwork for production.

This should be the first textile-focused vertical slice.

### Phase 2: Decoration and Fabrication

Objective: Turn graphic designs into machine-specific manufacturing outputs.

Introduce a deeper set of decorative processes.

Required features:

* Manufacturing method selection
* Embroidery digitization and stitch editing
* Embroidery machine file exports
* Patch definitions and manufacturing
* DTG and DTF preparation
* Basic screen-print separations
* Heat-transfer vinyl cut files
* Thread, ink, and transfer materials
* Equipment profiles and compatibility validation
* Initial production job management

Result: A user can develop decorated products and prepare actual machine-compatible files, with direct device workflows for selected supported equipment.

### Phase 3: Fabric Design and Soft-Goods Construction

Objective: Design and physically construct new objects from fabric.

Required features:

* Fabric print and repeat editor
* Parametric 2D pattern pieces
* Seams, hems, folds, and allowances
* Pattern-to-assembly relationships
* Cutting layouts and material estimates
* Fabric assignment
* Basic assembled 3D representation
* Pattern and cutting exports
* Construction instructions
* Reusable soft-goods templates

Initial products should emphasize bags, pouches, covers, and other objects with manageable construction.

Result: A designer can create a new fabric product, edit its construction, preview the result, and generate the patterns and documents required to make it.

### Phase 4: Garment Construction

Objective: Support original apparel design beyond decorating existing blanks.

Required features:

* Parametric garment blocks
* Garment-specific pattern editing
* Body measurements and size charts
* Size grading
* Construction editing
* Cloth simulation
* Avatar-based fitting
* Fabric behavior models
* Pattern-aware artwork placement
* Advanced garment technical packs

Result: A user can develop an original garment from editable pattern geometry, preview its assembled behavior, and prepare it for prototype construction.

### Phase 5: Integrated Textile Production Studio

Objective: Connect design, prototyping, and manufacturing into a continuous workflow.

Potential features:

* Expanded direct machine communication
* Production scheduling and job queues
* Material inventory integration
* More sophisticated costing
* Supplier and blank-product catalogs
* Factory-ready technical documentation
* Sample and quality-control tracking
* Production history linked to design iterations
* Shared studio resources
* Third-party fabrication extensions

Result: Form operates as a persistent creative and production environment for an independent textile studio or small apparel brand.

## 22. Initial Product Demonstration

The strongest demonstration of the textile capability would be a small merchandise collection containing products that exercise several production methods.

Demonstration project: A five-piece collection

### Product 1: Graphic T-shirt

An existing heavyweight blank with editable artwork, multiple colorways, realistic fabric rendering, and production-ready graphic files.

### Product 2: Embroidered cap

An existing blank with an embroidered emblem, editable stitch properties, machine-specific hoop constraints, and embroidery export.

### Product 3: Work jacket

A blank jacket with embroidery, a large printed back graphic, a patch, and additional material or trim variations.

### Product 4: Embroidered patch

A standalone manufactured object with selectable backing, border treatment, thread colors, and production instructions.

### Product 5: Custom canvas tote

An originally constructed product using parametric pattern pieces, printable fabric panels, seams, handles, and cutting patterns.

The entire collection should remain visible on one Table.

Each object should retain independent geometry and construction.

Artwork should be reusable between products and manufacturing methods.

The designer should be able to create iterations and variants, compare them spatially, generate attractive presentation assets, and prepare files appropriate to each production method.

This demonstration would establish the relationship between Form’s fundamental creative environment and its new textile-specific capabilities.

## 23. Product Principles

Design the object, not the file

The user starts with a physical product or desired outcome. Software representations and manufacturing formats are supporting infrastructure.

One environment, specialized tools

Form should provide focused editing experiences for artwork, embroidery, pattern drafting, materials, and manufacturing without requiring these tools to become one oversized universal editor.

Physical scale is fundamental

Dimensions, fabric widths, stitch sizes, seam allowances, printing areas, and material quantities should be expressed in real-world measurements.

Construction information is valuable

An object should retain knowledge of how it is made. Pattern pieces, seams, stitches, materials, and manufacturing processes should be represented explicitly.

Creative exploration remains central

The software should support experimentation, not just preparation for manufacturing.

Iterations, variants, references, swatches, and incomplete ideas belong together in the creative workspace.

AI provides expertise and reduces setup

The agent should help create initial product definitions, propose parameters, select construction methods, identify uncertainties, and operate specialized tools.

The actual editing experience should remain direct and responsive.

Materials are more than textures

Fabric and other materials should have recognizable physical properties, production constraints, and commercial identities.

Manufacturing capabilities are modular

Each process should have its own reliable implementation while participating in the shared product architecture.

Accuracy should be explicit

The application should distinguish visually plausible representations, approximate measurements, manufacturer specifications, simulated results, and physically verified production settings.

Support independent creators

The experience should work for someone with one sewing machine and a small inventory of materials, not only for established manufacturing businesses.

## 24. Long-Term Vision

The larger opportunity is to make textile creation feel as fluid as working with images, typography, or video.

A designer might begin with a photograph, turn part of it into a repeating textile pattern, apply that pattern to a garment, develop a coordinated embroidered graphic, alter the garment’s construction, and generate the files necessary to produce the finished object.

The process would not require the designer to manage separate software environments for each stage.

They would move between representations of the same physical product.

The 3D object communicates form, scale, material, and assembly.

The 2D editors provide precision for artwork and patterns.

The specialized manufacturing engines transform design intent into production instructions.

The Studio Library understands the user’s materials and available equipment.

The agent provides knowledge, research, technical assistance, and continuity across the entire creative process.

And the Table allows all of this work to remain visible, spatial, and open to experimentation.

Textiles are especially well suited to Form because they sit at the intersection of two-dimensional design, three-dimensional construction, physical materials, and digital manufacturing.

The capability can begin with the familiar act of placing artwork on a T-shirt and gradually extend into designing entirely new garments and fabric-based objects.

Ultimately, Form should make it possible for someone to imagine a physical textile product, develop it through multiple creative iterations, understand how it can be constructed, and produce the information needed to make it.

The ambition is not simply to create better clothing mockups or another fashion CAD application. It is to make designing, developing, and manufacturing textile products one continuous creative activity.
