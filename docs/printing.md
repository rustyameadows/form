# Local print preparation

FORM has a native print workspace, a persistent filament library, an official OrcaSlicer engine adapter, and a read-only Bambu P1S status adapter. **This version cannot upload files or start a print.** The user's instruction to avoid printing is enforced by the available UI and MCP operations.

## Native workflow

Select an object on the Table and click the printer icon or press `⌘P`. A dedicated sheet shows the object on the physical 256 × 256 mm P1S bed. Orbit and zoom directly, fit the bed, or focus the object.

Choose a complete object or a lamp's separate shade, stem, or base. The print transform is independent of the product design: rotate in 90° increments, change scale, and reset orientation. The mesh is centered and placed on the bed in millimeters. Validation checks build volume, actual triangle overlap with the P1S front-left exclusion region, nozzle/layer compatibility, filament diameter, and the P1S temperature limits.

Choose a saved printer and filament, then set layer height, infill percentage, wall count, supports, and brim. **Slice & preview** runs Orca locally in the background. The resulting layer slider shows extrusion paths, including interpolated arc previews, with time and filament estimates. Preview detail is bounded to 200,000 segments; this limit does not modify the actual G-code. Jobs can be cancelled.

Each preparation is saved inside the project:

```text
Exports/Print/<job-id>/
  model.stl          # binary STL, millimeters, printer Z-up
  machine.json      # resolved official Orca machine preset
  process.json
  filament.json
  Preparation.json  # object/component/settings and print_jobs_sent: 0
  Orca.log
  plate_1.gcode
  prepared.3mf      # sliced plate archive
```

Use **Show slice files** or **Export STL** to inspect the files. No connection credentials are included in these exports. Local slicing alone does not validate mechanical fit, material suitability, or a successful physical print.

## Official Orca engine

The UI is native SwiftUI/AppKit/SceneKit. FORM runs a separate, unmodified official `OrcaSlicer.app` through its CLI; it does not embed Orca's wxWidgets interface or link its C++ engine into the Swift app.

The tested engine is [OrcaSlicer v2.4.2](https://github.com/OrcaSlicer/OrcaSlicer/releases/tag/v2.4.2). Install it with:

```sh
bash scripts/install-orca.sh
```

The helper downloads the official universal Mac DMG, verifies SHA-256 `e15e7bb1b66214ec6e96b169b388004179c4f5f705effcdaf8c80d4992ee0366`, and extracts the untouched app to `.local/engines/OrcaSlicer.app`. This directory is ignored by Git. The helper can take a destination directory as its first argument.

An existing official installation can instead be selected in **Studio Library → Filaments & 3D printing → Slicing engine**. Engine discovery checks the saved path, `FORM_ORCA_APP_PATH`, a bundled helper location, `/Applications/OrcaSlicer.app`, the library's `Engines` directory, and the repository's `.local/engines` directory. Other releases may change CLI/profile behavior and require validation.

The adapter resolves inherited official BBL machine, process, and material presets, then overlays the chosen native controls. Each job has its own data directory. User post-processing hooks are not loaded. P1S nozzle profiles for 0.2/0.4/0.6/0.8 mm are recognized; end-to-end slices have been verified with the 0.4 mm profile.

OrcaSlicer is [licensed under AGPL-3.0](https://github.com/OrcaSlicer/OrcaSlicer/blob/v2.4.2/LICENSE.txt). Its binaries and profiles are not vendored or redistributed in this repository. Any future bundled distribution needs an explicit licensing and source-delivery review; the separate-process design is not a claim that distribution obligations disappear. No Bambu proprietary networking plugin is installed by FORM.

## Studio filament library

Open **Studio Library → Filaments & 3D printing → Filament library**. Four generic starter profiles cover PLA, PETG, and ABS. Add a spool and edit its name, manufacturer, polymer, color, diameter, density, nozzle/bed temperatures, maximum volumetric flow, remaining grams, cost per kilogram, and notes. Save explicitly. These are starting profiles, not manufacturer-qualified process settings.

Profiles live in shared `Studio.json`, outside individual projects. Per-object print configuration stores profile IDs. Existing materials/equipment are preserved during migration. Inventory is user maintained; preparing a slice does not subtract filament. AMS reports can be received by the status adapter, but automatic spool synchronization and multi-material job mapping are not implemented.

## Set up the local P1S

1. Keep the Mac and printer on a mutually reachable local network.
2. Open **Local printers** in the printing settings.
3. Enter its local IP/hostname and serial from its device settings. Confirm the actual nozzle and plate.
4. Enter the LAN access code directly into FORM's secure field. It is saved to macOS Keychain under `studio.form.printer`, keyed by printer profile ID. It is never returned by MCP or stored in project/Studio JSON.
5. Save the printer and choose **Test local connection**. If the certificate cannot be verified against the official printer CA and serial, independently verify the displayed SHA-256 fingerprint before trusting it.

The adapter opens TLS MQTT on port 8883, authenticates as `bblp`, subscribes to `device/<serial>/report`, merges telemetry deltas, acknowledges received QoS messages, and sends keepalive pings. It can display nozzle/bed temperatures, progress, state, and AMS metadata. It contains no MQTT publish operation and no FTPS uploader. Connecting does not publish a full-report request, so an idle printer may take time to push its first status update.

The physical P1S connection is **not yet verified**: its IP, serial, and locally entered code have not been supplied. There is no automatic LAN scan, cloud login, firmware change, or security-mode change. Availability depends on actual printer firmware and network configuration.

Bambu's [security whitepaper](https://cdn1.bambulab.com/trust-center/file/bambulab-security-whitepaper-en.pdf) describes local encrypted communication. Its [authorization announcement](https://blog.bambulab.com/firmware-update-introducing-new-authorization-control-system-2/) distinguishes status pushes from critical controls such as print start, temperatures, movement, and AMS changes. Future write/control support must follow the supported authorization route for installed firmware. FORM does not attempt to bypass it.

## MCP

The native workflow is available through `form_open_print`, `form_get_print_setup`, `form_set_print_options`, `form_slice`, `form_get_slice_status`, and `form_cancel_slice`. Filament discovery/editing uses `form_list_filaments` / `form_save_filament`. `form_list_printers` reports saved metadata and state; `form_connect_printer` uses credentials already saved locally. There is no upload, start, heating, or motion tool.

```json
{"name":"form_open_print","arguments":{"object_id":"<object UUID>"}}
{"name":"form_set_print_options","arguments":{"component":"Shade","layerHeight":0.2,"infillPercent":15,"wallLoops":2,"supports":false}}
{"name":"form_slice","arguments":{}}
```

Poll `form_get_slice_status` until `busy` is false, then inspect `validation_error`, outputs, layers, and estimates. `form_set_view` accepts `print_bed` and `print_object` for camera framing.

## Primary implementation references

- [Pinned Orca CLI implementation](https://github.com/OrcaSlicer/OrcaSlicer/blob/v2.4.2/src/OrcaSlicer.cpp)
- [Pinned official P1S 0.4 mm machine profile](https://github.com/OrcaSlicer/OrcaSlicer/blob/v2.4.2/resources/profiles/BBL/machine/Bambu%20Lab%20P1S%200.4%20nozzle.json)
- [Official Bambu P1S specifications](https://us.store.bambulab.com/products/p1s)
- [Public Bambu Studio device-management source](https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceManager.cpp)

The architecture follows primary sources and actual local engine execution. A passing local slice does not claim live printer compatibility; see [validation](validation.md).
