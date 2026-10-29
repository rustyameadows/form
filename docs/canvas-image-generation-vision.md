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
