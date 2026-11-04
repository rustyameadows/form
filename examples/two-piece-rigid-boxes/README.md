# CASK / COLLECT: two-piece separate-board study

This is editable project/library data. There is no box generator, named category or project-specific geometry in application code. `generate_starter.py` emits the bundled portable `constructionStarter` using generic planar cut pieces, per-piece material/face mappings, parent groups and anchored board-joint attachments.

The native **Add object → Construction starters** flow and public `form_construction` `add_starter` command import the same source. The bundled ID is `two-piece-setup`. Import creates the physical assembly and five canonical covering/lining/insert artwork sources as one undoable action. Source identities are remapped for each import. Standalone parameter variants also resize the owner fallback stock to the resolved root caliper, preserving any bonded ply ratios; independently stocked piece declarations remain separate.

Run the deterministic authoring and independent source checks:

```sh
python3 examples/two-piece-rigid-boxes/generate_starter.py
python3 examples/two-piece-rigid-boxes/verify_geometry.py
python3 examples/two-piece-rigid-boxes/test_starter_authoring.py
```

`variants.json` records parameter deltas and measured dimensions for the six acceptance families. Stapled construction has separate bare and covered checkpoints. Use `--check` to validate without writing, or `--snapshots` to emit full `variants/` working snapshots. The generator and parameter deltas are their authority; full snapshots are unnecessary for normal regeneration. From Python, `variant_starter(id)` returns a complete portable source and `add_variant(call, id, position)` performs one public MCP edit through the caller's ordinary LAB app. Neither importing the module nor building its data opens LAB, changes a project, renders, exports or sends hardware commands.

The examples are:

1. Oat paper, taped floor-to-wall seams and both halves unlined.
2. Independently lined base and lid; the base uses a wall band and separate face patch.
3. Spruce backed bookcloth with contrasting ivory lining and explicit fabric turn-ins.
4. Bare supported floor-to-wall staples, then the same receiving route under actual covering and slotted crown-leveling backing.
5. Mixed paper and cloth halves, one unlined, with physical overlap stop ledges.
6. Independent base/lid floor/wall calipers, inset base floor, a deeper lid and changed dimensions/fit.

Each half has five independent rigid boards. A complete cross wrap is one connected 17-face cut piece: exterior face, four outer wings, four edge traversals, four turn-ins and four relieved corner tabs. The alternative is a connected 21-face wall band with an adjustable front seam plus its separate exterior-face patch. Paper and backed fabric alternatives retain separate stock and pattern declarations while sharing canonical artwork. The fabric is an actual two-ply stock, with paper backing and woven face.

Liners are independent floor/top and four wall pieces. They stop short of tape and turn-ins; disabling a lining option removes its material and quantities while preserving its identities and source. Tape is a folded strip with two actual contact regions. Staple legs pass from the bare floor underside through the floor and into real wall material; this route intentionally rejects inset-floor boards. Installation order, tool access, termination and edge criteria are source data. Covered crowns have a physical slotted leveling backing rather than an invented empty gap.

Finished dimensions include local covering, corner/seam, tape, lining, adhesive and wire buildup. Cross-wrap tab buildup differs by axis. A band seam makes the front/back envelope asymmetric, so the closed lid is centred on that finished envelope. The lid seat resolves the actual local lining/tape/board ceiling under the base rim. Axial headspace, overlap, reveal, running clearance and insert clearance remain separate. Named presentation poses move the lid as one subassembly and do not change source dimensions or flat artwork.

The physical outside dimension reference includes enabled overlap stops and axial shims. The separate overlap-region body envelope drives lid fit, so stops below the sliding region do not artificially enlarge the lid. Stop reach grows with the actual lid rim, running clearance and declared seating land.

The production data declares independent stock formats, physical piece quantities, source-specific optional assembly steps, seam/turn-in guides, closed/raised/removed/exploded drawings and two sections. Technical guides have no print role and no implied machine operation. Material layouts partition actual stock/caliper/plies and never move canonical artwork or resize type. The lid's foil title and raised seal target stable canonical artwork IDs.

The Python checks cover source budgets, all retained flat polygons and cutouts, hinge attachment, actual posed adhesive contact and tape-region coverage, finished-dimension/clearance/seating arithmetic, pose invariance, stock-format ownership and translation-only artwork anchors. The independent 3D check also measures actual stock/wire envelopes and finds real coplanar seating-face intersections for all cases, maximum running clearance with locked overlap, outside-held stops and outside-held axial shims. They complement native strict decoding, actual board-staple engagement, save/reopen/Undo checks, construction-packet inspection and repeated real app render review. A passing offline check alone does not establish visual fidelity or manufactured fit.

Reference dimensions, dry adhesive layers, backed-cloth ratio, texture scale, turn-in allowances and stapler access remain explicit prototype assumptions. Stock compression, staple performance, adhesive strength and the desired sliding feel require physical samples. No printing, cutting, motion or heating is performed by these examples.
