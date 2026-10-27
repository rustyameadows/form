**I’d make the dieline a first-class view of the carton, available across all three sections. Function would be its primary home for construction work, but Form should absolutely let you design artwork directly on it.**

The distinction is between **what you’re working on** and **how you’re looking at it**. Those should be two independent choices.

## Form, Function, and Fabricate describe your purpose

For this carton, I’d organize them like this:

| Environment | The question you’re working on | What comes forward |
|---|---|---|
| **Form** | What should this look like? | Artwork, typography, materials, composition, visual proportions |
| **Function** | How should this be constructed and work? | Box style, panels, folds, closures, thickness, fit, clearances |
| **Fabricate** | How are we going to produce this version? | Stock, production process, sheet layout, output settings, previews, files |

**The assembled box and the flat dieline are useful in all three.** The environment determines which controls, annotations, and relationships are emphasized, rather than restricting which representation you can see.

That also gives Function a broader identity. It isn’t the electronics-and-mechanisms tab. It’s where you work on construction, relationships, and behavior. For a box, that means how it folds, closes, and holds its contents.

## I’d give the carton two linked 2D layouts

Your proposed face projections are useful. I’d call that view **Panels**, with **Dieline** as the alternative.

### Panels: compose each surface comfortably

The front, back, sides, and other relevant surfaces appear separately, arranged upright and conveniently for artwork editing.

You can work on the front without having to rotate your head because its physical position in the flattened carton happens to be upside down.

These should represent the carton’s identified surfaces, including relevant hidden or interior surfaces, rather than only whatever faces happen to be visible from the current camera.

### Dieline: compose and inspect the complete flat construction

The panels appear in their actual flat arrangement, with the tabs, flaps, cut boundaries, and crease lines.

A structural packaging definition contains more than projected exterior faces: cut and crease information, and potentially folding angles, establish how that flat structure becomes the package. [Esko Documentation](https://docs.esko.com/docs/en-us/studiodesigner/14/userguide/home.html?q=en-us%2Fcommon%2Fst%2Fconcept%2Fco_aboutardfiles.html\&utm_source=chatgpt.com)

In LAB, I’d make this view available with artwork on or off, plus an explicit choice of outside or inside artwork.

**You’re editing the same artwork through either layout.** A logo on the front panel remains the same logo when you switch to the dieline. Its apparent orientation changes to reflect the construction, but its relationship to the panel remains intact.

This also gives you a place to compose artwork that spans several connected panels, rather than treating every surface as an isolated little poster.

## My default UI would be a toggle, with an optional second view

For the selected carton, I’d put a compact **Panels / Dieline** control above its 2D workspace.

Switching it changes the representation of that carton’s working surface. It doesn’t rearrange the rest of your project, move your references, or change the actual design.

Your adjacent 3D view stays visible. Selecting a flap in the dieline highlights that flap on the box. Selecting a surface on the box brings its corresponding region into focus in 2D.

I like your idea of animating the panels into their dieline positions. That could make the relationship immediately understandable. But it would be a view transition, not an actual operation on the artwork.

For someone like you who wants to see both, add **Open linked view** or **Pin dieline to canvas**. Then you can have the individual panels and the whole dieline beside one another.

That gives you the expansive studio behavior without requiring every carton to automatically occupy three separate areas of the canvas.

**Default: switch representations. Optional: keep several linked representations visible.**

## Function is where you work out the construction

Imagine you’ve developed the carton’s graphics in Form. You select **Function**.

I’d retain the selected carton and its current view, while changing the contextual controls. For this object, they might include construction style, internal and external dimensions, board thickness, closure, and fold behavior.

You can now say:

> “Actually, I want this to open from the side, and I want the flap to tuck inside.”

The agent proposes a construction change. The dieline shows what changed, while the assembled view shows the resulting opening.

Or you select a fold and say:

> “We’re using thicker board. Make sure there’s enough clearance here.”

That request now has a concrete target. LAB knows which fold or panel relationship you’re referring to. The agent can propose a structural adjustment, run the available checks, and show the effect.

I’d make the resulting summary specific:

> “I’ve adjusted the closure allowance while preserving the internal dimensions. The top flap changed; the front artwork stayed at its original physical size.”

That is much more useful than “updated the box.”

Board choice, thickness, and fold angles are already explicit inputs in established packaging construction workflows. LAB’s opportunity is to make those relationships available through the same visual and conversational environment as the artwork. [Esko Documentation](https://docs.esko.com/docs/en-us/studiotoolkitforboxes/14.1/userguide/en-us/common/stb/task/ta_select_the_board.html?utm_source=chatgpt.com)

### Markup should work in whichever view explains your intention best

Since your interaction is primarily agent-driven right now, **selection and annotation are more important than building a complete manual dieline editor immediately**.

You should be able to mark up:

- The flat dieline to indicate a cut, fold, flap, or desired outline.
- The assembled box to describe an opening, fit issue, or visible shape.
- A partially folded view to explain how two parts should meet.

Those annotations should reference the actual panel, edge, fold, or region, along with the view in which you made them. The agent gets both your visual explanation and an identifiable part of the product.

A fold/unfold control would be especially valuable here. It helps you communicate about construction, even before LAB has comprehensive physical simulation.

## “I want to print here” crosses the environments naturally

That request contains both a creative intention and a construction or production question.

I’d let you select the surface and request artwork from wherever you are. Form provides the artwork tools. Function helps inspect whether the surface is exposed, concealed, or involved in a join. Fabricate checks the selected production route.

For example:

> “Put a small message inside this flap so you see it when opening the box.”

LAB could bring forward the inside artwork surface, show the box partially open, and let you compose the message.

You shouldn’t need to know which tab technically owns each part of that request. **The tabs organize attention; the agent and product relationships connect the work.**

Similarly, “Change box style” should be accessible from Form, even though the detailed construction comparison belongs in Function. It can open that context rather than force you to hunt for the setting.

## The underlying relationship is what makes the views work

I’d want the carton to have one construction definition describing its panels, edges, folds, joins, dimensions, and material assumptions.

Its assembled geometry and flat pattern come from that definition. Artwork attaches to identified surfaces or the connected flat layout.

When the agent changes something, it updates that construction definition. The views then regenerate.

This matters especially when changing box styles. Some surfaces may retain a clear correspondence; others may disappear or be replaced. I’d preserve artwork on corresponding panels and flag anything that needs placement review, rather than silently stretching everything to fit.

And when the starting object is only a conceptual box, opening Dieline may require an additional development step:

> “I’ll propose a folding construction for this shape.”

That is a useful moment in the workflow. The object is becoming more resolved, not merely changing camera angle.

## Fabricate uses the resolved design to create a production job

I agree with your instinct that Fabricate is primarily preparation, preview, and handoff.

The same dieline appears there, but now in relation to the selected stock, sheet dimensions, print and cutting processes, and output requirements.

The task is something like:

> “Prepare three prototypes on the stock in my studio.”

LAB lays out the pieces, prepares the relevant artwork and construction outputs, and previews the supported production sequence.

If the chosen process requires a design change, Fabricate can propose that change and take you back to the relevant construction context. Once you accept it, the production job is regenerated from the updated revision.

That keeps the distinction clear without making the workflow one-way.

## The organizing principle

I’d use this rule throughout LAB:

**Form, Function, and Fabricate determine what you’re doing. Panels, dielines, assembled models, sections, and other views determine what you’re looking at.**

For your carton, that means:

**Design the graphics on the dieline in Form. Develop the construction through the dieline in Function. Prepare the dieline for production in Fabricate.**

One carton, connected representations, different working perspectives. That feels much closer to the LAB thesis than assigning the dieline exclusively to one tab.