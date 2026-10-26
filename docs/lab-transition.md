# LAB rename and environment transition

LAB is the application name. [A Working Thesis, version 2.0](lab-working-thesis-v2.md) is the next guiding product document alongside the earlier design and textile briefs. This change reorganizes existing capabilities around the project or object being made. It does not claim that the thesis’s future mechanisms, electronics, constraints or manufacturing systems already exist.

## Current user direction

The three primary project environments are **Form**, **Function**, and **Fabricate**. They are interconnected contexts for the same project, not sequential stages or different documents. Canvas and Table remain connected 2D/3D views within these contexts; split and separate-window use remain available.

**Keep Studio.** The user’s subsequent correction overrides the initial request to retire it. Studio remains a separate environment reached through a secondary icon in project navigation and the menu bar. It is not a fourth primary tab. Saved shots, lighting, surfaces, reference framing and presentation exports remain available.

- **Form:** visual/spatial design, type, vectors, references, materials, surfaces and composition.
- **Function:** existing dimensions, parametric components, source relationships, construction and cloth/assembly behavior, with technical context and the same editing operations.
- **Fabricate:** existing 3D-print preparation, artwork/physical-page output, sewing/cutting, embroidery, decoration and collection production workflows. Production tools operate on the existing source and assets.

## Compatibility contract

The product identity becomes LAB in the native app, Home, titles, menus, setup/help and MCP discovery. Internal Swift module names are not product navigation. Keep the current bundle identity, document type/extension, existing project/library location, Keychain service and bridge endpoint compatible so the rename cannot orphan saved data, permissions, credentials or connected clients. Expose LAB-named launcher/helper paths while retaining the old MCP helper and tool names as explicit compatibility interfaces. Prefer LAB environment variables while accepting the existing FORM variables. Do not rewrite saved user artwork or immutable historical production/render files to change their branding.

Navigation must preserve project source, selection, shared Undo, camera controls, source links and assets. Camera gestures and named-view framing keep their existing contract. The six current projects, including the user-edited MERIDIAN v02 reference/dial/mask, are preservation fixtures. No external AI calls or printer commands are introduced; sending or starting prints remains disabled.

## Delivery stages

1. Record the thesis, corrections, compatibility contract and active goal.
2. Implement application identity and compatible native/MCP packaging and paths.
3. Introduce the three primary environments, secondary Studio entry, reusable context panels and direct routes to existing technical/production capabilities.
4. Complete native labels/docs/setup and navigation lifecycle tests.
5. Run the full appropriate suite, sign/package the tested source, validate actual native navigation/MCP/restart on existing projects, and record evidence.

Commit meaningful coherent stages and push accepted work. The goal is complete when the structural transition is delivered and verified, not when the entire product thesis is implemented.
