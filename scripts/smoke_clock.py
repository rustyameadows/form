#!/usr/bin/env python3
"""Validate shared artwork, clock fabrication, and scoped rendering in a disposable library.

Run with FORM_LIBRARY_PATH inside .local. Pass --slice for local Orca preparation.
This script never connects to a printer or sends a print job.
"""
import argparse
from collections import Counter
import json
import math
import pathlib
import re
import statistics
import struct
import time
import uuid
import xml.etree.ElementTree as ET

from smoke_mcp import Client, OUTPUT, ROOT
from smoke_print import slice_and_check


def mesh_evidence(path):
    data = path.read_bytes()
    count = struct.unpack_from("<I", data, 80)[0]
    assert len(data) == 84 + count * 50
    assert count <= 8192, "The bounded dial mesh unexpectedly grew in complexity"
    edges, volume, valid = Counter(), 0.0, 0
    for index in range(count):
        values = struct.unpack_from("<12fH", data, 84 + index * 50)
        a, b, c = [tuple(round(v, 4) for v in values[i:i + 3]) for i in (3, 6, 9)]
        ab, ac = [b[j] - a[j] for j in range(3)], [c[j] - a[j] for j in range(3)]
        cross = (ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0])
        if sum(v * v for v in cross) < 1e-12:
            continue
        valid += 1
        for left, right in ((a, b), (b, c), (c, a)):
            edges[tuple(sorted((left, right)))] += 1
        volume += (a[0] * (b[1] * c[2] - b[2] * c[1]) + a[1] * (b[2] * c[0] - b[0] * c[2]) + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6
    assert all(n == 2 for n in edges.values()), Counter(edges.values())
    expected = math.pi * (120 ** 2 - 4 ** 2) * 6
    assert abs(abs(volume) - expected) / expected < 0.01, (volume, expected)
    return {"triangles": count, "nondegenerate_triangles": valid, "watertight_edges": len(edges), "volume_mm3": abs(volume)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slice", action="store_true", help="Run the official local Orca engine; no printer communication")
    args = parser.parse_args()
    client = Client()
    try:
        status = client.call("form_status")
        library = pathlib.Path(status["library_path"])
        assert library.resolve().is_relative_to((ROOT / ".local").resolve()), "Use an isolated FORM_LIBRARY_PATH inside .local"
        assert len(client.rpc("tools/list")["tools"]) == 41
        project = client.call("form_create_project", {"name": "Time, well spent / validation", "template": "clock"})
        clocks = [o for o in project["objects"] if o["recipeID"] == "clock"]
        clock = clocks[0]
        source = next(o for o in project["objects"] if o["id"] == clock["artworkSourceID"])
        assert len(clocks) == 2 and all(o["artworkSourceID"] == source["id"] and not o.get("artwork") for o in clocks)
        art = client.call("form_get_artwork", {"object_id": clock["id"]})
        assert art == source["artwork"]
        package = library / (project["id"] + ".form")
        before = {o["id"]: o["file"] for o in json.loads((package / "Manifest.json").read_text())["objects"]}
        signature = next(e for e in art["elements"] if e.get("name") == "Dial signature")
        signature["text"] = "FORM / 01"
        client.call("form_set_artwork", {"object_id": clock["id"], "artwork": art})
        after = {o["id"]: o["file"] for o in json.loads((package / "Manifest.json").read_text())["objects"]}
        assert all(before[o["id"]] == after[o["id"]] for o in clocks)
        assert before[source["id"]] != after[source["id"]]
        assert client.call("form_get_artwork", {"object_id": clocks[1]["id"]}) == art

        client.call("form_set_view", {"view": "table", "object_id": clock["id"]})
        time.sleep(0.3)
        current_camera = client.call("form_get_project")["camera"]
        for key in ("azimuth", "elevation"):
            assert current_camera[key] == project["camera"][key], "Scene creation overwrote the project's saved camera"
        builds = client.call("form_status")["renderer"]["geometry_builds"]
        durations = []
        for minute in range(10, 30):
            start = time.perf_counter()
            client.call("form_update_object", {"object_id": clock["id"], "parameters": {"minute": minute}})
            durations.append((time.perf_counter() - start) * 1000)
        assert client.call("form_status")["renderer"]["geometry_builds"] == builds, "Hand movement rebuilt the dial"
        client.call("form_update_object", {"object_id": clock["id"], "parameters": {"minute": 8}})
        client.call("form_update_object", {"object_id": clock["id"], "parameters": {"hour": 1.5}}, expect_error=True)

        stable = client.call("form_get_project")
        client.call("form_batch", {"operations": [
            {"name": "form_link_artwork", "arguments": {"object_id": clock["id"]}},
            {"name": "form_link_artwork", "arguments": {"object_id": clock["id"], "source_object_id": str(uuid.uuid4())}},
        ]}, expect_error=True)
        assert client.call("form_get_project") == stable
        iteration = client.call("form_duplicate_object", {"object_id": clock["id"], "mode": "iteration"})
        assert not iteration.get("artworkSourceID") and iteration.get("artwork")
        client.call("form_undo")
        assert len(client.call("form_get_project")["objects"]) == 3

        # Convert a numeral into ordinary editable paths through the physical consumer.
        numeral = next(e for e in art["elements"] if e.get("name") == "Hour 12")
        outlines = client.call("form_convert_to_paths", {"object_id": clock["id"], "element_ids": [numeral["id"]]})
        path = outlines["elements"][0]
        assert path["kind"] == "path" and path["path"]["contours"]
        node = path["path"]["contours"][0]["nodes"][0]
        client.call("form_edit_path", {"object_id": clock["id"], "element_id": path["id"], "node_ids": [node["id"]], "operation": "transform", "matrix": {"a": 1, "d": 1, "tx": 0.2}})
        client.call("form_undo")
        client.call("form_undo")
        assert client.call("form_get_artwork", {"object_id": source["id"]}) == art

        exports = {}
        for fmt in ("svg", "pdf", "png", "jpeg"):
            output = OUTPUT / f"clock-dial.{fmt}"
            exports[fmt] = client.call("form_export_artwork", {"object_id": clock["id"], "format": fmt, "dpi": 150, "path": str(output)})
            assert exports[fmt]["width_mm"] == 240 and exports[fmt]["height_mm"] == 240
        png = (OUTPUT / "clock-dial.png").read_bytes()
        assert struct.unpack(">II", png[16:24]) == (1417, 1417)
        pdf = (OUTPUT / "clock-dial.pdf").read_bytes()
        box = re.search(rb"/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)", pdf)
        assert box and all(abs(float(n) - 240 * 72 / 25.4) < 0.01 for n in box.groups())
        svg = (OUTPUT / "clock-dial.svg").read_text()
        assert 'surface-boundary' in svg and 'clip-rule="evenodd"' in svg and '<text' not in svg
        cut = OUTPUT / "clock-cut-profile.svg"
        client.call("form_export", {"object_id": clock["id"], "format": "svg", "path": str(cut)})
        circles = ET.parse(cut).findall(".//{http://www.w3.org/2000/svg}circle")
        assert [float(c.attrib["r"]) for c in circles] == [120, 4]

        client.call("form_open_project", {"project_id": project["id"]})
        assert client.call("form_get_artwork", {"object_id": clock["id"]}) == art
        assert json.loads((package / "Manifest.json").read_text())["project"]["schemaVersion"] == 3
        setup = client.call("form_open_print", {"object_id": clock["id"]})
        assert setup["component"] == "Dial" and setup["validation_error"] is None, setup
        assert all(abs(a - b) < 0.03 for a, b in zip(setup["mesh_size_mm"], [240, 240, 6])), setup
        assert not setup["print_commands_enabled"] and not setup["printer_status"]["connected"]
        for component in ("Hour hand", "Minute hand"):
            hand = client.call("form_set_print_options", {"component": component})
            assert abs(hand["mesh_size_mm"][2] - 0.8) < 0.01, hand
        client.call("form_update_object", {"object_id": clock["id"], "parameters": {"hands": 0}})
        client.call("form_open_print", {"object_id": clock["id"]})
        complete = client.call("form_set_print_options", {"component": "Complete object"})
        assert abs(complete["mesh_size_mm"][2] - 6) < 0.01, "Hidden display hands remained in the complete-object mesh"
        client.call("form_update_object", {"object_id": clock["id"], "parameters": {"hands": 1}})
        client.call("form_set_print_options", {"component": "Dial"})
        slice_result, mesh = None, None
        if args.slice:
            slice_result = slice_and_check(client, clock["id"], {"component": "Dial", "layerHeight": 0.2})
            mesh = mesh_evidence(pathlib.Path(slice_result["output_directory"]) / "model.stl")
        report = {"project_id": project["id"], "clock_id": clock["id"], "source_id": source["id"], "numeral_id": numeral["id"],
                  "exports": exports, "hand_edit_median_ms": statistics.median(durations), "hand_edit_p95_ms": sorted(durations)[18],
                  "hand_edit_geometry_rebuilds": 0, "mesh_size_mm": setup["mesh_size_mm"], "mesh": mesh, "slice": slice_result,
                  "print_jobs_sent": 0, "printer_connections_attempted": 0,
                  "checks": "41 tools; shared source persistence; immutable consumer files; hand edits reuse meshes; rollback; independent iteration; editable numeral outlines/nodes; all physical exports; schema 3 reopen; P1S bed validation"}
        (OUTPUT / "clock.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
