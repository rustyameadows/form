# FORM

## 2D Design, Typography & Vector Editing

Product Vision & Feature Specification

Native macOS Design Environment | October 2026

---

## 1. Overview

Form needs a genuinely excellent 2D design environment.

While the application’s larger ambition is to become a unified creative environment for physical products, much of the actual design work will happen in two dimensions.

Typography, illustration, packaging artwork, printed graphics, labels, watch dials, textile patterns, embroidery artwork, instruction booklets, and other product elements all require precise 2D editing.

These activities should feel as capable, polished, and responsive as working in an established professional design application.

The goal is to build a focused, professional-quality vector and typography editor into Form, with an interaction model comparable to Figma, but oriented toward graphic design and physical products rather than digital interface design.

We want the precision of professional vector software, the fluidity and approachability of Figma, and deep integration with Form’s physical design environment.

The 2D editor should be useful as a standalone creative tool, even when no 3D object is involved.

A designer should be able to spend hours developing a typographic composition, arranging illustrations, refining vector geometry, or preparing a print layout without feeling that they’re working inside a simplified secondary editor.

It should be entirely possible to create a beautiful poster, label, dial, package design, or printed fabric graphic using Form alone.

The larger product vision depends on this foundation being excellent.

## 2. Product Philosophy

A real creative instrument

The 2D editor should not feel like an annotation layer, template customizer, or graphical utility attached to the 3D environment.

It is one of Form’s primary creative instruments.

The quality of its editing experience should be judged independently of the rest of the application.

A designer familiar with Figma, Illustrator, Affinity Designer, or Pixelmator should immediately recognize the core operations and be able to work with confidence.

We should emphasize the parts of these applications that support excellent composition, typography, illustration, and production artwork.

We do not need Figma’s interactive prototyping, web design systems, responsive web layout, developer handoff, or application-design-specific capabilities.

Our focus is on making beautiful, precisely constructed two-dimensional artwork.

Physical dimensions first

Form fundamentally works in real-world dimensions.

The 2D editor should therefore use inches, millimeters, centimeters, and typographic points as its primary units.

A user designing a 100 mm clock dial should be working on an actual 100 mm circle.

A designer laying out an 11-by-17-inch print should see those dimensions in the document and its rulers.

A 3 mm margin means exactly 3 mm.

Raster images still have pixel dimensions and resolution, but pixels should not define the physical size of the design.

The application must accurately handle conversion between physical dimensions, font points, raster resolutions, and output formats.

Direct manipulation

Almost every routine design operation should happen through direct manipulation rather than conversation.

Text can be selected and edited immediately.

Objects can be moved, resized, rotated, grouped, and aligned.

Colors can be changed through native controls.

Paths can be manipulated through their nodes and handles.

Text spacing can be adjusted numerically or with keyboard shortcuts.

The AI agent can help create or modify artwork, but the designer should never need to ask the agent to perform routine graphical operations.

The software should feel immediate and tactile.

Connected representations

A 2D design may exist independently, or it may belong to a physical object.

The same editor should work in both contexts.

A notebook cover, clock dial, package panel, embroidered emblem, and standalone printed poster should all use the same underlying artwork system.

When artwork is attached to a 3D object, edits should appear in the 3D representation in real time.

This connection is a major differentiator, but it should not introduce unnecessary complexity into the 2D editing experience.

## 3. The Editing Experience

The 2D editor should have a familiar, efficient professional layout.

Main canvas

The primary area is a zoomable 2D workspace.

It supports pan, zoom, selection, guides, rulers, snapping, and direct object manipulation.

Zooming should be smooth, including trackpad pinch gestures and conventional keyboard shortcuts.

Artwork must remain sharp at every zoom level.

The system should support both a document-bound view and an open canvas containing multiple related designs.

For example, a designer could lay out six alternate clock faces beside one another, or work on several package panels within the same editing surface.

Tools

A compact toolbar provides access to common operations:

* Select and direct-select
* Text
* Rectangle, ellipse, and other basic shapes
* Pen and Bézier curves
* Line and polygon tools
* Image placement
* Pan and zoom
* Eyedropper
* Frame or artboard creation

Frequently used operations should have conventional keyboard shortcuts.

Layers and objects

A layers panel exposes the document structure.

Users can select, rename, reorder, hide, lock, group, and organize objects.

The hierarchy should support groups, nested groups, clipping masks, and reusable components.

Contextual inspector

A property inspector changes according to the selected object.

Selecting text reveals typography controls.

Selecting a path reveals fill, stroke, geometry, and node-related options.

Selecting multiple objects reveals alignment and distribution operations.

Selecting a linked product face can reveal its physical dimensions and relevant production constraints.

The inspector should prioritize frequently used controls while providing access to detailed settings.

Advanced properties should be available without making the everyday interface unnecessarily complicated.

## 4. Typography: A First-Class Design System

Typography should be one of the strongest features of Form.

This is particularly important because physical products often involve unusually precise typographic work.

Clock dials, gauges, packaging, labels, printed goods, stationery, books, and apparel graphics all depend on nuanced control over type.

The user should be able to work at a level approaching a dedicated professional typography tool.

### 4.1 Native macOS font support

Form should use the fonts installed and available on the user’s Mac.

This includes:

* macOS system fonts
* User-installed fonts
* Fonts managed through Font Book
* Standard OpenType and TrueType fonts
* Variable fonts
* Supported font collections and font families

Users should not need to import fonts separately into Form when those fonts are already installed and available to macOS.

The font picker should present available families and their supported styles.

A useful font browser would support searching, previewing, favorites, and recently used fonts.

It should show actual typeface previews rather than rendering every font name in the same generic typeface.

Font metadata and availability

The application should preserve font family, face, style, and applicable variation settings in the document.

When opening a project that references an unavailable font, Form should identify the missing face and provide replacement options.

Font substitutions should be visible and should not silently modify the original font assignment in the document.

Project portability requires predictable behavior when fonts are missing or unavailable.

We should also respect font embedding, distribution, and conversion licensing restrictions.

### 4.2 Core text properties

Text objects need full control over their basic typographic properties.

| Property | Required behavior |
| --- | --- |
| Font family | Choose from installed fonts |
| Font style | Select available weights and faces |
| Font size | Exact sizing in typographic points |
| Leading | Automatic or explicit line spacing |
| Tracking | Adjustable overall character spacing |
| Kerning | Font kerning and manual pair adjustments |
| Word spacing | Adjustable word spacing |
| Baseline shift | Move selected text vertically |
| Horizontal scale | Adjust character width where supported |
| Alignment | Left, center, right, justified |
| Vertical alignment | Top, middle, bottom within text frame |
| Paragraph spacing | Before and after paragraph |
| Indentation | Left, right, and first-line controls |
| Text direction | Appropriate support for writing direction |
| Case | Uppercase, lowercase, and other case treatments |
| Decoration | Underline and strikethrough |
| Color | Fill and opacity |
| Rotation | Rotate entire text objects |
| Position | Exact physical coordinates |

Controls should be expressed in sensible typographic units and preserve precision.

Users should be able to type exact values, increment them with arrow keys, and adjust settings interactively.

Multi-selection should allow shared typographic changes across multiple text objects.

### 4.3 Fine-grained character editing

Form should distinguish between properties applied to an entire text object and properties applied to selected characters.

A user should be able to highlight individual characters, words, or ranges and change their styling without creating separate objects.

For example, a designer could create a typographic composition using one text object with multiple sizes, weights, colors, and baseline adjustments.

The application should support mixed formatting within text frames.

Specific capabilities include:

* Per-character font and style changes
* Character-level tracking and baseline adjustments
* Individual character color
* Superscript and subscript
* Small caps where supported
* Manual kerning between selected glyphs
* Character-level OpenType feature settings

We should preserve rich text structure in the underlying document rather than splitting every differently styled character into an independent graphic object.

### 4.4 Ligatures and OpenType features

Professional OpenType support is a priority.

Users should be able to access typographic features provided by the selected font.

These may include:

* Standard ligatures
* Discretionary ligatures
* Historical ligatures
* Contextual alternates
* Stylistic alternates
* Stylistic sets
* Small capitals
* Oldstyle figures
* Lining figures
* Tabular figures
* Proportional figures
* Fractions
* Ordinals
* Slashed zero
* Swashes
* Localized forms

Available controls depend on what the font actually supports.

The application should display relevant options rather than suggesting that every typeface supports every feature.

Ligatures and complex character substitutions must be handled through proper font shaping rather than by independently rendering Unicode characters.

Alternate glyph selection

A particularly valuable interaction would be selecting a character and viewing the alternate glyphs available for that character in the current font.

A small contextual palette could show alternate forms.

The user chooses an alternate and sees it applied immediately.

This is especially useful for logos, decorative typography, packaging, and display type.

Eventually, a complete glyph browser could expose the characters and available glyph forms within a selected font.

### 4.5 Variable fonts

Variable typography should be treated as a native capability.

When a font exposes variation axes, Form should allow adjustment of those axes through the property inspector.

Common axes include:

* Weight
* Width
* Optical size
* Slant
* Italic variation
* Font-specific custom axes

The interface should display the actual supported axes and their valid ranges.

Adjustments should update the text immediately.

Where a font supports optical sizing, Form should expose that behavior and allow the user to control automatic versus explicit optical-size settings.

Variable axis values should be retained in the project and represented correctly in rendering and exports.

### 4.6 Text frames and composition

The application should support two primary types of text objects.

Point text: Clicking on the canvas creates a text object that grows as the user types. This is ideal for logos, short labels, dial numerals, and display typography.

Area text: Dragging a rectangle creates a defined text frame. Text wraps within the available width, and the user can adjust the frame independently of font sizing.

The user should be able to switch between appropriate text behaviors.

Text frames need reliable line breaking, alignment, clipping, overflow indicators, and layout updates.

Changing a text frame’s width should reflow its content rather than automatically stretching the glyphs.

Scaling the entire text object should be a distinct operation from resizing its text frame.

This distinction is important for predictable professional editing.

### 4.7 Paragraph and longer-form typography

Although Form is not intended to become a general-purpose word processor, many physical products require more than a few words.

Examples include instruction booklets, printed inserts, product descriptions, labels, and packaging copy.

Form should support styled paragraphs within text frames.

Important capabilities include paragraph alignment, indentation, line spacing, tabs, lists when useful, and hyphenation.

Text styles should be reusable within a document.

A designer might create styles for a heading, subheading, body copy, and caption, then update the formatting consistently.

Eventually, linked text frames should allow text to flow across columns or pages.

This makes it possible to design a small instruction booklet or publication without requiring an entirely separate editorial system.

We do not need full book-publishing capabilities in the first implementation, but the text engine should be designed to accommodate them.

## 5. Converting Typography to Vector Outlines

Convert to Outlines should be an important and reliable feature.

The user selects a text object and converts its rendered glyphs into editable vector geometry.

This is useful for logo construction, decorative lettering, cutting operations, engraving, and manufacturing workflows that require paths.

The conversion must preserve the visible appearance of the text, including:

* Glyph selection
* Ligatures
* Font variations
* Kerning and tracking
* Character positioning
* Text transforms
* Baseline adjustments
* Relevant OpenType substitutions

Once converted, the resulting glyphs are represented as vector paths.

The user can manipulate individual glyph outlines, combine them, alter their control points, or use them in boolean operations.

Conversion behavior

Form should provide an option to preserve the original editable text as a hidden or linked source object.

This allows the user to return to the original typography if needed.

The actual converted outlines should remain ordinary editable vector geometry without a requirement to retain a live font dependency.

For example, a designer might convert a wordmark to outlines, adjust one letter’s shape, and then unite several glyphs into a custom logo.

The resulting artwork should be usable across Form’s printing, laser cutting, vinyl cutting, engraving, and other vector-based manufacturing systems.

## 6. Vector Drawing and Editing

Vector graphics should be the second major pillar of the 2D environment.

The application should provide the core operations necessary for precise illustration, geometric construction, logos, diagrams, and production artwork.

### 6.1 Basic shapes

Initial shapes should include rectangles, rounded rectangles, ellipses, circles, lines, polygons, and stars.

Shape-specific parameters should remain editable where possible.

Examples include corner radius, polygon side count, and star point configuration.

Shapes should support exact numerical dimensions, rotation, and positioning.

### 6.2 Bézier paths

Form needs a capable path editor.

Users should be able to draw open and closed paths, create straight or curved segments, and manipulate control points.

Required operations include:

* Add and delete anchor points
* Convert between corner and smooth points
* Adjust Bézier handles
* Open and close paths
* Join and split paths
* Reverse path direction
* Edit multiple selected nodes
* Transform nodes numerically or interactively

Node editing should feel precise at high zoom levels.

### 6.3 Boolean operations

The application should support familiar vector boolean operations:

* Union
* Subtract
* Intersect
* Exclude
* Divide, where supported

These should work across compatible vector shapes and paths.

A designer should be able to combine primitives into complex artwork without leaving the editor.

Non-destructive boolean groups are desirable, with an option to flatten the result into ordinary paths.

### 6.4 Fill and stroke

Vector objects need comprehensive appearance controls.

Fill

Support solid colors, opacity, and gradients.

Gradient types should include linear and radial as initial capabilities.

Users should be able to manipulate gradient positions and stops directly on the canvas.

Stroke

Stroke properties should include:

* Width
* Color
* Opacity
* Cap style
* Join style
* Miter limit
* Dashed lines
* Dash and gap configuration
* Stroke alignment where geometrically supported
* Variable-width strokes as a later capability

Strokes should also be convertible into editable vector outlines.

This is useful for manufacturing operations that require explicit boundary geometry.

### 6.5 Compound paths and clipping

Form should support compound paths with holes, clipping masks, and nested artwork.

This is essential for graphics such as letters, stencils, complex illustrations, and printable layouts.

Masks should be editable and should not permanently alter their contents unless explicitly flattened.

### 6.6 Grouping and organization

Users should be able to group objects with a simple keyboard shortcut and manipulate the group as one unit.

Groups should support nested objects and consistent transformations.

Entering a group should allow focused editing without requiring the user to ungroup everything.

Locking, visibility, and layer order should behave predictably.

### 6.7 Reusable components

A designer may use the same emblem, icon, or graphic on several products.

Form should support reusable vector components or symbols.

Editing the source component updates its linked instances.

Instances may have selected properties overridden, such as color or size, without necessarily becoming fully independent.

A designer can also detach an instance to edit it separately.

This capability should work across different 2D documents and, eventually, across objects within the same Form project.

## 7. Precision Layout and Alignment

A major part of making Form feel professional is getting the small layout interactions right.

Users should be able to position objects precisely without fighting the interface.

### 7.1 Transform controls

Every applicable object should expose:

* X and Y position
* Width and height
* Rotation
* Scale
* Aspect-ratio locking
* Transform origin
* Flip horizontally or vertically

Measurements should be expressed in the document’s configured units.

Inputs should accept simple unit conversions where appropriate.

For example, a user working in millimeters should still be able to enter a dimension in inches and have it converted accurately.

### 7.2 Smart guides and snapping

Form should provide contextual alignment assistance similar to Figma.

When moving an object, the system can indicate alignment with nearby edges, centers, guides, or other relevant features.

The user should be able to snap to:

* Document bounds
* Grid lines
* Guides
* Object edges
* Object centers
* Anchor points
* Relevant geometric intersections

Snapping should be configurable and temporarily overridable while dragging.

### 7.3 Alignment and distribution

Multi-selected objects should support:

* Align left, right, top, bottom
* Align horizontal centers
* Align vertical centers
* Distribute horizontally or vertically
* Equalize spacing
* Match width or height
* Arrange at specified intervals

These operations should be accessible through both the inspector and keyboard shortcuts where appropriate.

### 7.4 Rulers, grids, and guides

The canvas should support visible rulers with draggable guides.

Users can create guides numerically and lock or hide them.

Grid options should include a rectangular grid and configurable spacing.

For typography, baseline grids should eventually be supported.

Guides and grids must respect the document’s physical coordinate system.

### 7.5 Keyboard precision

Users should be able to nudge selected objects with arrow keys.

A modifier should provide larger increments.

Nudge increments should be configurable in real-world units.

The editor should also support familiar shortcuts for duplication, grouping, locking, ordering, and direct selection.

Reliable keyboard interaction is a major part of the professional editing experience.

## 8. Color, Swatches, and Appearance

Form’s color system should support both creative exploration and accurate physical output.

### 8.1 Color editing

Users should be able to specify colors through standard interfaces such as RGB, HSB, HEX, and supported print-oriented color representations.

A native macOS color picker can be part of the experience, but Form should provide an inspector optimized for graphic design.

Opacity and gradients should be editable directly.

### 8.2 Reusable swatches

A document can define named colors and reusable swatches.

A merchandise collection might use a shared palette of six colors applied across garments, packaging, and printed artwork.

Changing a shared swatch should update all objects using it.

Swatches can eventually reference physical materials, thread colors, inks, or manufacturer-defined colors.

### 8.3 Print colors

Form should preserve the distinction between screen colors and production colors.

RGB appearance values should not be treated as guaranteed printed results.

As print-oriented capabilities mature, the system should support appropriate ICC color profiles, CMYK workflows, named spot colors, and output-specific color conversion.

The application should identify the active document color space and relevant output profile.

### 8.4 Appearance effects

Useful appearance features include opacity, basic shadows, blur, and blending modes.

These should be non-destructive where practical.

Advanced effects can be introduced gradually.

The initial priority is excellent geometry, typography, and color rather than a large collection of decorative filters.

## 9. Raster Images in the Vector Environment

Form should support raster images as ordinary design objects.

Users can place images from disk or drag them directly onto the canvas.

Supported capabilities should include:

* Placement and scaling
* Rotation and cropping
* Clipping masks
* Opacity
* Basic color and image adjustments
* Image replacement while retaining layout
* Image resolution information
* Effective DPI at physical output size

Raster images should retain links to their original assets within the project structure.

The application should not unnecessarily resample or degrade image data during routine editing.

For print-oriented projects, Form should identify when an image’s effective resolution may be insufficient for its intended dimensions.

Raster image editing can rely on Core Image and related native technologies.

We do not need to reproduce a complete Photoshop-style pixel editing environment inside the vector editor.

## 10. Artboards, Frames, and Documents

The editor should support multiple bounded design regions.

These may be called artboards, frames, or pages depending on context.

A designer might use them to organize several logo directions, alternate labels, clock dials, package panels, or printed pages.

Each frame has exact physical dimensions.

Frames can be duplicated, renamed, rearranged, and exported independently.

Physical document presets

Useful presets include standard paper sizes, common labels, posters, and other physical formats.

The user can always enter custom dimensions.

Frame dimensions should not be restricted to traditional paper sizes.

For example, an artwork surface might represent a 3-inch patch, a 90 mm watch dial, or a 14-by-18-inch T-shirt print.

Multi-page content

The underlying system should eventually support sequential pages, especially for instruction booklets and printed publications.

Multi-page documents can share styles, guides, margins, and reusable elements.

An initial version can use separate frames, with more sophisticated page management added later.

## 11. Linked 2D and 3D Design

This is one of Form’s defining capabilities.

A user should be able to edit artwork in 2D while observing the changes on a physical object in 3D.

Example: Clock dial

The designer selects a clock face on the Table and chooses Edit Dial Artwork.

A 2D editing surface opens, displaying the dial at its exact physical diameter.

The designer adjusts the typeface, changes the numeral spacing, repositions markers, and modifies the colors.

The assembled clock remains visible in an adjacent 3D preview.

Every change appears on the clock immediately.

The user can return to the Table without exporting, saving separate files, or manually refreshing textures.

Example: Printed packaging

A packaging design contains several connected printable panels.

The user can edit one panel or open the complete unfolded dieline.

Artwork appears across the corresponding surfaces of the assembled package.

Cut and score lines are visible as production overlays but are not automatically printed as artwork.

Changing package geometry updates the artwork surface dimensions and identifies placements requiring review.

Example: Embroidered garment

The user opens a flat decoration region on a jacket.

They refine the logo in the vector editor, then preview the corresponding embroidered result on the garment.

The vector artwork remains the source definition, while the embroidery engine derives its stitch instructions.

Implementation principle

The 2D artwork should exist as an independent editable asset.

The 3D system references a rendered representation of that asset and places it on the appropriate product surface.

The application should avoid serializing and reimporting external files every time the user makes a change.

Instead, the editor should update the underlying asset and invalidate only the affected render resources.

This should make live updates practical even while working on complex projects with many objects.

## 12. Manufacturing-Aware Artwork

Because Form is oriented toward physical products, the 2D environment should understand the distinction between design artwork and manufacturing instructions.

The same document might contain several types of geometry:

Printable artwork: Graphics, typography, and imagery intended to appear on the finished object.

Cutting paths: Vector geometry defining where material will be cut.

Score or fold lines: Construction information for packaging or sheet materials.

Stitch paths: Instructions for embroidery or sewing.

Engraving geometry: Artwork or paths intended for engraving equipment.

Guides and annotations: Information useful to the designer but excluded from production output.

These elements should have explicit roles in the document model.

A layer color alone should not determine its manufacturing meaning.

Production overlays

Users should be able to show or hide:

* Bleed
* Trim boundaries
* Safe areas
* Cut and score lines
* Material boundaries
* Registration marks
* Print limitations
* Other process-specific guides

The actual exported content depends on the chosen manufacturing workflow.

A package artwork PDF may exclude construction guides while a cutting file contains them.

The same connected document can produce both outputs.

## 13. Import, Export, and Interoperability

Form should be able to exchange artwork with existing creative software.

Import

Priority formats include:

* SVG
* PNG
* JPEG
* PDF as a placed reference, with deeper editable import added where practical
* Other common raster image formats supported by macOS

SVG import should preserve editable vector geometry, fills, strokes, transforms, groups, and supported text properties whenever possible.

Complex or unsupported SVG features should be handled predictably and reported when they cannot be preserved.

Export

Priority formats include:

* SVG
* PDF
* PNG
* JPEG

Export options should support selected objects, individual frames, and complete documents.

For raster output, users can specify the output dimensions or effective resolution.

For physical print output, the exported file should preserve the intended physical dimensions.

Typography in exports

SVG and PDF export should preserve live text where supported and appropriate.

Users should also have an explicit option to convert typography into outlines for portability or manufacturing workflows.

PDF export should use proper font embedding where supported and permitted.

Converting to outlines should preserve the rendered shape of the typography as closely as possible.

Vector fidelity

The application’s internal representation should preserve more information than any single exchange format requires.

Import and export should translate between the native document model and outside file formats.

We should not use SVG itself as the sole source of truth for every native editing feature.

## 14. Native Mac Implementation

The editor should be implemented with native macOS technologies.

The objective is excellent performance, crisp rendering, reliable text behavior, and a familiar Mac experience.

Application interface

SwiftUI and AppKit should provide the windowing environment, inspector controls, menus, shortcuts, popovers, and native interaction components.

AppKit is particularly relevant for advanced desktop editing behaviors.

Text shaping and layout

Core Text should be a central part of the typography engine.

It provides low-level font and text layout capabilities needed for accurate glyph shaping, positioning, and rendering.

The implementation should preserve font features and handle complex shaping through the underlying text system.

The editor must not treat typography as a sequence of independently positioned characters.

Ligatures, contextual substitutions, kerning, script shaping, and other features require proper text layout.

TextKit 2 and AppKit text input capabilities are also relevant for managing interactive text editing, selection, caret behavior, composition, and input methods.

A practical architecture may use a dedicated text-editing layer for active text input while the canvas renderer owns the final positioned artwork.

Vector geometry

The vector editor should maintain its own structured representation of shapes, paths, transforms, styles, and groups.

Core Graphics can provide high-quality vector drawing and path operations.

Additional geometry algorithms may be necessary for robust boolean operations, offsetting, stroke expansion, and path editing.

The system should support both interactive rendering and exact geometric export.

Canvas rendering

A Metal-backed canvas is an appropriate direction for interactive performance.

The renderer should handle pan, zoom, selections, guides, previews, and large collections of objects smoothly.

Vector content can be tessellated, cached, or rendered through suitable native drawing paths.

Text and geometry caches should be invalidated selectively when their content changes.

We should avoid rerendering an entire complex document unnecessarily because a single text property or vector shape has changed.

Color management

ColorSync and supported macOS color-management facilities should be used where applicable.

The renderer and export system should preserve color-space metadata and perform intentional conversions.

Document persistence

The 2D editor should use Form’s existing modular project package.

Each artwork document contains:

* Object and layer hierarchy
* Vector path data
* Text content and typographic properties
* Font references and variation settings
* Colors and styles
* Placed image references
* Frames and dimensions
* Guides and grids
* Linked physical-object references
* Manufacturing roles and metadata

A document can exist independently or be attached to a larger product.

The model should support non-destructive editing, undo history, and efficient updates.

## 15. Editing Quality and Performance

Professional creative software succeeds or fails on the details of its interaction quality.

Form should prioritize reliability and responsiveness in a relatively small set of core features before expanding the surface area of the editor.

Important expectations include:

Immediate editing: Text entry, dragging, and basic property changes should feel responsive, without agent calls or visible regeneration delays.

Accurate selection: Users must be able to select the intended object, even when paths and text overlap.

Predictable transforms: Resizing a text frame should behave differently from scaling typography. Group transforms should preserve relative positions.

Reliable undo and redo: A user should be able to move through a long sequence of edits without losing document consistency.

High zoom precision: Path nodes and small typographic details must remain editable at high magnification.

Consistent shortcuts: Common Mac and graphic-design shortcuts should behave predictably.

Stable layout: Font loading, text edits, and changes to document state should not cause unexplained shifts.

Good handling of large documents: Dozens or hundreds of vector objects and text elements should not make ordinary operations sluggish.

Automatic persistence: Artwork modifications should be saved within the existing project architecture and survive application restarts.

Keyboard and accessibility support: The editor should support proper text input, keyboard navigation where practical, VoiceOver-accessible controls, and familiar macOS editing conventions.

A smaller editor with excellent behavior is preferable to a large collection of features that are difficult to use reliably.

## 16. AI Integration

The agent should have full access to the 2D editor’s underlying operations.

It should be able to create artwork, add text, modify typography, arrange objects, manipulate vectors, apply styles, and generate variants.

However, routine editing should remain deterministic and direct.

For example:

“Try this label in a condensed serif with much tighter spacing.”

The agent can select a font, create an alternate version, and modify its text properties.

Once the user selects the text, they can refine the result through native font, tracking, kerning, and layout controls.

The agent should be able to inspect the current artwork document, including its dimensions, text objects, layers, styles, and vector geometry.

Structured commands

Agent operations should map to the same underlying commands used by the UI.

Examples include:

* Create text object
* Change font and typographic properties
* Set OpenType features
* Convert text to paths
* Create or modify vector shapes
* Group and ungroup objects
* Align or distribute objects
* Apply color or styles
* Create a new frame
* Duplicate artwork as an iteration
* Link artwork to a physical product surface

These operations should also be exposed through Form’s external automation interface.

Design variants

The agent should be able to create alternate compositions while preserving the original.

A user might request five typographic treatments of the same label, or three colorways for a printed graphic.

The agent can create the alternatives as distinct frames or objects, arranged side by side.

This continues Form’s broader approach to visible iterations and variants.

## 17. Recommended Development Sequence

The 2D editor should be built incrementally, but with a strong emphasis on achieving professional editing quality early.

### Phase 1: A Credible Professional Canvas

Goal: Make fundamental graphic composition feel excellent.

Required capabilities:

* Native Mac canvas
* Smooth pan and zoom
* Artboards with physical dimensions
* Rulers and guides
* Selection and transforms
* Layers and groups
* Basic shapes and paths
* Fill and stroke
* System font discovery
* Text creation and editing
* Font family, size, weight, alignment
* Leading and tracking
* Core snapping and alignment
* Undo and redo
* SVG and PDF export
* PNG export
* Live 2D-to-3D artwork updates

Completion criterion: A designer can produce a precisely laid out, typography-heavy label or clock dial and edit it comfortably without using another design application.

### Phase 2: Deep Typography

Goal: Make Form particularly strong for typographic design.

Add:

* Full OpenType feature controls
* Ligatures and contextual alternatives
* Alternate glyph selection
* Variable font axes
* Manual kerning
* Character-level styling
* Baseline shift
* Small caps and numeral styles
* Advanced text frames
* Paragraph styles
* Convert to Outlines
* Editing of converted glyph paths
* Font fallback and missing-font management

Completion criterion: A designer can create and refine sophisticated display typography, a custom wordmark, or a typographic clock dial with the precision expected from a professional vector editor.

### Phase 3: Mature Vector Editing

Goal: Support detailed illustration and production artwork.

Add:

* Advanced Bézier manipulation
* Boolean operations
* Compound paths
* Non-destructive clipping
* Stroke expansion
* Gradient editing
* Reusable components
* More powerful alignment
* Improved SVG interoperability
* Advanced image placement and masks

Completion criterion: A designer can create an original vector illustration or logo entirely inside Form and prepare it for several different manufacturing processes.

### Phase 4: Print and Publication Design

Goal: Extend the same editor into more sophisticated printed matter.

Add:

* Linked text frames
* Multi-page documents
* Baseline grids
* Reusable document styles
* Bleed and trim management
* Print color-management improvements
* CMYK and spot-color workflows
* More advanced PDF production
* Preflight validation
* Packaging and textile production overlays

Completion criterion: A designer can prepare a professional printed insert, instruction booklet, or packaging artwork packet from within Form.

### Phase 5: Advanced Physical Integration

Goal: Connect graphic design more deeply to construction and manufacturing.

Add:

* Pattern-aware artwork placement
* More complex dieline relationships
* Advanced object-surface projections
* Artwork continuity across physical panels
* Dedicated embroidery artwork workflows
* Cutting and engraving preparation
* Shared design assets across collections
* More sophisticated material-aware previews
* Automatic production packet generation

Completion criterion: A designer can produce sophisticated visual work that remains connected to the physical objects and processes through which it will be manufactured.

## 18. Primary Demonstration Projects

The editor should be evaluated using actual graphic-design tasks rather than only isolated feature tests.

### Project A: Typographic clock dial

Create a 100 mm clock dial using a system-installed or user-installed OpenType font.

Arrange twelve numerals precisely, apply alternate glyphs or ligatures where applicable, adjust kerning and tracking, and create a set of vector markers.

Convert a duplicate of the typography to outlines and edit individual glyph shapes.

Change the artwork and see the physical clock preview update immediately.

Export the artwork as SVG and PDF at its actual dimensions.

### Project B: Product packaging

Create a folding paper package with several printable panels.

Edit type, illustration, logos, and colors directly on the dieline.

Use guides, snapping, alignment, and precise numerical positioning.

Preview the assembled package in 3D while changing the artwork.

Export the print artwork separately from the cut and score geometry.

### Project C: Apparel graphics

Create a graphic using vector illustration and custom typography.

Apply it to a T-shirt and create several alternate colorways.

Reuse the original artwork for an embroidered patch.

Convert appropriate paths into manufacturing-ready geometry using the relevant production subsystem.

### Project D: Instruction booklet

Design a short instruction booklet containing headings, body text, diagrams, and illustrations.

Use reusable text styles and exact page dimensions.

Export a multi-page printable PDF.

This tests the text system’s ability to handle both expressive display typography and practical information design.

## 19. Acceptance Criteria

The 2D editor should be considered successful when the following workflow is reliable:

## 1. Create a new artwork frame measuring exactly 8 by 10 inches.
## 2. Add text using any compatible installed Mac font.
## 3. Adjust font size, weight, leading, tracking, and alignment.
## 4. Apply supported ligatures, stylistic alternates, and variable font settings.
## 5. Manually adjust spacing between individual glyphs.
## 6. Add vector shapes and edit their nodes.
## 7. Align several objects using snapping, guides, and exact numerical properties.
## 8. Group objects, transform the group, and edit objects inside it.
## 9. Apply colors, strokes, gradients, and clipping masks.
## 10. Create a second variant of the composition.
## 11. Convert a copy of the typography to editable outlines.
## 12. Link the artwork to a physical object’s surface.
## 13. Edit the artwork while observing the corresponding 3D representation update.
## 14. Export dimensionally accurate vector and print files.
## 15. Save, close, and reopen the project with all supported typography, artwork, and editing relationships intact.

The output should be visually faithful, technically precise, and remain editable.

## 20. What We Are Not Building

The 2D editor should remain focused on graphic design rather than expanding into every adjacent creative software category.

We are not prioritizing:

* Interactive UI prototyping
* Web and application design systems
* Responsive webpage layout
* Developer handoff tools
* HTML or CSS generation
* Full raster painting and retouching
* Animation and motion graphics
* A general-purpose word processor
* Large-scale editorial publishing features in the initial implementation
* Every specialized capability found in mature illustration applications

These exclusions are important because they allow us to invest more heavily in the quality of the capabilities that directly support Form’s purpose.

The objective is not feature parity with Illustrator, InDesign, and Figma combined.

It is a deeply capable subset of professional graphic design tools that serves physical creative work exceptionally well.

## 21. Long-Term Vision

Form’s 2D editor should eventually become one of the reasons designers choose to use the application, not merely a necessary supporting feature.

Someone may begin by designing a physical product but discover that Form is also a wonderful environment for drawing, typography, and composition.

The editor should support the full progression from an initial visual idea to a carefully resolved piece of artwork.

A designer should be able to choose a beautiful typeface from their Mac, explore its ligatures and alternate characters, adjust individual letter spacing, manipulate its outlines, combine it with geometric illustration, and refine every element at precise real-world dimensions.

They should be able to use that artwork on a clock dial, a notebook, a piece of packaging, a T-shirt, an embroidered patch, or a laser-cut object without recreating it in another application.

The same design can appear in several physical forms, with manufacturing-specific representations derived as needed.

At the center of this experience is a powerful but approachable 2D canvas that treats typography, geometry, color, and composition with the seriousness they deserve.

The vision is to bring the quality of a professional graphic design application into a creative environment where every design can become a physical thing.

For Form to succeed, its 2D editor cannot merely be adequate.

It should be a genuinely excellent place to design.
