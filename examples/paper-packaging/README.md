# Twelve editable paper and packaging studies

The twelve primary JSON files are complete `PlanarConstructionDefinition` sources for `form_construction create`; `07-liner-component.json` supplies the separate loose liner. They use the same parameter expressions, panels, physical cutouts, hinge trees, independent component roots and declared interiors available to any agent-authored model. They add no product registrations or application generators.

Open the included [Field — Twelve paper studies.form](<Field — Twelve paper studies.form>) using LAB’s **File → Open Project…**. The menu uses the app’s project importer. System-level file-open event delivery was unreliable in this native session; the delivered project was copied byte-for-byte into the persistent library and opened with public `form_open_project` instead.

The project contains all twelve studies on one Table, plus two modeled contents objects and one separate patterned liner. Inside artwork sources are editable on Canvas without appearing as extra loose objects on the Table. See the [validation report](../../docs/paper-packaging-validation-report.md) for measured coverage, native images and manufacturing limits.

```python
definition = json.loads(Path("examples/paper-packaging/04-two-piece-board-box.json").read_text())
call("form_construction", {"command": "create", "definition": definition})
```

Each file declares stock caliper in millimeters. Assign an editable stock profile, any bonded plies, outside/inside artwork and finishes using the ordinary paper/artwork commands after creation. A fresh physical paper source has a transparent artwork background so an unprinted area shows its actual stock. An opaque artwork background remains an explicit full-sheet printed color.

| Source | Physical construction | Specific review |
|---|---|---|
| `01-rsc-shipping.json` | Four body panels, glue seam and four top/bottom flaps | Major flap meeting line and actual board/tape allowance |
| `02-straight-tuck-carton.json` | Body seam, two bridge/tuck closures and four dust flaps | Tuck contact, upright panel art and caliper changes |
| `03-locking-mailer.json` | Double sidewalls with integral tongues, real floor slots, lid window and finite-width perforations | Slot alignment and mechanical retention need a prototype |
| `04-two-piece-board-box.json` | Ten independently placed rigid boards plus a separate apertured insert; lid components lift together and settle beside the base when open | Lid/base interference, referenced product orientation and insert position |
| `05-archival-clamshell.json` | Independent tray boards, cover boards and spine with articulated front cover | Cover clearance and actual hinge/covering specification |
| `06-commercial-envelope.json` | Front, two side bonds, bottom bond and independently opening flap | Registered front/back/inside printing, pocket depth and bond overlap |
| `07-invitation-envelope.json` | Envelope with independent opening flap and separate `07-liner-component.json` | Loose vellum-profile liner has its own physical caliper and editable pattern |
| `08-hang-tag.json` | Curved single panel with a real punch hole | Double-sided artwork, hole clearance, foil and blind emboss |
| `09-duplex-business-card.json` | Single card with contrasting bonded plies and independent front/back artwork | Authoritative summed caliper, visible ply edges, foil and deboss |
| `10-postcard.json` | Flat card with printed front and postal reverse | Divider, address rules and stamp zone remain editable |
| `11-folded-greeting-card.json` | Scored articulated cover/back | Upright cover, publisher imprint and inside greeting |
| `12-finished-invitation.json` | Cotton card with editable wording and ornamental vectors | Separate letterpress, blind emboss and foil masks |

## Replay through MCP

Build `build/LAB.app` using the repository's build instructions. Python 3 and `pdfinfo` are required for the validation scripts; the scripts use only the public native MCP bridge. From the repository root, this creates a separate library and socket without replacing an existing project:

```sh
paper_app="$PWD/build/LAB.app"
paper_output="$PWD/.local/validation/paper-packaging/replay"
paper_socket="/tmp/lab-paper-packaging-replay.sock"

python3 scripts/validate_paper_packaging.py --launch \
  --app "$paper_app" --socket "$paper_socket" --output "$paper_output"
python3 scripts/refine_paper_packaging.py \
  --app "$paper_app" --socket "$paper_socket" --output "$paper_output"
python3 scripts/check_paper_packaging.py --round replay \
  --app "$paper_app" --socket "$paper_socket" --output "$paper_output"
python3 scripts/render_paper_packaging.py \
  --app "$paper_app" --socket "$paper_socket" --output "$paper_output"
```

The seeder writes `report.json` with the actual project/object/source IDs. `refine_paper_packaging.py` makes the artwork refinements in one batch and preserves existing target IDs, stock, geometry and finishes; a matching second run makes no edits. The checker retains per-case baselines, temporary edit/Undo/Redo evidence, finite parameter cases, packets and reopen comparisons under `checks/replay/`. It verifies 3 mm bleed extents using test sheets 40 mm larger than the net in each axis. The renderer records actual native PNGs and capture metadata under `renders/`, including an overview, twelve case views and four reverse views. These output folders retain their source and binary provenance.

To continue an interrupted seed against its existing private library, use the same arguments with `--resume`; do not launch a second owner of the same socket. Checker rounds are resumable and `--round another-name` preserves a separate verification attempt. Reverse-view captures temporarily turn the actual parametric sheet and restore it afterward. Rendering saves Studio scenes and therefore can add presentation/history entries; run another named checker round afterward when proving the final saved presentation state.

`components` in source version 3 declares a root for each independent hinge tree. Its `anchor` is a canonical sheet point on that root. `position` is the assembled anchor in construction millimeters: X right, Y up, Z toward the viewer. `rotationDegrees` applies X, then Y, then Z to an initially upright source panel. Only root-pose expressions additionally receive `fold` and `opening` percentages. Fold 0 retains the original laid-out blanks; Fold 100 reaches the declared assembly. Opening can articulate a component without generating new source panels or changing the flat artwork. All components in one source share the stock; a differently materialized loose liner is a separate physical object.

An `interior` is an explicit usable rectangular volume attached to a component anchor. Its `origin`, `size` and optional rotation use that component's local millimeter frame. Its optional rectangular opening has a normal `axis`; width/height follow Y/Z for X, X/Z for Y, or X/Y for Z. Opening `origin` defaults to zero in those transverse coordinates. `form_paper preflight` with `contents_object_id`, `interior_id` and `clearance_mm` checks the actual referenced object's oriented bounds in this frame. The result identifies both revisions and distinguishes volume containment from opening cross-section. Flat-net extents never stand in for a usable interior.

These sources are editable prototype studies. Declared dimensions, rigid sharp-stock checks and sampled poses do not establish a continuous insertion path, crease compression, springback, lock strength, adhesive performance or a supplier-approved production specification. Finite-width perforation cutouts remove the stated material and retain physical bridges; they do not simulate tearing. Finish relief is shaded process intent, not pressed tooling geometry. The controlled supplier-template SVG is a LAB-authored acceptance fixture, not a commercial vendor approval. Inspect real output and a physical prototype before treating these assumptions as measured manufacturing instructions.
