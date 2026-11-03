# Multi-sheet publications

This push extends the existing `PublicationDocument`, `TextStory`, independent page artwork and native shared text editor. It adds a generic ordered-sheet assembly; booklets, magazines and case covers are project-authored configurations rather than application model types.

## Source and representations

- Each logical page keeps its original artwork object and stable publication-page identity. Ordered pages drive reading order, story frames, page labels, reader spreads and physical leaf pairing.
- Chapter copy stays in the existing global rich story. Canvas frames, the source galley, PDF and 3D faces resolve that source. Capacity changes reflow words without storing displayed fragments.
- Masters reference ordinary editable artwork sheets. Page numbers, publication/chapter names and labels are derived at render time. Locked derived furniture is stripped before saving a page; editing the master updates its consumers.
- A sheet assembly references a publication, pairs its page faces into leaves, and derives caliper from stock. Opening, turned-leaf count and bend are viewing controls. Enclosure planes have authored physical dimensions, expression-driven poses and actual-size source crops, allowing covers, boards, spines and endpapers to reuse the existing paper/material/finish renderer.
- Canonical page and enclosure sources remain editable on the same Canvas. A consumed source does not become an extra default Table product. Explicit source instances remain available for Studio compositions.

## Delivery and acceptance

The implemented native workspace provides a floating page/spread navigator, actual page thumbnails, configurable creation, insertion/duplication/reordering/removal, chapter-source editing, mirrored margins, numbering, master editing and shared physical controls in Canvas and Table. Shared source, text Undo, camera and older-project boundaries remain the governing editing contracts; the exercised validation scope is recorded in [Publications](publications.md).

Reader-page output remains the default physical multipage PDF. Reader spreads and two-up folded-sheet output are separate derived arrangements with explicit order metadata and physical boxes. Blank signature padding requires an explicit option and never inserts source pages. Production ink composites and plates retain their original page path. No printer is contacted. Reader order and printer imposition serve different purposes; Adobe's [booklet imposition guidance](https://helpx.adobe.com/indesign/desktop/print/print-booklets/impose-documents-for-booklet-printing.html) and [booklet type guidance](https://helpx.adobe.com/ie/indesign/desktop/print/print-booklets/booklet-types.html) inform the folded-sheet checks. Native flow continues to use Apple's existing [layout manager and text containers](https://developer.apple.com/documentation/appkit/nslayoutmanager).

Two required authored studies are a twelve-page folded booklet and a finished hardbound publication with independent case artwork, interior chapters, endpapers, foil and blind relief. Acceptance requires actual closed/open/spread/reverse/detail renders, every page proof, source edits/reflow, native navigation/Undo, count/stock/opening variations, PDF order/scale checks, reopening and source-preservation checks. Those authored studies and retained physical comparison records are exercised through the existing public-MCP workflow. The final 52-page VARIOUS magazine adds exact parent-sheet stock/ink declarations, saddle/side-staple comparison and independently posed shared-source copies. Its completed native source/visual/output review and hash-pinned evidence are recorded in the [example validation](../examples/publications/various-quarterly/VALIDATION.md).

Physical binding strength, adhesive behavior, press calibration, paper stretch and machine operation are separate from the viewing and document model.
