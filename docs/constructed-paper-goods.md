# Constructed paper goods · LAB 0.4

The [guiding brief](constructed-goods-vision.md) separates the purpose of work from its representation. One paper construction supplies the assembled geometry, identified panels, folds, glue joins, flat artwork coordinates and production outline.

## Start with a study

**Sun studies / Fold & print** now starts a white, uncoated paper envelope for twenty 8 × 10 inch cyanotype sheets. Its back is flat, its body has one side glue seam, its bottom is bonded, and its top opens independently. The blue typography and original leaf illustration remain editable vectors. The white eggshell appearance is an original material cue inspired by the requested Superfine direction, not a measured manufacturer profile. Choose the actual paper and prove its caliper, grain and crease behavior before production.

**STILL / Construct a carton** starts a cosmetics straight-tuck carton with four body panels, one side glue seam, four dust flaps and separate tuck closures. Outside graphics and a registered inside message have independent editable sources. A bottle provides a scale study; retention and inserts are not inferred.

Existing saved four-sided sleeves remain unchanged. `form_paper` offers an explicit, undoable **convert** operation: it preserves the old front artwork's physical size, translates it into the new front panel, retains the original linked source and flags a placement review. It does not silently replace older projects.

## Purpose and representation

| Environment | Paper workflow | Existing fabric workflow |
| --- | --- | --- |
| Form | Artwork, typography, physical paper tint and linked panel/dieline composition. | Original editable graphics, material appearance and supported decoration regions. |
| Function | Internal dimensions, caliper, allowances, flaps, fold review, opening, joins and anchored construction notes. | Original pieces, seam allowances, cut copies, grain, notches, seam correspondence, assembly declarations and cloth controls. |
| Fabricate | Stock declaration, quantity, physical sheet layout, preflight and separate print/cut/crease files. | Cutting templates, explicit tiled sheets, material layouts, embroidery/decoration and revision-linked jobs. |

**Panels**, **Dieline** and **Sheet layout** remain available across all three environments. The Table stays alongside them in split view. Switching purposes or representations does not move source artwork, change dimensions or reset the camera.

Panels are linked crops of the same flat artwork. Select a card to identify its panel in the model; double-click or choose **Edit selected panel in dieline** to edit that region in the native vector editor. Dieline in Form retains the normal drawing/type tools and editable elements, with generated construction overlays. Function uses a construction review; Fabricate uses a production review. Neither substitutes a second design document.

Selecting an actual panel on the Table identifies that panel in the flat review. Function also exposes identified folds and attaches notes to panels/folds, retaining the originating view. Notes whose source edges disappear remain recorded and receive a review warning.

## Fold and opening

**Fold** moves the complete rigid panel construction between flat and assembled. **Opening** articulates only the top closing and dust flaps. The body, side seam and bottom stay fixed when the top opens. Changing either pose retains the mesh and texture resources.

Panel surfaces have actual caliper, softened cut edges, outside/inside material slots and a bounded original paper texture. These are rigid panel previews; crease-adjacent bending, springback, adhesive behavior and physical closure tolerances need prototype verification.

Construction changes preserve artwork at its original physical coordinates. A change to panel geometry raises a placement-review warning instead of stretching the design. Apply the construction, inspect the affected panels/bleed, then acknowledge the review through `form_paper` once placement is checked.

## Inside artwork

Creating the inside source is explicit and adds one Undo step. It is an ordinary independent artwork sheet bound to the paper object. Side/view switches do not create or modify that source.

Both sources use registered flat-net coordinates. The inside review is labelled accordingly; it does not infer a printer's feed or duplex turn. Source typography and transforms remain editable. Prove the selected inside orientation and duplex registration on the actual production setup.

## Prepare local files

Use **Print / ⌘P** on a paper object to open its Fabricate sheet review. This does not send a job. Use the Fabricate controls to choose sheet dimensions, margins, spacing and prototype quantity. The conservative layout retains grain orientation, does not rotate or scale blanks, and reports insufficient stock.

Available outputs:

- **Cut & crease SVG:** millimeter geometry with separately named cut and crease groups, with the selected artwork side clipped to the construction.
- **Sheet proof PDF:** actual physical page dimensions, showing the stock appearance, artwork and production lines. Print at actual size to review the construction; keep production guides separate from final artwork printing.
- **Production packet:** independent outside and available inside artwork SVGs, cut/crease SVG, outside/inside sheet proofs, the construction and layout JSON, and a production record with source identity, assumptions and artifact SHA-256 hashes.

Outputs are exclusive new files/folders. Existing files and authoritative source/asset directories are protected. A packet captures the current accepted revision; later source edits do not rewrite it. Current proof/artwork clipping is the cut boundary; final production bleed/trapping, printer color certification, kerf/tooling and machine execution are not inferred by this prototype workflow.

MCP layout supports up to 500 copies; native prototype preparation/export is bounded to 64 copies and 64 sheets. The local tool never sends or starts fabrication.

## Agent workflow

Inspect the construction and its stable targets:

```json
{"command":"inspect","object_id":"…"}
```

Open linked views without editing the project:

```json
{"command":"view","object_id":"…","representation":"dieline","split":true,"panel_id":"front","inside":false}
```

Change the working construction through one Undo operation:

```json
{"command":"configure","object_id":"…","parameters":{"width":216,"height":275,"depth":12,"stock":0.35,"opening":100}}
```

`preflight` accepts optional measured `contents`; `layout` accepts physical sheets/margins/gap/count; `annotations` adds or removes anchored notes. `ensure_inside` creates the editable inside source if needed. `export` writes SVG, PDF or a packet to a new absolute path. Invalid edits retain the previous accepted source.

The [implementation acceptance](constructed-goods-implementation.md) and project evidence record the tested build and native review results. Supported fabric constructions remain the existing bounded pattern/assembly/cloth features; this reorganization does not establish calibrated garment fit or a complete garment factory workflow.
