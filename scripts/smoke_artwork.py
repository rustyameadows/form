#!/usr/bin/env python3
"""Validate native artwork commands and real physical exports through MCP.

Creates a new typography/vector study in the running app. Prefer an isolated
FORM_LIBRARY_PATH. No model calls, printer connections, or fabrication jobs.
"""
import json
import pathlib
import re
import struct
import uuid

from smoke_mcp import Client, OUTPUT


def element(kind, x, y, width, height, **options):
    return {"id": str(uuid.uuid4()), "kind": kind, "x": x, "y": y,
            "width": width, "height": height, "text": "", "color": "#292D2C",
            "fontSize": 14, **options}


def main():
    client = Client()
    try:
        project = client.call("form_create_project", {"name": "Type & form"})
        fonts = client.call("form_list_fonts", {"query": "Georgia"})["families"]
        assert fonts and any(face["name"] == "Georgia" for family in fonts for face in family["faces"])
        features = client.call("form_font_features", {"font_name": "Georgia"})
        assert features["missing"] is False and features["features"]
        frame = client.call("form_add_object", {"recipe_id": "artboard", "name": "Soft geometry / 8 × 10", "parameters": {"width": 203.2, "depth": 254}})
        title = element("text", 17, 43, 175, 65, text="Soft\ngeometry.", fontSize=54,
                        typography={"fontName": "Georgia", "tracking": -0.5, "leading": 57})
        label = element("text", 18, 18, 170, 12, text="FORM / EXPLORATIONS IN TYPE AND SHAPE", fontSize=8,
                        typography={"fontName": "HelveticaNeue-Medium", "tracking": 1.2})
        circle = element("ellipse", 110, 136, 68, 68, color="#D45A37", gradient={"kind": "linear", "start": {"x": 0, "y": 0}, "end": {"x": 1, "y": 1}, "stops": [
            {"id": str(uuid.uuid4()), "offset": 0, "color": "#D45A37"},
            {"id": str(uuid.uuid4()), "offset": 1, "color": "#E3BE7C"}]})
        square = element("rectangle", 18, 138, 62, 62, color="#849381", cornerRadius=3,
                         stroke={"color": "#292D2C", "width": 0.3, "cap": "round", "join": "round"})
        hole = element("ellipse", 36, 155, 25, 25, color="#849381")
        footer = element("text", 18, 225, 168, 12, text="A place for ideas to become things. / 01", fontSize=9,
                         typography={"fontName": "HelveticaNeue"})
        artwork = {"background": "#F2EDE1", "bleed": 3, "unit": "in", "gridSpacing": 10,
                   "snapEnabled": True, "guides": [{"id": str(uuid.uuid4()), "axis": "x", "position": 18}],
                   "elements": [label, title, square, hole, circle, footer]}
        client.call("form_set_artwork", {"object_id": frame["id"], "artwork": artwork})
        result = client.call("form_boolean_artwork", {"object_id": frame["id"], "element_ids": [square["id"], hole["id"]], "operation": "subtract"})
        assert result["elements"][0]["kind"] == "path"
        assert len(result["elements"][0]["path"]["contours"]) >= 2
        current = client.call("form_get_artwork", {"object_id": frame["id"]})
        client.call("form_edit_artwork", {"object_id": frame["id"], "command": "replace", "elements": [{**title, "opacity": 2}]}, expect_error=True)
        assert client.call("form_get_artwork", {"object_id": frame["id"]}) == current
        second = client.call("form_add_object", {"recipe_id": "artboard", "name": "Outlined / editable glyphs", "parameters": {"width": 203.2, "depth": 254}, "position": [280, 0, 0]})
        client.call("form_set_artwork", {"object_id": second["id"], "artwork": current})
        outlined = client.call("form_convert_to_paths", {"object_id": second["id"], "element_ids": [title["id"]]})
        assert outlined["elements"] and all(item["kind"] == "path" for item in outlined["elements"])
        saved = client.call("form_get_artwork", {"object_id": second["id"]})
        assert next(item for item in saved["elements"] if item["id"].lower() == title["id"].lower())["hidden"] is True
        exports = {}
        for fmt in ("svg", "pdf", "png", "jpeg"):
            path = OUTPUT / f"soft-geometry.{fmt}"
            exports[fmt] = client.call("form_export_artwork", {"object_id": frame["id"], "format": fmt, "path": str(path), "dpi": 150, "outline_text": True})
            assert path.stat().st_size > 200
        svg = (OUTPUT / "soft-geometry.svg").read_text()
        assert '<text' not in svg and 'width="203.2mm"' in svg and '<path' in svg
        png = (OUTPUT / "soft-geometry.png").read_bytes()
        assert struct.unpack(">II", png[16:24]) == (1200, 1500)
        pdf = (OUTPUT / "soft-geometry.pdf").read_bytes()
        box = re.search(rb"/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)", pdf)
        assert box and abs(float(box[1])-576)<0.01 and abs(float(box[2])-720)<0.01
        client.call("form_open_project", {"project_id": project["id"]})
        assert client.call("form_get_artwork", {"object_id": second["id"]}) == saved
        client.call("form_set_view", {"view": "artwork", "object_id": frame["id"], "element_ids": [title["id"]]})
        report = {"project_id": project["id"], "frame_id": frame["id"], "outline_frame_id": second["id"], "title_id": title["id"], "exports": exports, "tools": len(client.rpc("tools/list")["tools"]), "checks": "installed fonts/features, exact 8x10 frame, rich typography, gradients, editable boolean paths, invalid-edit rollback, shaped text outlines with retained source, all artwork export formats, physical PDF and raster dimensions, save/reopen"}
        (OUTPUT / "artwork.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
