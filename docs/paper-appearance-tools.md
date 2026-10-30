# Paper stock and artwork-linked finishes

`form_paper` uses the same saved declarations and undoable operations as the native controls. These capabilities apply to ordinary source-authored paper constructions as well as existing constructed envelopes and cartons; examples are not new product generators.

All physical values are millimeters. A displayed inch unit does not change the MCP wire units. Existing paper projects keep their appearance when the optional declarations are absent. A project using stock profiles, plies or finish assignments saves as schema 57.

## Stock and bonded plies

`stock_presets` returns seven **unmeasured visual examples** without requiring a project or object. Their names are descriptive, not manufacturer or measured-stock claims. `configure` accepts a partial stock declaration:

```json
{
  "command": "configure",
  "object_id": "PAPER_OBJECT_UUID",
  "parameters": {"caliper": 0.8},
  "stock": {
    "name": "Contrasting bonded stock",
    "profile": {
      "texture": "cotton",
      "color": "#F1EBDD",
      "roughness": 0.94,
      "textureScaleMM": 1.2,
      "textureDepthMM": 0.035,
      "opacity": 1
    },
    "plies": [
      {"name": "Dark back", "color": "#243C47", "thicknessMM": 0.45},
      {"name": "Warm front", "color": "#F1EBDD", "thicknessMM": 0.35}
    ]
  }
}
```

Use the actual declared construction parameter name in `parameters`; `caliper` is only this example's name. Legacy constructions use `stock`. A supplied ply array establishes the total caliper as its sum unless `thicknessMM` is explicitly supplied, in which case it must agree. The authored `stockThickness` expression must resolve to that same total. Update its parameters in the same call. The app rejects a mismatch without changing the accepted project and never rewrites an arbitrary expression to make it pass.

Ply order is **back to front**. Each ply has an optional stable `id`, name, color, caliper, optional GSM and optional surface profile. Bonding sheets is distinct from printing two faces. A translucent profile is an appearance description, not a calibrated transmission measurement. An existing `object.color` remains an explicit instance override; a stock profile does not silently remove it.

Profile textures are `smooth`, `cotton`, `coated`, `laid`, `linen`, `recycled` and `vellum`. A profile supports color, roughness, physical texture scale/depth and opacity. Partial profile updates preserve unspecified values; `profile:null` clears the optional description. `plies:null` returns to a monolithic stock at its currently declared caliper. Stock configuration follows the existing shared-construction family behavior. Finish assignments remain local to each physical owner.

`save_stock` captures the selected paper object's stock as an ordinary `Material.paperStock` snapshot in the existing Lab materials library. Optional `name` and `material_id` name or update that reusable record; an optional `stock` patch can describe a stock without first applying it. Saving a Lab stock does not change the project or add a document Undo.

`apply_stock` takes `object_id` and the saved `material_id`. Normal native material picking uses the same stock-application helper. The project receives a portable material snapshot and its physical stock in one Undo. A direct caliper parameter can be updated within its declared bounds; composed expressions require a matching parameter-and-stock `configure` call. Later Lab edits never rewrite assigned project snapshots. Explicitly applying a changed Lab version preserves an existing different project material under its old ID and creates a distinct local snapshot.

## Finishes follow editable artwork

Create a finish using canonical source artwork element IDs:

```json
{
  "command": "set_finish",
  "object_id": "PAPER_OBJECT_UUID",
  "finish": {
    "name": "Letterpress wording",
    "kind": "letterpress",
    "side": "outside",
    "elementIDs": ["EDITABLE_TEXT_UUID"],
    "depthMM": 0.06
  }
}
```

Kinds are `flatInk`, `letterpress`, `emboss`, `deboss`, `foil` and `screenPrint`. Optional properties include color, roughness, metallic fraction, opacity, enabled state, impression `depthMM` and raised `heightMM`. Flat ink has no relief; emboss uses height, deboss/letterpress use depth, screen ink uses height, and foil may combine its film height and impression. Native presentation uses surface shading for these relief declarations; it does not establish displaced tooling geometry.

Omitted values default to outside, zero relief, opacity 1 and enabled. The response's `finishes[].assignment.id` identifies the assignment. Pass that `id` in another `set_finish` call with only changed properties to update it without replacing its targets or order. `remove_finish` takes `finish_id` and removes one existing assignment. Each command is one Undo. Ordered assignments can coexist on one physical object.

Targets are attached to canonical source IDs, including editable text or groups. Changing wording, a path or its placement updates the live mask. Outside and inside target different registered source artworks. On a single flat card these correspond to front and back. Run `ensure_inside` before assigning an inside finish when that source is absent. The readable Canvas back view and the 3D surface retain the existing physical registration; these commands do not mirror, fit or scale artwork.

Images retain their original ink colors and may supply alpha masks for foil or relief. An explicit color override for `flatInk`, `letterpress` or `screenPrint` targeting a bitmap directly or through a group is currently rejected: an exact tinted raster ink plate is not implemented. Use original image colors (`color:null`) or an editable vector mask. This prevents native appearance and exported ink from silently disagreeing.

New assignments require existing IDs on the selected side. If later edits delete a target, the saved finish retains its missing IDs for repair and reports them. It never silently attaches to a replacement element. Moving artwork into another source can therefore require explicit finish reassignment.

## Inspection and production limits

`appearance` returns the stock, resolved caliper, ply order, assignments, source object IDs/revisions, resolved group targets, missing targets and review issues. `inspect` includes the same appearance report beside the construction/net/preflight. These calls do not change source or history. Source revisions identify canonical artwork bytes; rendering also depends on resolved fonts, styles, resources and material settings.

Unknown nested appearance fields, nonfinite values, wrong types, incompatible relief properties, invalid colors and mismatched calipers reject atomically. Locked physical owners cannot have finishes changed. Missing targets after later source edits are review warnings, not permission to erase the saved intent.

Paper packets should preserve this report and the complete source declarations. Native ink/foil/impression appearance, actual-size artwork and a declared depth are distinct from verified press output. Accurate tooling, trapping, registration, duplex feed/turn, adhesive thickness, bonding strength, crease performance and physical samples remain unverified unless separately generated and proved. The appearance report always exposes `manufacturingVerified:false` and describes relief as `surfaceShading`.

## Modeled contents and retained supplier templates

For a declared interior, `preflight` accepts `contents_object_id`, optional `interior_id` and nonnegative `clearance_mm`. The native host resolves the actual modeled bounds. Numeric `contents:{width,height,depth}` remains the legacy dimension-only check; it cannot be combined with a modeled object reference. A modeled fit report does not prove closure strength, flexible contents fit or an impression's displaced geometry.

`template_attach` retains an original self-contained SVG using `path`, explicit `instructions`, optional supplier `vendor`/`revision`, `technical_mapping:[{elementID,kind}]`, and optional `canonical_to_template:{a,b,c,d,tx,ty}` registration. Technical kinds are `cut`, `crease`, `perforation`, `glue`, `safety`, `bleed` and `instructions`. `template_inspect` verifies its retained source hash and reports geometry review. Fold interpretation remains separately editable and is not inferred or supplier-approved. Arbitrary PDF/Illustrator structures are not supported by this bounded path.

Exports declare optional `bleed_mm` (0–25) and `handoff` (`artwork_only`, `separate` or `registered_original`) explicitly. These choices do not imply that the app has verified the supplier's press, die, trapping or duplex workflow.
