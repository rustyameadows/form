# FORM project status

As of October 26, 2026.

**FORM is a working native Mac alpha with substantial 2D, 3D and fabrication workflows. The complete product, typography and textile briefs are not finished.** The latest verified application integrates **portable artwork transfer (48) and physical page setup (49)**, with **983 optimized tests passing**: 640 core/graphics/IPC and 343 native tests, with no failures or skips. The installed signed application matches the tested source. See [integration evidence](evidence/transfer-page-native.json).

This report distinguishes features in that application from local candidates and research. Test totals are validation checkpoints, not a percentage of product completion.

## Current execution and GitHub state

- The goal service currently returns **no active goal**. The earlier Active label in the roadmap was stale as an execution indicator. The remaining requirements have not been completed or cancelled.
- The available record does not establish why the goal stopped being attached. There is no basis to report that it stopped because the app was finished.
- The two requested feature candidates are now integrated and accepted together. The current pass is integration and stabilization only; it does not start the remaining feature roadmap. Separate cloth and broader SVG research remain local.
- The application code is pushed to **codex/form-v0.1** in [draft pull request 1](https://github.com/rustyameadows/form/pull/1). It has not been merged. **main still contains the initial product brief and README**, so viewing main does not show the implementation.
- The ordinary library was restored after validation. All five saved projects and Studio settings matched their preservation snapshots. No print was sent or started.

## What works in the verified application

| Area | Implemented and verified | Important boundary |
| --- | --- | --- |
| Native project environment | Home previews, modular project packages, assets, autosave, Undo/Redo, iterations, linked variants and shared Studio records. | A complete release and clean-install acceptance pass remains ahead. |
| 3D Table and navigation | Continuous Table, parametric recipes and inspectors, selection/movement/groups, focus/isolation and stable named views. Four actual mouse directions preserve the expected axis and world-up frame; Perspective frames the whole project with or without selection. | Supported constructions remain recipe based. This is not a general solid-modeling or arbitrary garment-construction system. |
| Connected 2D and 3D surfaces | Freeform Canvas with notes, references, type and graphics; physical frames and linked object artwork; single, split and separate-window arrangements sharing state and Undo. | General curved-surface projection, engineered cross-panel continuity and broader dieline relationships remain incomplete. |
| Typography | Native rich text, installed fonts and replacement, actual font features/axes/glyphs, kerning, optical sizing, source-preserving superscript/subscript and genuine small caps, styles, language, lists, tabs, hyphenation and editable outlines. | Broader font/script and complex-document compatibility still needs acceptance work. Font files are not made portable automatically. |
| Vector and image editing | Bézier nodes/handles, compounds, live booleans/divide, gradients, stroke controls/expansion, nested masks, reusable components/swatches, image crop/replace/adjustments and physical DPI. | Portable cross-project Copy/Cut/Paste now carries supported assets, named resources and component/mask dependencies, with bounded validation and safe failed-Cut behavior. Variable-width strokes and fuller SVG interchange remain open. |
| Publications and print color | Linked stories, ordered physical pages, baseline grids, overset review, multipage booklet PDF, separate bleed/safe guides, vector page review, physical PDF boxes/crop marks, ICC conversion and declared CMYK/spot output for supported paints. | Master pages/running furniture, advanced paragraph keep controls, cross-references, imposition and broader production-color handling remain incomplete. |
| Rendering Studio | Saved named compositions, exact subjects, lighting/surface choices, reference framing, output pixel sizes and PNG/render records with Undo. | Calibrated materials, photorealistic output and archived simulated garment poses are not established. |
| 3D print preparation | Dedicated bed/settings/layer UI, component orientation/scale, persistent filament and printer libraries, and actual local Orca slicing with STL/G-code/3MF output. | Orca runs as a separate official app behind FORM's native UI. Physical P1S status is unverified; uploads and print-start commands are unavailable. |
| Fabric and merchandise | Bomber, tee, cap and tote studies; physical decoration placement; editable repeats/colorways and fabric specifications. | These are supported studies and blanks, not a complete apparel catalog or garment-fit system. |
| Sewing and cloth | Editable straight/curved pieces, allowances/notches/seams, cutting layouts, tiled actual-size patterns, a managed size/grade study and bounded pattern-derived pouch/cloth simulation. | No cloth self-collision or predictive fit is integrated. General garment assembly remains unfinished. |
| Embroidery and decoration | Actual running/satin/fill commands, underlay/ties, thread preview, DST and physical outputs; bounded HTV/DTF preparation and immutable packets. | Production digitizing/compensation, broader processes and verified physical sew-out/application remain incomplete. |
| Collection production | Explicit product/spare runs, once-counted attachments, purchase-versus-make estimates, declared stock/rates and frozen PDF/JSON/CSV/ZIP technical packets. | No automatic purchasing, inventory deduction, factory scheduling or complete manufacturing technical pack. |
| Codex workflow | 59 local MCP tools operate the same document operations as the native app. | The creative conversation stays in Codex. External AI model calls inside FORM are intentionally outside this version. |

The [AFFINITIES acceptance workflow](design-acceptance.md) demonstrates the credible-canvas foundation. [Character-form evidence](evidence/character-forms-native.json), [collection and Home evidence](evidence/collection-home-native.json), and [validation notes](validation.md) record the tested scope. Some older broad roadmap checkboxes contain already implemented subfeatures; they should not be read as a list of wholly missing systems.

## Local work that has not shipped

| Work | Current state | Required before it can count as shipped |
| --- | --- | --- |
| Stronger SVG admission | Prototype with 34 focused tests and rendered comparison. Shared parsing/work/resource limits are implemented only in the prototype. | Review and wire the stronger limits into native/MCP import, run full acceptance and ship. The existing workspace-destination rejection is fixed separately in the current application. |
| Cloth self-contact | Offline detection, scheduling/compiler and closest-feature/correction math checkpoints exist. Independent math and sanitizer tests pass. | Implement and verify accepted motion/contact response, lifecycle, performance and native integration. **No self-contact solver or completed physical time step has shipped.** |
| Reusable publication furniture | Proposed shared headers/footers and live folios. | Design, implement and validate. No production code exists for this slice. |

The isolated test totals overlap earlier suites and must not be added together. These remaining prototypes stay in the ignored local validation workspace. Transfer and page setup have passed their combined 983-test, installed MCP, native UI and process-reopen gates; the earlier isolated totals are historical.

## Stabilization results and practical limits

Failed Cut no longer deletes source, complete supported clipboard dependencies travel with artwork, and asynchronous Paste rejects a changed frame/project before editor handoff. Page output retains typography notices and cannot export stale review options. SVG import into the existing loose Canvas workspace now succeeds at physical scale. Focused regressions and packaged checks cover these repairs. No unresolved failure remains in this acceptance scope; that is not a claim that every product workflow is complete or free of defects.

| Priority | Current issue | Practical consequence |
| --- | --- | --- |
| Medium | SVG responsiveness near input limits needs the stronger shared limits from the prototype. | Existing SVG support should not be treated as arbitrary-complexity interchange. |

The most recently verified camera behavior follows the fixed [camera contract](camera-navigation.md): primary drag orbits, Shift-drag pans, and named Perspective/Top/Front views frame the whole project. The latest mouse checks passed. Later work must preserve those bindings and repeat the regression checks.

## The largest remaining product work

### Garments and the NASA showcase

The NASA study already has two bomber colorways, independent patch/label artwork, attached details and real generated embroidery output. **Its bomber is presentation geometry, not a jacket assembled from production cutting patterns.** The border and name-tape construction are partly concepts. Bomber pattern drafting, lining/closures, complete assembly instructions, calibrated fit and physical sew-out remain ahead. The cap supports conforming direct artwork; the specified embroidered-cap demonstration is incomplete.

The broader textile brief also needs supplier/user blank import and replacement, general shirt/jacket/pants blocks and body measurements, richer grading and fit/body-form workflows, darts/pleats/closures/linings, validated construction instructions, engineered prints and seam continuity, wider decoration/process compatibility, and production-ready patch/label construction. Existing repeats, skirt/size studies and pouch simulation are useful foundations rather than completion of those requirements.

### Publication and production

Linked stories and booklet output already work. Remaining publication work includes reusable furniture, page numbering, widow/orphan and keep controls, footnotes/cross-references, spreads/imposition and automatic page creation from overset. Separate page safety/bleed and explicit physical page output are now integrated; they do not complete the remaining publication requirements.

Production color still needs broader gradient/image/transparency and spot workflows, overprint/trapping/screening, comprehensive preflight and any claimed PDF/X certification. Textile production needs richer materials/process checks, purchasing/inventory/scheduling integration and complete technical packs. Software-generated outputs have not established physical manufacturing quality.

### Broader physical design and release quality

Extend beyond the current construction recipes, flat artwork links and supported garment regions. Complete the connected demonstrations for packaging, clocks, apparel and instructions under the current build, with actual source edits, outputs and reopen checks. Continue whole-workflow UI/performance work; passing bounded benchmarks is not a guarantee for every large document or collection.

A release still needs a clean installation/distribution check and an explicit supported-workflow acceptance pass. Current validation is local; this branch has no GitHub Actions workflow. The draft PR remains unmerged.

## Order for the next implementation work

1. **Completed in this stabilization pass:** integrate portable artwork transfer and page setup, repair clipboard lifecycle/workspace SVG defects, verify native/MCP/Undo/reopen, and deliver the tested source. The remaining items are future feature work.
2. **Fix import and finish core publication workflows:** stronger SVG parsing limits, reusable furniture and live folios, followed by the remaining typography/layout requirements.
3. **Develop the actual garment system:** collision response and cloth integration alongside real garment patterns, construction and the NASA bomber; keep mathematical prototypes distinct from working app behavior.
4. **Complete manufacturing and release acceptance:** broader process/color coverage, technical packs, end-to-end demonstrations and clean installation. Verify P1S status only when its local credentials are supplied; sending or starting prints remains disabled.

The unavailable P1S connection does not block the remaining software work. No completion percentage or delivery date is assigned here because the open items vary greatly in scope.

## Governing scope

The [original product brief](product-brief.md), [2D typography and vector specification](2d-design-typography-vector-spec.md), [textile brief](textiles-apparel-merchandise-spec.md), and the user's subsequent Canvas/Table, camera and print directions remain the scope. The [implementation roadmap](implementation-goal.md) retains detailed requirements; this status report is the current summary of delivery and execution state.
