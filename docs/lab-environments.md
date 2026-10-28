# LAB environments

LAB organizes work around one project. **Form**, **Function**, and **Fabricate** are the three primary navigation buttons. **Studio** is a separate environment reached through the aperture icon beside them or **Studio → Show Studio**. It is intentionally outside the main three.

## Form

Work with typography, paths, images, references, materials, object appearance and spatial composition. The secondary Views toolbar offers **Canvas**, **Table**, **Split**, and the separate Canvas window. Existing artwork tools and contextual object controls remain available.

## Function

Inspect the same project's components through the object chooser. Existing native controls expose dimensions, recipe parameters, material, placement, linked artwork sources, textile relationships, cloth attachments and pattern-assembly controls where applicable. These edit the original objects and share their existing Undo history. This transition does not introduce a new constraint solver, electronics editor or mechanical simulation system.

The Canvas and Table remain available here. Clicking a view changes editing focus without changing the environment or silently focusing/refitting an object.

## Fabricate

Choose a source object to enable its supported processes:

- Solid object: native 3D print bed, component/orientation/filament settings and local slicing.
- Independent rectangular artwork frame: actual-size physical-page/PDF review.
- Artwork with sewing pieces: cutting-pattern/tiled PDF and material cutting layout.
- Eligible embroidery component: actual stitch preview, digitizing and process controls.
- Finite artwork/decorated face: HTV/DTF preparation.
- Project: existing production jobs/archives and collection plans/packets.

Filaments, materials and equipment are in **LAB Library**, available from the navigation icon and Fabricate panel. Process eligibility follows the source; choosing a context does not manufacture a new export, duplicate the object or send a job. Printer upload/start remain disabled.

## Studio

The existing full 3D presentation surface retains lighting/background options, exact-subject saved shots, reference framing and image/render-record output. Returning to Form, Function or Fabricate restores the prior design surface arrangement and artwork source. Existing camera gestures and whole-project named-view framing are unchanged.

## Data and integration

Environments are ephemeral interface state. Projects, source links, materials, assets, production records and shared Undo are not copied or migrated when switching. A project change dismisses old production reviews and clears the previous project's Studio return context.

LAB uses the existing `.form` packages, ordinary `Application Support/FORM` library, bundle/document identifiers, defaults, Keychain service and local socket. The native bundle is `build/LAB.app`; compatible legacy launch/helper paths and `form_*` MCP tools remain supported. See [MCP setup](mcp.md) and the [transition contract](lab-transition.md).
