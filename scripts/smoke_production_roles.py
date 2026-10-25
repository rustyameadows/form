#!/usr/bin/env python3
"""Packaged MCP proof of shared print/manufacturing roles. No hardware calls."""
import copy
import json
import pathlib
import re
import shutil
import struct
import subprocess
import uuid
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT, ROOT


def element(kind, x, y, width, height, **values):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y,
                width=width, height=height, text="", fontSize=14,
                color="#203D34", **values)


def contour(points):
    return dict(id=str(uuid.uuid4()).upper(), closed=True,
                nodes=[dict(id=str(uuid.uuid4()).upper(), anchor=dict(x=x, y=y)) for x, y in points])


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call("form_status")["library_path"])
        assert library.resolve().is_relative_to((ROOT / ".local").resolve()), "Use an isolated .local validation library."
        tools = c.rpc("tools/list")["tools"]
        assert len(tools) == 50
        assert "roles" in next(t for t in tools if t["name"] == "form_export_artwork")["inputSchema"]["properties"]
        project = c.call("form_create_project", {"name": "PRESS / Separate by intent"})
        sheet = c.call("form_add_object", {"recipe_id": "artboard", "name": "PRESS / Production master",
            "parameters": {"width": 200, "depth": 140}, "position": [-130, 0, -120]})
        title = element("text", 15, 14, 170, 24, name="PRESS / Editable wordmark")
        title.update(text="PRESS", fontSize=52, typography={"fontName": "HoeflerText-Regular", "kerningMode": "metrics"})
        subtitle = element("text", 15, 42, 170, 8)
        subtitle.update(text="ONE SOURCE / FIVE PRODUCTION CHANNELS", fontSize=7,
                        typography={"fontName": "Menlo-Regular", "tracking": 0.7})
        group = element("group", 15, 56, 110, 45, name="Shared clipping study",
                        contentSize={"x": 110, "y": 45})
        mask = element("path", 0, 0, 110, 45, name="Compound mask", parentID=group["id"], productionRole="guide")
        mask["path"] = dict(width=110, height=45, evenOdd=True,
            contours=[contour([(0, 0), (110, 0), (110, 45), (0, 45)]),
                      contour([(20, 12), (36, 12), (36, 30), (20, 30)])])
        printed = element("rectangle", 0, 0, 55, 45, name="Print / shared hole", parentID=group["id"], clipID=mask["id"])
        printed["color"] = "#A35F3C"
        cut = element("rectangle", 60, 4, 46, 37, name="Cut / independent geometry", parentID=group["id"],
            clipID=mask["id"], productionRole="cut", fillEnabled=False,
            stroke={"color": "#285B8A", "width": 0.35})
        score = element("line", 15, 108, 170, 0.1, name="Score / fold reference", productionRole="score",
            stroke={"color": "#A35F3C", "width": 0.3, "dash": [3, 2]})
        stitch = element("rectangle", 145, 57, 40, 44, name="Stitch / seam reference", productionRole="stitch", fillEnabled=False,
            stroke={"color": "#417469", "width": 0.35, "dash": [1, 1]})
        engrave = element("text", 15, 120, 100, 8, name="Engrave / serial", productionRole="engrave")
        engrave.update(text="FORM / STUDY No. 01", fontSize=8, typography={"fontName": "Menlo-Regular"})
        guide = element("line", 100, 9, 0.1, 122, name="Guide / center", productionRole="guide",
            stroke={"color": "#8A9B8D", "width": 0.25, "dash": [1, 2]})
        c.call("form_set_artwork", {"object_id": sheet["id"], "artwork": {
            "background": "#F4F0E5", "bleed": 0,
            "elements": [title, subtitle, group, mask, printed, cut, score, stitch, engrave, guide]}})
        product = c.call("form_add_object", {"recipe_id": "box", "name": "PRESS / Printed oak edition",
            "parameters": {"width": 200, "depth": 140, "height": 10}, "material_id": "oak", "position": [130, 0, 100]})
        c.call("form_link_artwork", {"object_id": product["id"], "source_object_id": sheet["id"]})
        package = library / (project["id"] + ".form")
        def references():
            return {o["id"]: o["file"] for o in json.loads((package / "Manifest.json").read_text())["objects"]}
        old = references()
        c.call("form_edit_artwork", {"command": "production", "object_id": product["id"], "element_ids": [title["id"]], "role": "print"})
        assert {key for key in old if old[key] != references()[key]} == {sheet["id"]}
        baseline = c.call("form_get_project")
        assert baseline["schemaVersion"] == 22
        c.call("form_edit_artwork", {"command": "production", "object_id": sheet["id"], "element_ids": [group["id"]], "role": "engrave"})
        grouped = c.call("form_get_project")
        art = c.call("form_get_artwork", {"object_id": sheet["id"]})
        assert next(e for e in art["elements"] if e["id"] == group["id"])["productionRole"] == "engrave"
        assert all(not e.get("productionRole") for e in art["elements"] if e.get("parentID") == group["id"])
        c.call("form_edit_artwork", {"command": "production", "object_id": sheet["id"], "element_ids": [cut["id"]], "role": "print"}, expect_error=True)
        assert c.call("form_get_project") == grouped
        c.call("form_undo"); assert c.call("form_get_project") == baseline
        command = {"command": "production", "object_id": product["id"], "element_ids": [cut["id"]], "role": "print"}
        invalid = dict(command, role="unknown-role")
        c.call("form_batch", {"operations": [
            {"name": "form_edit_artwork", "arguments": command},
            {"name": "form_edit_artwork", "arguments": invalid}]}, expect_error=True)
        assert c.call("form_get_project") == baseline
        c.call("form_update_object", {"object_id": sheet["id"], "locked": True})
        locked = c.call("form_get_project")
        c.call("form_edit_artwork", command, expect_error=True)
        assert c.call("form_get_project") == locked
        c.call("form_undo"); assert c.call("form_get_project") == baseline
        roles = ["print", "cut", "score", "stitch", "engrave"]
        exports = {}
        for fmt in ["svg", "pdf"]:
            exports[fmt] = c.call("form_export_artwork", {"object_id": product["id"], "format": fmt,
                "roles": roles, "path": str(OUTPUT / ("press-production." + fmt))})
            assert exports[fmt]["roles"] == roles
            assert exports[fmt]["width_mm"] == 200 and exports[fmt]["height_mm"] == 140
        tree = ET.parse(exports["svg"]["path"])
        svg = tree.getroot(); assert svg.attrib["width"] == "200.0mm" and svg.attrib["height"] == "140.0mm"
        layers = [n for n in svg if n.get("data-form-role")]
        assert [n.attrib["data-form-role"] for n in layers] == roles
        metadata = json.loads(svg.find("{http://www.w3.org/2000/svg}metadata").text)
        assert metadata["roles"] == roles and not metadata["stitch_program"]
        ids = [n.attrib["id"] for n in svg.iter() if "id" in n.attrib]
        assert len(ids) == len(set(ids))
        for node in svg.iter():
            for value in node.attrib.values():
                for ref in re.findall(r"url\(#([^\)]+)\)", value): assert ref in ids
        info = shutil.which("pdfinfo")
        assert info, "Poppler pdfinfo is required to verify physical PDF pages."
        pdf = subprocess.run([info, exports["pdf"]["path"]], capture_output=True, text=True, check=True).stdout
        assert re.search(r"Pages:\s+5", pdf)
        size = re.search(r"Page size:\s+([\d.]+) x ([\d.]+) pts", pdf)
        assert abs(float(size[1]) - 200 * 72 / 25.4) < 0.002
        assert abs(float(size[2]) - 140 * 72 / 25.4) < 0.002
        for role in ["print", "cut"]:
            result = c.call("form_export_artwork", {"object_id": sheet["id"], "format": "png", "roles": [role],
                "dpi": 150, "path": str(OUTPUT / ("press-" + role + ".png"))})
            data = pathlib.Path(result["path"]).read_bytes()
            assert data[:8] == b"\x89PNG\r\n\x1a\n"
            width, height = struct.unpack(">II", data[16:24])
            assert abs(width - 200 * 150 / 25.4) < 1 and abs(height - 140 * 150 / 25.4) < 1
            exports[role] = result
        legacy = c.call("form_export_artwork", {"object_id": sheet["id"], "format": "svg", "path": str(OUTPUT / "press-legacy-print.svg")})
        old_svg = pathlib.Path(legacy["path"]).read_text()
        assert "data-form-role" not in old_svg
        assert "layer-" + cut["id"] not in old_svg and "layer-" + guide["id"] not in old_svg
        assert "layer-" + printed["id"] in old_svg
        assert c.call("form_get_project") == baseline
        c.call("form_open_project", {"project_id": project["id"]})
        assert c.call("form_get_project") == baseline
        c.call("form_set_view", {"view": "artwork", "object_id": sheet["id"], "element_ids": [group["id"]]})
        report = dict(project_id=project["id"], source_id=sheet["id"], product_id=product["id"], group_id=group["id"],
            print_id=printed["id"], cut_id=cut["id"], roles=roles, exports=exports, pdfinfo=pdf)
        (OUTPUT / "production-roles-report.json").write_text(json.dumps(report, indent=2))
        (OUTPUT / "production-roles-baseline.json").write_text(json.dumps(c.call("form_get_project"), indent=2))
        print(json.dumps({k: v for k, v in report.items() if k not in ["exports", "pdfinfo"]}, indent=2))
    finally:
        c.close()


if __name__ == "__main__":
    main()
