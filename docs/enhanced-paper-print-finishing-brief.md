# Enhanced paper support and print finishing

Product brief | October 29, 2026

Current implementation and validation: [twelve-case paper and packaging plan](paper-packaging-validation-plan.md) and [native validation results](paper-packaging-validation-report.md).

## Vision

Make LAB a place to design, construct, and convincingly present printed paper goods. A designer or agent should be able to create a wedding invitation suite, a business card, a printed envelope, or a screen-printed poster with editable artwork, recognizable paper stocks, physical construction, and finishes that look and behave like the intended print process.

The target is more than placing a flat graphic on a generic sheet. Thick cotton paper should look and feel different from a smooth coated card. Letterpress should read as an impression in the paper; blind embossing and debossing should respond to light; foil should reflect its surroundings; and layered stock should have convincing, distinct edges. These qualities need to remain connected to the actual design rather than existing only in a generated image.

The long-term reference test is to give an agent 100 varied wedding invitation references and have it recreate the designs as editable paper goods and produce very good-looking renders. Extend the same capabilities to other printed objects so the work is useful across the app.

## Starting point

LAB already has meaningful pieces of this workflow:

- Paper constructions with physical caliper, panel geometry, folds, opening, and inside/outside artwork.
- Editable Canvas artwork, typography, physical dimensions, and linked artwork surfaces.
- Agent-authored planar construction, inspection, and review tools.
- A procedural paper color and normal-map texture that suggests grain, plus physically based material channels in the rendering foundation.
- Studio compositions and image output; physical paper layouts and cut/crease outputs; and bounded CMYK and named-spot production output for supported artwork.

The current paper surface is a generic visual cue, not a library of measured or recognizable stock appearances. Artwork is flattened into a color texture rather than creating distinct printed and pressed surface treatments. Foil, artwork-driven relief, bonded paper plies, and envelope liners are not established as complete workflows. Rigid fold previews, on-screen color, and current Studio lighting do not establish photographic or press accuracy.

See [constructed paper goods](constructed-paper-goods.md), [agent modeling tools](agent-modeling-tools.md), [production inks](production-inks.md), and [Studio workflows](environment-workflows.md).

## Product outcomes

- Describe paper and print as real materials and processes that can be used on editable artwork and physical objects.
- Render the same object convincingly at whole-object and close-up scales, including texture, thickness, edges, print, impression, and reflective finishes.
- Let an agent use the same object, artwork, material, finish, camera, and inspection capabilities as the user to recreate and review reference-led work.
- Keep editable source artwork, physical construction, appearance, and production intent connected. Changing text or a shape should update its assigned treatment without manually repainting the result.
- Support both an accurate native scene and the planned Studio AI-rendering workflow. An AI-rendered image is a presentation output; it does not replace the editable source or prove the accuracy of its construction and artwork.
- Make incomplete information and unsupported processes visible so attractive imagery is not mistaken for a verified manufacturing specification.

## Paper materials and physical construction

Support visually distinct paper and board materials suitable for both design and presentation: for example, cotton letterpress stock, smooth uncoated and coated papers, laid or linen textures, recycled fiber, and translucent vellum. Materials should carry applicable physical properties such as color, thickness, weight, grain, and sheet dimensions, as well as appearance properties such as texture scale, roughness, and light transmission.

Material changes should affect the object and its rendered appearance. The visible paper face, its cut edge, and its response to light should read as the same stock. Enable reusable paper materials in the Lab and project contexts, consistent with the [Lab library direction](lab-library-vision.md). Manufacturer or stock-specific claims should be based on actual source information; a plausible visual material is not automatically a measured stock profile.

Support bonded, duplexed, or otherwise layered paper stock. Each ply can have its own material and thickness, with the total caliper and visible edge reflecting the construction. Front/back printing is a separate concern from bonding multiple sheets.

Support cards, sheets, folded pieces, envelopes, and distinct envelope liners. A liner should have its own paper, shape, and artwork and sit in the envelope as a real component. Existing general construction and linked artwork tools should be the foundation; avoid requiring a separate hard-coded object generator for each example.

## Print and finishing treatments

Make treatments assignable to editable text, vector shapes, or other relevant artwork on a physical paper surface. Their boundaries must follow the source artwork as it changes and preserve placement across linked representations.

Treatments should cover:

- **Flat printed ink**, including separate colors and the appearance of printing on the chosen stock.
- **Letterpress**, combining ink where present with an impression in the paper.
- **Blind deboss and emboss**, including finishes without ink.
- **Foil stamping**, with a distinct reflective appearance and the ability to combine foil with an impression.
- **Screen printing**, including distinct ink areas, color layers, and the relationship between the ink and paper.

The design should retain the intended treatment, target artwork and surface, and relevant editable properties such as color or appearance and impression depth or height. A treatment can be presented through a combination of fine surface shading and actual relief or geometry as appropriate to the scale and view. Shading alone must not be represented as physical geometry where silhouette, edge shape, shadow, or manufacturing output depends on the relief.

Treatments may overlap or be adjacent: a blind embossed mark, foil-stamped monogram, and printed text can coexist on one card. Review the resulting order, registration, and combined appearance rather than flattening all finishes into one undifferentiated color image. The exact initial finish range and controls should be guided by the stress tests below.

## Rendering and Studio

Paper, ink, relief, and foil need lighting that makes their differences legible. Studio should support the camera and scene control needed to compose a full suite, inspect an edge, and examine an impression under angled light. Agents should have corresponding MCP control for repeatable composition and review, in line with the [Studio AI rendering direction](studio-ai-rendering-vision.md).

Preserve enough source and render detail for fine typography, thin rules, small foil shapes, and close-up paper texture. The current paper artwork atlas has a bounded resolution; simply exporting a larger image cannot recover detail already lost in a lower-resolution texture. Evaluate the complete source-to-render path at the intended output sizes.

Studio AI rendering may use a native scene image and the intended photographic settings to produce a polished presentation. The workflow should make it possible to compare that image with the editable scene, especially for text, artwork, proportions, and finishes. Do not assume an image model preserves those details without checking.

## Reference-led agent workflow

The agent should be able to inspect a reference, construct the paper objects and editable artwork, choose materials and treatments, configure a scene, capture views, compare the result, and revise it. This should use the existing project and modeling tools, adding general capabilities when the workflow exposes a gap.

Keep reference material, relevant source information, decisions, and resulting editable project data available for continuing work. When a reference does not establish a detail—such as exact paper caliper, typeface, back artwork, or the depth of an impression—the agent can make a well-informed choice or ask for more information. A visual match to one photograph alone does not establish a verified physical specification.

## Stress-test projects

These examples are acceptance exercises, not hard-coded product categories. Each should produce an editable project, a convincing full view, and close views that expose the relevant material and finish.

### Wedding invitation suite

Create an invitation on thick textured cotton stock, with editable letterpress text, a blind embossed or debossed detail, and a foil-stamped element. Include an envelope with printed addressing and a separately materialized, patterned liner. Review the suite as a composition and inspect the card surface, foil, paper edge, and liner at close range. Change the wording, stock, and at least one finish and verify that the construction and appearance follow.

### Duplexed business card

Create a double-sided business card made from two visibly different bonded stocks, with a contrasting edge and a small debossed or foil detail. Inspect front, back, and edge; change a ply's thickness or color and verify the overall caliper and edge. Review fine text at close range and confirm the finish stays attached after editing.

### Printed envelope

Create an envelope with editable front addressing, a printed return address, and inside artwork or a distinct liner. Inspect it closed and open, checking orientation, fold relationships, and the relationship between the liner, envelope, and printed surfaces. Test changes to dimensions and artwork without silently stretching or losing the intended placement.

### Screen-printed poster

Create a physically sized poster on a visibly textured sheet with multiple screen-printed colors and editable artwork. Inspect both the full composition and details of thin lines, color boundaries, paper texture, and ink coverage. Change one color or layer independently and verify that the result remains connected to the source. Where production output is supported, inspect the separate print information at actual size.

### Reference variety

Add other examples that challenge the same capabilities: smooth versus heavily textured stock, subtle blind impressions, dense fine typography, foil next to flat ink, multiple plies, and translucent or dark papers. Include views where surface effects are easy to see and views where they are subtle.

## Validation and completion

Start with the four stress-test projects, then evaluate the 100-reference wedding-invitation goal across varied designs and finishes. Use references with the necessary permissions and retain the source and review context. Where possible, include multiple angles or detail views for the same design.

For each evaluated piece:

1. Recreate the physical object and editable artwork using the available tools.
2. Capture whole-object and relevant close-up views under suitable lighting.
3. Compare layout, typography, proportions, material, finish, and construction against the reference; revise and inspect again.
4. Change representative artwork, material, dimensions, and finish settings; confirm the result updates and remains editable after save/reopen.
5. Record what was observed, what was assumed, and what could not be verified from the available reference.

Review visual quality with human judgment as well as any automated comparisons. Report results across the set, including failures and unsupported treatments, rather than treating a small number of attractive renders as proof of general coverage. Check native scenes and AI-rendered outputs separately.

For fabrication, distinguish an editable visual treatment from a production-ready output. Existing artwork, color, and paper exports are useful foundations, but accurate press separations, tooling, registration, bleed, trapping, and physical prototypes should only be claimed where the app has actually generated and verified them.

## Suggested delivery sequence

1. Establish a representative paper material and a physically thick, editable printed card; verify close-up rendering and text detail.
2. Add artwork-driven ink and impression treatments, then foil, including combinations on the same surface.
3. Add layered stock and envelope-liner construction, and exercise full suites and other paper forms.
4. Strengthen Studio camera, lighting, and MCP review for the materials and finishes; connect the planned AI-render path when available.
5. Run the stress-test projects and expand to the 100-reference evaluation, using failures to guide general improvements.

These are product milestones, not a commitment to a particular rendering engine or a separate special-purpose UI. Preserve existing paper, Canvas, artwork, and production workflows as the capabilities grow.
