# Embroidery and patch production

Research note | October 30, 2026

## Purpose

Assess LAB's current embroidery foundation and identify what it needs to become an excellent tool for designing and producing embroidered patches, whether someone makes them at home or works with a manufacturer.

The goal is a connected workflow: editable artwork becomes a complete patch design, actual stitch instructions, a useful physical preview, and the right deliverables for the chosen maker. The person or agent can review a sample, make changes, and regenerate the work.

## Current foundation

LAB already generates actual needle commands from editable vector and text artwork. A decoration can define ordered regions, threads, physical dimensions, and a hoop. Its current digitizing methods are running stitch, constant-width centerline satin, and basic angled scanline fill. Explicit underlay and tie-in/tie-off stitches are available. The editor previews needle paths, travel, trims, and playback; editing the source can regenerate the program.

The patch surface displays the same needle paths as the generated program. Exports include real DST, a thread-color sidecar, exact command JSON, and an actual-size needle-path SVG. Hoop and geometry preflight is available. The production-job workflow can capture an immutable revision, thread schedule, equipment declarations, assumptions, an actual-size hoop review PDF, and selected outputs. See [regenerable embroidery](embroidery.md), [physical stitch surfaces](embroidery-process.md), and [production jobs](textile-production-jobs.md).

This is a substantive foundation, not just a decorative image effect. Its limits are equally important:

- Satin uses a centerline and constant width; fill uses a basic scanline approach with unoptimized travel. There is no automatic image-to-stitch inference.
- Underlay and locking are explicit; fabric compensation, automatic routing, density tuning, and machine-specific process settings are not inferred.
- The thread preview uses textures derived from the actual needle paths. It does not simulate thread stacking, tension, or fabric deformation.
- The showcase's merrow-style border is an appearance study and is not included in its stitch program. The patch's visible construction and machine instructions are not yet a complete patch-production model. See [the flight bomber study](flight-bomber-showcase.md).
- Exported DST has been independently decoded and compared with the generated program, but a physical sew-out and compatibility with a particular machine have not been established.

## Artwork, stitches, and manufacturers

An ordinary artwork SVG describes the visual design; a machine embroidery file contains needle movements and machine instructions. They serve different purposes. LAB's needle-path SVG is a representation of its generated stitch program and is different from an ordinary editable source-artwork SVG.

Many patch manufacturers accept vector artwork or other images and digitize the design themselves. Their digitizer may choose different stitch types, directions, density, underlay, sequencing, colors, or border construction. Even if a manufacturer accepts LAB's stitch file, the physical result can vary with fabric, stabilizer, thread, machine, and finishing. Acceptance of a supplied stitch file is vendor-specific.

Two useful handoff paths are:

1. **Manufacturer digitizes:** provide the source artwork, finished size, thread and material intent, border and backing requirements, and a visual reference. The supplier creates the stitch program.
2. **Manufacturer uses or adapts LAB's program:** provide the machine file, thread schedule, specifications, and review material. Confirm the supplier's required format and whether it will use or modify the supplied program.

The current production packet can include needle-path SVG, DST, program JSON, and review material. Ordinary source-artwork export is a separate operation; the listed packet outputs do not include a standalone source-artwork SVG. A future handoff should make the distinction clear and make it easy to provide the appropriate materials together.

The customer's LAB design, the supplier's digital proof, any returned stitch file, and the physical sample should be comparable. If a supplier redigitizes the artwork, the LAB preview communicates intent; it is not proof that the supplier will produce the same stitch pattern.

## Home embroidery

LAB exports a real DST program, which some home embroidery machines can read. A machine's supported formats, hoop size, and other limits depend on its model. LAB does not currently export PES or JEF. Equipment records can compare declared hoop and DST support but do not establish actual machine compatibility.

DST does not embed the full RGB thread palette; LAB writes an ordered thread sidecar. Its trim uses a conventional sequence of jumps whose interpretation varies between machines. No export sends or starts a machine job.

A successful home workflow needs more than a file: a compatible machine and hoop, suitable fabric and stabilizer, thread and needle choices, a test sew, and a way to cut and finish the patch. Some border or backing treatments may require a separate finishing operation or equipment.

## Opportunities

### Production-quality digitizing

Improve the stitch program while preserving the editable artwork-to-stitch relationship:

- Satin columns with variable width, curves, corners, and controllable stitch direction.
- Better fill routing and sequencing, with useful controls for density, angles, entry and exit points, overlaps, and travel.
- Additional underlay and lock strategies; appropriate handling of short stitches, fine details, and small lettering.
- Explicit fabric, thread, and stabilizer context, including pull compensation and other adjustments that affect a physical sew-out.
- Clear inspection and manual correction of stitch order, commands, and generated regions where needed.

Investigate established digitizing tools and libraries, including Ink/Stitch and its underlying format support, before assuming LAB should reimplement every capability. Evaluate integration, licensing, supported platforms, and preservation of editable project data.

### Complete patch construction

Represent the patch as a physical item with a shape, size, base fabric, thread coverage, border or edge treatment, backing, and attachment. The finished appearance and production description should agree about what is actually sewn, cut, attached, or finished separately.

Allow the same patch to be inspected on its own and placed on a garment or other object. A visible merrow-style border should be identified as a separate finishing operation unless the actual production workflow represents how it is made; it must not silently appear in the preview as though it were part of the exported needle program.

### Machine formats and compatibility

Support formats and limits for representative home and commercial machines, potentially including PES and JEF alongside DST. Select the machine and hoop, export an appropriate program and thread information, and report the compatibility that has actually been verified. Check behavior such as color changes and trims on the selected machines rather than relying only on the extension.

### Appearance and inspection

Make the actual stitch program more convincing and useful to review: thread sheen and direction, raised satin and overlapping stitches, base-fabric weave, coverage, and realistic edges. Preserve a clear way to inspect the needle sequence, underlay, travel, trims, and small details at the patch's finished physical size.

A polished Studio image can communicate the design, but it should not hide differences between the image, the stitch program, and the finished physical patch.

### Physical validation and iteration

Test exported designs on real machines and materials. Include small lettering, curved satin, fills with holes, multiple colors, different fabrics, and complete patch finishing. Compare the sew-out with the program, preview, intended dimensions, and design reference. Record issues such as gaps, puckering, registration, thread breaks, illegible details, trim behavior, and border quality against the specific revision.

Use the existing revision-linked job and sample records as a starting point. A successful software preflight or visual preview is not a substitute for a physical sample.

## Suggested first end-to-end test

1. Create an editable patch from source artwork and set its physical size, shape, base fabric, border, backing, and thread colors.
2. Generate and inspect the actual stitch program, including order, underlay, travel, trims, and hoop fit.
3. Review the patch on its own and attached to a garment; check the appearance of thread, material, and edge at close range.
4. Produce a manufacturer handoff with source artwork and specifications, and a machine-compatible stitch file and thread schedule for a selected home setup.
5. Make a physical sample, compare it with the design and preview, record the results, revise the source and program, and repeat.

Repeat the workflow with several patch shapes, levels of detail, materials, finishing methods, and machines. Use the results to decide which general capabilities to improve first.

## Research references

- [STAHLS patch artwork guidance](https://blog.stahls.com/top-10-q-a-emblems-patches/): vector artwork and patch ordering considerations.
- [Stitch America digitizing](https://stitchamerica.com/embroiderydesigns/digitizing): digitizing and physical proofing as part of a manufacturer's process.
- [Brother file and hoop guidance](https://help.brother-usa.com/app/answers/detail/a_id/55842/~/machine-is-not-recognizing-the-design-from-the-bes-lettering-software): machine-specific file and hoop compatibility.
- [Brother test-sew guidance](https://help.brother-usa.com/app/answers/detail/a_id/64799/): checking a design on the fabric to be embroidered.
- [Ink/Stitch workflow](https://inkstitch.org/docs/workflow/) and [supported file formats](https://inkstitch.org/docs/file-formats/): an existing digitizing workflow and machine-format ecosystem.
