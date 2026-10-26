# MERIDIAN — reference-led desk clock, version 01

The October 26 desk-clock project starts with the user's original photograph copied byte-for-byte into its freeform Canvas. The reference is a locked, editable image layer, independent of its Downloads source. Notes, physical dimensions and the editable dial sit alongside it. The photograph is retained in the local project, not published in this repository.

The first construction follows the reference's tapered bowed case, warm recessed surround, ivory face, long fine hour indices, narrow 12/6 numerals, spear hands and splayed feet. Case dimensions are **180 × 166 × 54 mm**, with approximately **180 mm overall height**. They are inferred design dimensions, not measurements of the photographed clock.

## Editable construction

The native `deskClock` recipe exposes actual outside width/height/depth, normal wall thickness, top taper, outline roundness, rolled edge, shaft bore and displayed time. The case uses a convex tapered superellipse, normalized to its stated outside dimensions. Inward polygon offsets maintain the physical wall, rather than scaling a smaller outline. A 512-sample perimeter and eight segments per quarter-round produce a smooth closed triangulated shell. The sampled outline chord error is below 0.002 mm at the checked default and extreme settings; this is a geometric check, not a manufacturing tolerance.

The case, outer bezel and inner surround are closed swept rings. The dial is a separate 2 mm solid with an actual 8.2 mm through-bore. The rear cover is a separate plate. Hands and hub occupy separate depth levels. Four feet are shown in the assembly. Display artwork and hand inlays are excluded from physical component output. The assembled clock is deliberately unavailable as one fused print.

The case uses FORM's material selector and custom finish. The initial design combines muted metal, brass-colored trim/hands/feet, a warm brown surround and ivory dial. The surround and trim are currently fixed material choices in this bounded construction; general component material editing is a follow-up.

Dial graphics are ordinary editable SVG paths and live type at physical millimeter scale. Rendering and SVG/PDF output use the shaped face and shaft opening as the actual boundary. The photograph is not used as a face texture. The 2D dial and upright 3D face use the same source. Displayed hand changes reuse the case geometry and preserve camera controls.

## Physical preparation

Print preparation exposes **Case shell, Bezel, Inner surround, Dial, Back cover, Hour hand, Minute hand, and Foot (print 4)**. The foot exports once in its own fabrication coordinates; assembled legs at different depths must not become floating bed islands. Use X rotation 90° for the flat case/dial parts and 0° for an upright foot, then review supports and orientation for the chosen material/process. No slicing or printer connection is required to export millimeter STL.

The blank dial STL does not contain embossed ink. Use the separate physical artwork for a printed insert, marking or a later engraving/embossing workflow. Brass appearance in a render does not specify a manufacturing material.

## Validation and current stopping point

The construction passes **989 optimized tests: 643 core/graphics/IPC and 346 native**, including six new tests. The physical component test independently checks every component's centered binary STL triangle edges, positive volume, physical bounds and P1S bed fit. It rejects assembled-object printing. Core checks cover convexity, physical wall offset, taper, linked artwork, reference-layer source, strict controls and schema50 save/reopen. A native regression verifies that displayed time reuses the case geometry. The schema gate prevents older readers from silently opening an unsupported construction; portable artwork transfers accept the new project schema.

The first version is a detailed form and component prototype. These items remain before a functional clock build:

- Measure the selected movement, shaft length/diameter, hand fittings and adjustment/battery access.
- Design movement bosses, rear-cover fixings, dial seats/retention and foot sockets/fasteners.
- Add the clear shaped lens, its rebate and retention; the first version leaves the dial exposed.
- Establish actual assembly clearances and test coupons for the selected printer/material.
- Decide on physical dial marking and hand manufacture; add emboss/engrave only after choosing the process.
- Add general editable profile/loft/shell tools, component materials and direct MCP mesh export as broader modeling capabilities. The current construction is a focused native recipe.

- Normalize SVG provenance dates across MCP getter/setter round trips. `form_get_artwork` returns ISO-8601 dates while the current `form_set_artwork` decoder expects reference-date numbers. The project handoff converts those dates without discarding original SVG records.

Actual native Save dialogs export all eight components. Independent Python inspection of the saved binary STLs verifies every nondegenerate edge has two incident faces, positive volume and expected millimeter bounds. The case is 180×166×54 mm, the blank dial is 2 mm thick, and the upright foot is 24 mm tall. The exposed first foot-cap seam was replaced with shared topology; the regression now inspects centered STL bytes. Actual renders and native split view verify the upright 12/signature/6. The original image survives real app replacement/restart, and the linked dial master passes an actual source edit, exact Undo and saved reopen. All five earlier projects and Studio settings remain exact. [Native/physical evidence](evidence/desk-clock-native.json).

The project records these decisions on its Canvas and in its notes. No print is sent or started, and geometric validity does not establish movement compatibility or fit.
