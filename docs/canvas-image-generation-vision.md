# Canvas image generation

This document records the product direction established for image generation on Canvas.

- **Generate Image is a contextual Canvas control.** It is invoked by clicking a specific area of the Canvas, not through a standalone UI button.

- **Choosing Generate Image immediately creates a generic blank artboard** in that area. The user does not need to click again to place it.

- **Generation controls appear contextually near the artboard.** They include a freeform prompt, model selection, model settings, user-saved prompts, and reference inputs.

- **Users can generate from an existing asset.** Right-clicking an asset and choosing to generate from it immediately creates a new blank artboard nearby, with that asset already attached as a reference.

- **References remain unchanged.** Generating a new image does not alter or remove the reference.

- **Canvas assets can be used as references.** This includes images and existing artboards; an artboard is flattened before it is sent to the model. For now, references can be limited to things already on the Canvas.

- **The prompt is unrestricted.** Inputs can include text, PNGs, PDFs, and other supported references; the output is an image placed on the new artboard.

- **Generated images retain their metadata**, including the prompt, model, settings, and references used.

- **The prompt library contains user-created prompts.** Users can save their own prompts for reuse.

- **Follow-up image edits are new generations.** A user can generate again using an existing asset as a reference. No additional markup or masking interface is part of this flow.

## Implemented local workflow

Right-click the Canvas and choose **Generate Image Here…**. LAB creates an ordinary blank artboard at that location and opens a contextual prompt. Return generates; Shift-Return inserts a line. Right-click artwork to generate from the selection, or choose the whole artboard explicitly. Additional references can be selected by name in the prompt panel. Closing the panel retains the current draft. The **Image prompt…** button above its top-right edge, the matching inspector action, and **Continue Image Prompt…** in its context menu reopen that draft without refitting or moving the Canvas. Saved prompts sit above the prompt editor; image settings remain visible in a separate column without scrolling the composer.

Drag any unlocked independent artboard’s edges or corners to change its bounds, including a blank generation artboard. Click its title to select the artboard, or drag the title to move it. Selected artwork keeps its own resize handles; explicit crop, mask and node editing controls take precedence over the active artboard boundary. Shift preserves the aspect ratio; Option resizes around the center. Handles and hover targets stay the same visual size at different zoom levels. Resizing an artboard changes its boundary, not the scale or crop of existing artwork; left/top edge changes keep artwork fixed in world space. A resize gesture is one Undo step, and Escape cancels it.

Canvas dimensions remain physical millimeters. Generation resolution is expressed separately in pixels: Small, Medium and Large use a 512, 768 or 1024 pixel long edge in the local demo. The artboard’s actual ratio determines the other pixel dimension (rounded down to whole pixels); the panel shows both units. Shapes between 1:8 and 8:1 are supported. Shape presets resize the blank artboard while preserving its long edge and top-left position. Generation fills the chosen bounds without resetting their size or placement. Resizing while a request is running invalidates that result and retains the prompt for retry.

The flow currently uses the same local provider, model configuration types, connection preview and project prompt library as Studio. **Generate demo** produces a labeled local graphic, with captured references shown as a collage. It does not interpret the prompt with an AI model. There is no network transport, credential lookup or live API call. The named model configurations are demo placeholders, not verified API model identifiers.

References are frozen into bounded PNGs before the provider request. Artboards, groups, images and selected artwork use the existing appearance renderer, including typography, clipping, transforms and transparency. Sources remain editable and unchanged. Up to eight references may be attached; hidden layers and component support definitions are excluded from the chooser.

Each completed result is a normal image layer on its destination artboard and is also registered in the project Library. Its prompt, settings, source identities, capture hashes, dimensions and demo status are saved as portable image provenance (project schema 60), visible under **Generation details** in the image inspector. Replacing the pixels clears that provenance. Moving, resizing, cropping and copying retain it.

Creating the artboard and placing a successful result are separate Undo steps. Cancel and failure retain the draft for retry. A changed project, removed/locked destination, or edits to destination contents prevent a late result from overwriting user work. Moving or renaming the destination during generation is allowed. Completed results wait for an active drag or text edit to finish, preserving its selection and Undo step. Prompt drafts are session state; saved prompts and completed image provenance persist across restarts.

## Live provider follow-up

The remaining API boundary is an implementation of `StudioImageGenerationProvider`. Before enabling it, add one shared credential service for Studio and Canvas, verify supported model IDs and output capabilities against the provider, map the frozen reference bytes into real image inputs, and exercise real responses, authentication, cancellation, service failures and image decoding. Neither surface should introduce its own independent key storage. The current request types and local failure fixtures allow the interaction flow to be tested without access to a real account.
