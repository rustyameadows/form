# Studio stills and Library

Studio's **Generate image** action opens a local preview of the AI-assisted rendering workflow. It captures the current working composition, including unsaved instance placement and the camera currently on screen. Capturing does not save the scene or change design objects, artwork, the Table camera or their Undo history.

This implementation is deliberately a mock. It has no OpenAI client, network transport, ambient credential lookup or Keychain integration. Its local provider produces native scene images with a deterministic color treatment and a visible **LOCAL DEMO** mark. Prompts and references are recorded for the workflow; no model interprets them. They are not AI-generated final assets.

## Scene to still

1. Compose a Studio scene and choose **Generate image** below **Save still…** in the inspector. Saved scenes live in the left thumbnail strip; add instances and props from the viewport dock.
2. Review the captured input. The capture is fixed; use **Recapture** to bring later scene edits into another run.
3. Choose a prompt preset to fill the editor, then edit it freely. Save reusable prompts within the project. Choose model, aspect, preview size, quality and one, two or four outputs. Optional references can come from local image files or Library, with a declared role.
4. Choose **Use demo connection** in OpenAI connection setup, then create demo images. Progress, cancellation, failure and retry all run locally.
5. Browse project results in the right thumbnail strip. Preview opens a separate, nonmodal window without replacing the prompt, input, options or references being authored. Compare a result with its original scene, rename or favorite it, save a copy, reuse it as a reference, or explicitly place it on Canvas. Regenerate is an explicit action that loads the earlier run.

Returning to the composition leaves an active job running within the same project. Switching projects or going Home cancels the active job and prevents a late result from appearing in the next project. Completed results and run history remain in Library. A running request uses its frozen input even if the scene is edited afterward.

Using a result as a reference preserves the next prompt, settings and input. Undo and Redo in the still workspace target its native text editor; they do not undo a hidden scene edit.

The preview scenarios exercise authentication failure, rate limits, an offline state and a refused request. These are simulated states rather than claims about an actual account, network connection or policy decision. Retry creates a new run and preserves earlier records.

## Authoring layout and scene context

Studio keeps saved scenes in a narrow thumbnail rail, with the composition viewport in the center and the existing camera, instance and lighting inspector on the right. Thumbnails render saved compositions independently; moving the live camera does not overwrite a saved scene or its preview. Motion and video controls are hidden in this stills workflow. Existing saved motion data and automation interfaces remain supported.

Image authoring uses three columns at both wide and minimum window sizes: frozen scene input and metadata on the left, prompt presets and an expanding native text editor in the center, and this project's generation history on the right. Upload, Library, model settings and generation controls stay below the prompt. Results open in one owned preview window; returning to the composition or changing projects closes it.

A capture records a bounded context alongside its native scene image: visible objects and placements, declared dimensions where available, paper stock and face substrates, print finishes, authored mesh material slots, camera, lighting, surface and exact captured pixel dimensions. Registry material defaults are distinguished from authored paper and mesh properties. This same frozen context is passed to the local provider and retained in the run record, with a digest in asset provenance. Later scene edits do not change a past run's input. Older captures without context remain readable and identify the missing details.

## OpenAI setup preview

Connection setup is available from the image workspace, Studio menu and Settings. It opens a normal, independent Mac window. **Use demo connection** works without entering a key. The optional secure field demonstrates masked API-key entry; its contents stay inside that view, are never passed to the provider, and are cleared when the window closes. **Run demo check** simulates connection outcomes. No key is stored, tested or transmitted.

The provider choices are GPT Image Sunburst and Flare, identified separately from the local mock provider. The model identities and future image/reference handoff are based on the [official OpenAI image-generation guide](https://developers.openai.com/api/docs/guides/image-generation). The preview's bounded image sizes and color treatments are local fixtures, not live model capabilities, quality guarantees or pricing estimates. Enabling real API access requires a separate implementation and explicit authorization.

## Project asset Library

**Library** in each project's top navigation opens an independent window for that project, including projects with no assets. Empty projects show an empty Library. Search, filters, view mode and import share one compact toolbar; source, file type and favorites filters live in its filter menu. There is no cross-project browser or Library entry on Home. Uploads, generated images, exports and reference choices belong to the active project. Switching projects or going Home closes and discards the old Library window.

Uploads are copied into the project's Library inventory; existing project Assets and Exports are indexed as references. Ordinary renderer record sidecars and temporary files are excluded from media browsing. Existing files and index records are preserved when scoping the inventory; unassigned legacy assets are not silently assigned to an arbitrary project.

Rename and favorite affect Library metadata. Removing an item archives its entry; it does not delete the original upload, export or project asset. Missing files remain identifiable. Generated demo images retain their demo label, source-image links and run identity. Saving a copy preserves the original, and placing an image on Canvas uses the existing native image importer as an explicit design edit.

The shared on-disk index and owned media remain under `StudioAssets` in the configured LAB library, separately from `.form` design schemas. Each Library instance has an immutable project scope, exposes only that inventory and preserves other projects' records when publishing changes. Background indexing scans only the current project and merges metadata edits made while scanning. Generation history and custom styles are also scoped to their owning project.

## Local validation

Provider, persistence and native integration checks run without any API key or outbound request. It includes real prompt/key-field and mouse actions, result review, empty-reference dismissal, cancellation, project switches, interrupted history recovery, source preservation and Canvas Undo. Existing Studio manipulation, native export and independent Canvas/Table selection checks also pass. The authoring gate also covers saved-thumbnail caching and invalidation, native stage selection while editing dimensions, prompt presets, frozen material context and nonmodal preview focus. Native visual checks cover wide and minimum-width workspaces, connection setup and Library.
