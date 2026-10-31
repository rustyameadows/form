# Studio AI rendering

This document records the product direction established for AI rendering in Studio.

The [local still-workflow implementation](studio-ai-stills.md) now rehearses scene input, prompts, references, provider setup, generation states, result review and the global asset Library. It uses a clearly labeled local mock and makes no API calls.

- **Studio should provide fine-grained camera and scene controls**, especially through MCP, so a user or agent can compose a shot and configure the camera.

- **Studio should support AI rendering as part of the existing rendering flow.** A user can choose an AI option, provide a prompt, and generate an image from the configured scene.

- **The handoff should include the user’s photographic intent.** Camera and scene information—potentially including lens, sensor, depth of field, grain, and similar choices—can accompany the image and prompt.

- **The image sent to the model may be rendered with or without some effects.** For example, Studio might provide a clean, full-resolution image and communicate the desired lens character in the handoff.

- **The user or agent configures the camera, supplies a prompt, and selects a model.** The generated image is then placed in an easily accessible Studio library.

- **Saved render styles should be supported.** Preset treatments such as product photography or editorial presentation are possible starting points, and users should be able to save their own styles. Their exact design remains open.

- **Creative AI generation belongs in Canvas.** A user may take a Studio still into Canvas for creative experimentation and potentially bring the result back into their work. Studio’s AI feature is for rendering the actual scene and product.
