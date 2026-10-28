# Starter object library

The library starts a design with a useful object and keeps the source choice reversible. **Add object → Object library…** opens editable starters, the reference catalog, and work examples. The **Gift shop / Working blanks** Home template starts two tees, a hoodie, a cap, a beanie, a bandana and a tote.

The supplied `Design_Form_Reference_Library.xlsx` is imported as reference data: 211 forms, 26 material/option groups and eight work examples. Original IDs, construction families, distinctions, URLs and source notes are retained in `Sources/FormCore/Resources/ObjectReferences.json`. Source notes describe the references; they are not agent instructions. The workbook is unchanged. Regenerate the resource with `python3 scripts/import_object_reference_library.py /path/to/Design_Form_Reference_Library.xlsx`.

There are 28 editable starters: 13 textile items and 15 paper/packaging items. Unsupported catalog constructions remain explicitly reference only. The library does not substitute a solid box for a carton with closures or imply that a product reference supplies a manufacturing model. Work examples retain alternative components as alternatives; they are browseable references rather than automatically assembled packages.

## Product identity and depiction

Nine starters propose named real products: BELLA+CANVAS 3001, AS Colour 5080 and 5030, Independent SS4500 and IND420XD, YP Classics 6245CM and 1501KC, AS Colour Carrie Tote 1001, and Printful's All-Over Print Bandana. Each object retains a portable product and reference snapshot, a selection reason, source date and depiction note. Source identity remains available without dominating the object name.

All garment geometry is approximate and uses concept measurements. The hoodie is a flat body with long sleeves, a laid-out open hood and pouch pocket; the beanie has a flat crown and turned cuff; the bandana is flat hemmed cloth. These are editable presentation shapes, not reconstructed supplier garments, sewing patterns or cloth simulations. Tee and tote reuse the existing native meshes. The dad cap reuses the generic curved crown; its panel count and crown proportions do not reproduce the referenced six-panel cap. Region bounds describe the preview surface and are not provider-approved decoration limits.

The [6245CM product page](https://www.flexfit.com/hat/yp-classics-classic-dad-cap), [1501KC product page](https://www.flexfit.com/hat/beanie-cuffed-knit-cap), [BELLA+CANVAS 3001 page](https://www.bellacanvas.com/product/3001/Unisex-Jersey-Short-Sleeve-Tee.html), and [Printful bandana page](https://www.printful.com/custom/collections/halloween/all-over-print-bandana) were consulted during implementation on October 26, 2026. The [AS Colour Heavy Tee](https://ascolour.com/heavy-tee-5080/) and [Carrie Tote](https://ascolour.com/carrie-tote-1001/) product pages were also reviewed on that date. Known reference fabric, weight, fit and sizes are stored separately from display materials and preview proportions. Other catalog links retain the workbook's October 25 reference date. No general claim of supplier verification is made. Size charts, color-specific fabric composition and production templates still require selection. Preview fabric thickness, hoodie fleece and bandana side length are authored assumptions; GSM is not converted into thickness.

## Commitment and changing blanks

- **Concept:** a useful form, without an active commitment to a blank.
- **Proposed blank:** a named product chosen as a reversible starting point.
- **Chosen blank:** the user has decided to design around that product. This changes commitment, not geometry accuracy or production readiness.
- **Custom variation:** dimensions, material selection or product identity changed. The original product remains a reference. Reapply a starter to return to its proposed proportions.

Change a blank through its inspector or `form_object_library replace`. A compatible swap retains the object ID, placement, custom name, artwork/source links, decoration offsets, rotations and physical artwork dimensions. The previous selection stays in an alternatives list. A replacement that would put attached artwork outside a region rejects atomically. Cross-construction replacements, locked objects and linked variant families reject; create an independent iteration before changing a linked family's blank. Each successful change has one shared Undo step.

Design source and existing production plans/jobs remain independently owned. There are no live stock, price, shipping, provider-variant or ordering connections in this starter library. There is no “production checked” toggle. Choosing a product does not verify measurements or approve an order.

## Agent access and storage

`form_object_library` accepts `list`, `get`, `examples`, `add`, `replace` and `state`. Read commands work without a project. List supports word search, domain, `ready_only`, offset and limit; get accepts a starter `entry_id` or catalog `reference_id`. Add/replace/state support shared native Undo and atomic `form_batch` rollback. Add positions use millimeters. `form_textile_zones` discovers preview regions on the new garments. Add independent `textilePrint` decorations to author physically sized artwork.

Schema 51 stores optional `ProductObject.librarySelection` snapshots. Older objects remain unchanged and decode without source records. Saved snapshots do not resolve product identity from the current bundled catalog. The resource bundle is included in the packaged app.

## Parallel LAB transition

This work lives on `codex/starter-library` in the managed `starter-object-library` worktree. The adjacent **Add Form product brief** chat is implementing LAB identity and Form/Function/Fabricate navigation, with Studio retained separately. The initial five library paths were moved out of the shared checkout after exact-content checks; naming work was preserved. No running user projects or production devices are changed for this feature.

Internal Swift modules, tool prefixes and document identifiers remain compatible. New UI says “Object library” and “Library source.” Integration overlaps are small additions in `StudioViews.swift` (sheet and Add menu), `StudioStore.swift` (presentation state), `Panels.swift` (inspector), `Model.swift` (optional snapshot/schema), schema readers in `Repository.swift` and `ArtworkTransferBundle.swift`, `Operations.swift`, `MCP.swift`, `Package.swift` and `scripts/build.sh` (resource packaging). When integrating the LAB rename, retain the FormCore resource bundle copy in the renamed app and keep the new sheet reachable from Add object. No changes to the three-environment architecture or Studio navigation are required here.

## Native visual proof

[Library browser](images/object-library/browser.png) and [working assortment](images/object-library/assortment.png) are captured from the actual SwiftUI browser and SceneKit renderer. The starter action remains visible while details scroll.

## Validation

The optimized suite passes 1,002 tests: 652 core/graphics and 350 native app tests. Coverage includes every starter, reference/example integrity, exact source snapshots, compatible swaps, atomic bounds rejection, shared Undo/Redo, native autosave, mesh reuse, physical-region orientation and portable artwork from schema 51 projects. Existing featured study ordering is preserved.

The signed release also passes `scripts/smoke_object_library.py` through its actual 60-tool packaged bridge. This verifies bundled-resource loading, read-only catalog access, the seven-object assortment, product snapshots, physical decoration preservation, Undo/Redo, choice/custom transitions and saved reopen. The script launches and closes only its own app process with a disposable library and unique local socket. It does not use the ordinary app instance or send hardware commands.

Reproduce with:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -c release
bash scripts/build.sh release
python3 scripts/smoke_object_library.py
```
