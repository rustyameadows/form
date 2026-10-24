#!/usr/bin/env python3
"""Validate local print preparation through real MCP + official OrcaSlicer.

Requires a running FORM app and the optional Orca engine. Creates a disposable
validation project and filament. Never connects to, uploads to, or starts a printer.
"""
import json
import pathlib
import struct
import time
import zipfile

from smoke_mcp import Client, OUTPUT


def slice_and_check(client, object_id, options):
    setup = client.call("form_open_print", {"object_id": object_id})
    assert setup["engine_available"], "Install the official engine first: bash scripts/install-orca.sh"
    setup = client.call("form_set_print_options", options)
    assert setup["validation_error"] is None, setup
    client.call("form_slice")
    deadline = time.monotonic() + 180
    while True:
        result = client.call("form_get_slice_status")
        if not result["busy"]:
            break
        assert time.monotonic() < deadline, "Local slicing exceeded the smoke-test timeout"
        time.sleep(1)
    assert result["validation_error"] is None, result
    assert result["layers"] > 0 and result["estimated_time"] and result["filament_grams"], result
    assert result["print_commands_enabled"] is False
    assert result["printer_status"]["connected"] is False, "Run this test without a live printer connection"
    directory = pathlib.Path(result["output_directory"])
    stl = (directory / "model.stl").read_bytes()
    triangles = struct.unpack_from("<I", stl, 80)[0]
    assert len(stl) == 84 + 50 * triangles and triangles > 0
    assert (directory / "plate_1.gcode").stat().st_size > 100
    with zipfile.ZipFile(directory / "prepared.3mf") as archive:
        assert any(name.endswith(".gcode") for name in archive.namelist())
    assert json.loads((directory / "Preparation.json").read_text())["print_jobs_sent"] == 0
    return result


def main():
    client = Client()
    try:
        tools = client.rpc("tools/list")["tools"]
        assert not any(word in tool["name"] for tool in tools for word in ("start_print", "upload", "heat_printer"))
        project = client.call("form_create_project", {"name": "Print preparation validation"})
        filament = client.call("form_save_filament", {"filament": {"name": "Validation PLA", "polymer": "PLA", "color": "#D45A37", "remainingGrams": 850}})
        assert any(item["id"] == filament["id"] for item in client.call("form_list_filaments")["result"])
        client.call("form_save_filament", {"filament": {"name": "Invalid", "nozzleTemperature": 999}}, expect_error=True)
        cube = client.call("form_add_object", {"recipe_id": "box", "name": "20 mm test cube", "parameters": {"width": 20, "height": 20, "depth": 20, "corner": 0}, "material_id": "vermillion"})
        setup = client.call("form_open_print", {"object_id": cube["id"]})
        before = setup["configuration"]
        client.call("form_set_print_options", {"layerHeight": 1}, expect_error=True)
        assert client.call("form_get_print_setup")["configuration"] == before
        cube_result = slice_and_check(client, cube["id"], {"filamentID": filament["id"], "layerHeight": 0.2})
        assert all(abs(size - 20) < 0.01 for size in cube_result["mesh_size_mm"])
        print("Cube: valid millimeter STL, sliced 3MF, G-code, layers and estimates.", flush=True)
        lamp = client.call("form_add_object", {"recipe_id": "lamp", "name": "Hollow shade test", "material_id": "vermillion", "parameters": {"height": 200, "shadeHeight": 60, "shadeDiameter": 100, "topDiameter": 40}})
        shade_result = slice_and_check(client, lamp["id"], {"component": "Shade", "filamentID": filament["id"], "layerHeight": 0.2})
        client.call("form_set_view", {"view": "print_object"})
        current = client.call("form_get_project")
        assert current["printSetups"][lamp["id"]]["component"] == "Shade"
        report = {"project_id": project["id"], "cube": cube_result, "shade": shade_result, "print_jobs_sent": 0, "printer_connections_attempted": 0}
        (OUTPUT / "printing.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
