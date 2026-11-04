# Independent construction authoring

An authored construction is saved project data. Version 4 extends the existing planar source with independent cut pieces, material stocks, parent frames, physical joint plans, native control metadata and production formats. The native editor and `form_construction` use that same source; no application branch recognizes a named product or starter.

## Source and controls

`form_construction capabilities` returns the complete strict `definition_schema` and `starter_schema`. Existing version 1–3 sources remain supported. Version 4 retains the existing panel polygons, cutouts, hinges, joins, expressions, requirements and declared interiors.

Each `components` entry owns one physical cut piece: its `rootPanelID` and descendants connected by hinges. Separate boards, wrap blanks, liners, tape and inserts remain separate components. A component can declare independent `stock`, a parameter-driven `stockThickness`, `quantity`, `purpose`, an `enabled` 0/1 expression, `front`/`back` canonical artwork faces and `finishes`. Disabled alternatives retain their source identities. `groups` are reusable parent frames with parameter-driven XYZ position and rotation; components reference `groupID`.

`controls` travels with the source. It declares groups, parameter labels, explanations, numeric choices, optional `visibleWhen` conditions, derived measurements, an explicit `dimensionReferenceParameter` and named opening/explosion review poses. Native controls interpret this metadata without assigning meanings to parameter names. Visibility expressions resolve to zero or one. Measurements and physical artwork dimensions use closed source values. `fold`, `opening` and version-4 `explosion` are reserved presentation percentages, each 0–100.

`jointAttachments` references existing joins. Adhesive plans name both contact regions, exclusions and bond thickness. A region can name `edgeIndex` to address the real cut edge. Tape plans reference an actual cut-piece component and declare contact regions, physical width/length/overlap/end offsets, bond thickness and installation order. Staple plans declare entry and receiving faces, wire section, crown, legs, placement/count/spacing, penetration, termination, joint-gap and edge checks, tool access and the exact material layers present during installation. Preview and Apply validate engagement in the closed source; an exploded presentation does not detach the accepted manufacturing joint.

## Starter source data

Resource-backed entries are JSON files in `Sources/FormCore/Resources/ConstructionStarters/`. The catalog identifies entries by their `kind: "constructionStarter"` marker; names, categories, geometry and option semantics stay in data.

```json
{
  "kind": "constructionStarter",
  "version": 1,
  "id": "source-identifier",
  "name": "Source name",
  "summary": "Description",
  "symbol": "square.3.layers.3d",
  "definition": { "...": "complete planar construction" },
  "stock": { "...": "complete PaperStock" },
  "artworkSources": [
    {
      "id": "source UUID referenced by a component face",
      "name": "Editable artwork",
      "width": "namedWidthAlias",
      "height": "namedHeightAlias",
      "artwork": { "...": "complete canonical Artwork" },
      "artworkRegions": []
    }
  ]
}
```

Optional fields include `ownerID`, `materialID` and owner `artwork`. Artwork source width, height and physical-region expressions can reference saved construction parameters or derived dimension aliases. The importer creates regular editable Canvas source objects with physical dimension bindings; artwork coordinates, typography and image sizes are preserved. Each import remaps owner, artwork, layer and referenced UUIDs, so repeated imports are independent. Source text that happens to look like a UUID remains text. Import publishes the complete owner/source graph in one Undo transaction.

Strict tool and catalog validation rejects ignored or misspelled nested source, material, control, production, joint and artwork fields. Portable project loading remains forward compatible.

## Commands

| Command | Arguments | Result |
| --- | --- | --- |
| `starters` | Optional `starter_id` | Bounded catalog metadata, or the complete chosen source; no project edit |
| `add_starter` | Exactly one `starter_id` or inline `starter`; optional `name`, `position: [x,y,z]` | Fresh physical owner and all canonical artwork sources in one Undo; returns `object_id`, `artwork_source_ids`, revision and inspection |
| `inspect` | `object_id` | Complete saved source, current panel/component poses, parameters, per-part stock, source IDs, flat bounds, closed material envelope and closed joint review |
| `configure` | `object_id`, `definition`, optional `expected_revision` | Complete validated source replacement retaining the owner identity |
| `parameter` | `object_id`, `values`, optional `expected_revision` | Atomic parameter or presentation change from saved expressions |
| `adopt_parts` | `object_id`, `expected_revision`, optional reviewed `definition` | Explicit v1–3 independent-root adoption into version 4; stable panel/component/artwork identities remain |
| `create_part_artwork` | `object_id`, `component_id`, `side: outside/inside`, `expected_revision` | Physically dimension-bound transparent canonical artwork source; returns `artwork_source_id` |
| `validate_cases` | `object_id`, `cases`, optional `extrema` | Bounded read-only geometry/physical checks with explicit per-case outcomes |

Native source edits are staged. Preview renders actual candidate geometry and materials using a reconciled candidate project, without changing accepted geometry, artwork or history. Apply rechecks the captured project, owner and source revision and records one Undo. Cancel leaves the accepted model intact. Legacy sources retain their existing controls until adoption is explicitly previewed and applied.

Creating part artwork creates a new blank source; it does not extract or scale previously printed owner artwork. If that side already has a canonical source, its existing source is returned. All linked faces refer to normal Canvas artwork and use translation/cropping in millimeters.

The existing `form_get_artwork`, `form_edit_artwork` and `form_edit_path` accept `physical_frame: { surface_id, side }` for readable upright face coordinates. For version 4, a panel ID resolves its actual owning component and canonical front/back source. `component_id` selects that piece's complete flat pattern; if both identifiers are supplied, they must agree. Canvas and MCP consume the same physical projection descriptor, including source crop, upright rotation, independent reverse orientation, holes and stock. Edits inverse-map into that source in one Undo. Reading embedded registered reverse artwork is pure; its first actual edit can migrate that existing artwork to an independent source within the same Undo. A missing cut-piece reverse requests `create_part_artwork` rather than creating an unrelated owner-wide reverse atlas.

Native material controls also edit physical bonded plies and backing. Each layer retains its identity, caliper, color, texture and surface profile; its position in the back-to-front stack controls the exposed face and cut edge. A linked total-caliper expression rescales the declared layer proportions together. Layer edits never become printing ink or artwork.

Table joint and wire selections retain their physical owner, joint, attachment, fastener-row and optional individual-wire IDs. Picking a wire opens its source row in the same native joint editor; an explicit joint or row picker highlights its accepted Table targets. These are ephemeral navigation states and leave Canvas, cameras and Undo unchanged. `form_get_context` reports the scoped selection under `table.construction_target`; Canvas piece proofs include `component_id` in their ready-to-use artwork query.

## Production and presentation

`production` persists stock sheet/roll formats, assigned source pieces, grain/rotation rules, margins, spacing, waste allowance, quantity, technical labels, registration marks, bleed, nominal kerf assumptions, guides, assembly steps, dependencies and drawing views. Different physical stocks and calipers receive distinct material layouts. Cut files retain nominal geometry; declared kerf is recorded as a process assumption rather than silently applied.

For version 4, `form_paper preflight`, `layout` and `export` consume those saved formats. Global sheet/count/layout overrides are rejected. `export` supports SVG, PDF and construction packets. `packet_status` with `object_id` and `path` reviews the exported packet against the current source. Packet checks retain explicit failures, artwork-registration review and material assumptions.

Studio instances may independently override `paperPose: { foldPercent, openingPercent, explosionPercent }`. Omitted fields inherit the physical source. Several views of the same physical source can appear in one scene without copying or altering its canonical artwork, materials or construction.
