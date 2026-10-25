#!/usr/bin/env python3
"""Actual stitch generation through packaged local MCP. No machine/hardware calls.
Run with the isolated validation reader venv so DST is independently decoded.
"""
import copy
import json
import pathlib
import uuid
import xml.etree.ElementTree as ET
from smoke_mcp import Client, OUTPUT, ROOT
from verify_embroidery_dst import verify


def element(kind, x, y, width, height, color, name, **more):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=width,
                height=height, color=color, name=name, text="", fontSize=14, **more)


def contour(points):
    return dict(closed=True, nodes=[dict(id=str(uuid.uuid4()).upper(), anchor=dict(x=x, y=y)) for x, y in points])


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call("form_status")["library_path"])
        assert library.resolve().is_relative_to((ROOT / ".local").resolve()), "Use an isolated .local validation library."
        tools = c.rpc("tools/list")["tools"]
        assert len(tools) == 50
        update = next(t for t in tools if t["name"] == "form_update_object")
        assert "embroidery" in update["inputSchema"]["properties"]
        project = c.call("form_create_project", {"name": "ORBIT / Needle program"})
        patch = c.call("form_add_object", {"recipe_id": "textilePatch", "name": "ORBIT / three stitch methods",
                      "parameters": {"width": 80, "depth": 60, "corner": 3}, "material_id": "patch-twill"})
        running = element("path", 0, 0, 80, 60, "#C74C32", "Running / orbital arc", fillEnabled=False,
            path=dict(width=80, height=60, evenOdd=False, contours=[dict(closed=False, nodes=[
                dict(id=str(uuid.uuid4()).upper(), anchor=dict(x=8, y=10), outgoing=dict(x=18, y=2)),
                dict(id=str(uuid.uuid4()).upper(), anchor=dict(x=38, y=12), incoming=dict(x=28, y=20))])]))
        satin = element("line", 8, 23, 30, 0.1, "#E9DDB7", "Satin / constant-width centerline")
        group = element("group", 45, 8, 28, 40, "#285B8A", "Fill / clipped compound", contentSize=dict(x=28, y=40))
        mask = element("rectangle", 2, 1, 24, 36, "#FFFFFF", "Clipping boundary", parentID=group["id"])
        fill = element("path", 0, 0, 28, 40, "#285B8A", "Fill / preserved inner void", parentID=group["id"], clipID=mask["id"],
            path=dict(width=28, height=40, evenOdd=True, contours=[contour([(0,0),(28,0),(28,40),(0,40)]), contour([(8,12),(19,12),(19,26),(8,26)])]))
        artwork = dict(background="#FFFFFF", bleed=0, elements=[running, satin, group, mask, fill])
        c.call("form_set_artwork", {"object_id": patch["id"], "artwork": artwork})
        design = dict(hoopWidth=100, hoopHeight=100, margin=5, trimJumpThreshold=4, maximumStitches=100000,
            threads=[dict(name="Signal orange", color=running["color"], brand="FORM study", catalog="O-1"),
                     dict(name="Ecru", color=satin["color"]), dict(name="Orbital blue", color=fill["color"])],
            regions=[dict(id=str(uuid.uuid4()).upper(), elementIDs=[running["id"]], method="running", threadIndex=0, stitchLength=2),
                     dict(id=str(uuid.uuid4()).upper(), elementIDs=[satin["id"]], method="satin", threadIndex=1, stitchLength=4, spacing=0.5, satinWidth=3),
                     dict(id=str(uuid.uuid4()).upper(), elementIDs=[fill["id"]], method="fill", threadIndex=2, stitchLength=2.5, spacing=0.7, angle=23)])
        before = c.call("form_get_project")
        c.call("form_update_object", {"object_id": patch["id"], "embroidery": design})
        configured = c.call("form_get_project"); assert configured["schemaVersion"] == 25
        c.call("form_undo"); assert c.call("form_get_project") == before
        c.call("form_redo"); assert c.call("form_get_project") == configured
        snapshot_art = c.call("form_get_artwork", {"object_id": patch["id"]})
        c.call("form_update_object", {"object_id": patch["id"], "locked": True})
        locked = c.call("form_get_project")
        c.call("form_update_object", {"object_id": patch["id"], "embroidery": None}, expect_error=True)
        assert c.call("form_get_project") == locked
        c.call("form_undo"); assert c.call("form_get_project") == configured
        preflight = c.call("form_export_artwork", {"object_id": patch["id"], "format": "preflight"})
        assert preflight["stitches"] > 250 and preflight["verified_sew_out"] is False
        assert preflight["hoop_width_mm"] == 100 and preflight["margin_mm"] == 5
        outputs = {}
        for fmt in ["dst", "json", "svg"]:
            args = dict(object_id=patch["id"], format=fmt, embroidery_format=fmt,
                        path=str(OUTPUT / ("embroidery-orbit." + fmt)))
            outputs[fmt] = c.call("form_export_artwork", args)
            assert outputs[fmt]["source_digest"] == preflight["source_digest"]
            assert pathlib.Path(outputs[fmt]["path"]).stat().st_size == outputs[fmt]["bytes"]
        independent = verify(outputs["dst"]["path"], outputs["json"]["path"], outputs["dst"]["thread_sidecar_path"])
        program = json.loads(pathlib.Path(outputs["json"]["path"]).read_text())
        svg = ET.parse(outputs["svg"]["path"]).getroot()
        assert svg.attrib["width"] == "100.000mm" and svg.attrib["height"] == "100.000mm"
        assert json.loads(svg.find("{http://www.w3.org/2000/svg}metadata").text) == program
        assert len([n for n in svg if n.get("data-command") == "stitch"]) == preflight["stitches"]
        assert any(n.get("data-command") == "jump" and n.get("stroke-dasharray") for n in svg)
        assert c.call("form_get_project") == configured
        assert c.call("form_get_artwork", {"object_id": patch["id"]}) == snapshot_art
        sentinel = OUTPUT / "embroidery-approved.dst"; sentinel.write_bytes(b"APPROVED OUTPUT")
        for selector in [dict(roles=["stitch"]), dict(fabric_pattern_material="patch-twill"), dict(pattern_pieces=True)]:
            c.call("form_export_artwork", dict(object_id=patch["id"], format="dst", path=str(sentinel), **selector), expect_error=True)
            assert sentinel.read_bytes() == b"APPROVED OUTPUT"
        too_small = copy.deepcopy(design); too_small["hoopWidth"] = 20
        c.call("form_update_object", {"object_id": patch["id"], "embroidery": too_small})
        c.call("form_export_artwork", {"object_id": patch["id"], "format":"dst", "path":str(sentinel)}, expect_error=True)
        assert sentinel.read_bytes() == b"APPROVED OUTPUT"
        c.call("form_undo"); assert c.call("form_get_project") == configured
        c.call("form_edit_artwork", {"object_id":patch["id"], "command":"transform", "element_ids":[running["id"]], "translate_x":1})
        changed = c.call("form_export_artwork", {"object_id":patch["id"], "format":"preflight"})
        assert changed["source_digest"] != preflight["source_digest"]
        c.call("form_undo"); assert c.call("form_get_project") == configured
        c.call("form_open_project", {"project_id":project["id"]})
        reopened = c.call("form_export_artwork", {"object_id":patch["id"], "format":"preflight"})
        assert reopened["source_digest"] == preflight["source_digest"]
        assert c.call("form_get_artwork", {"object_id":patch["id"]}) == snapshot_art
        report = dict(project_id=project["id"], object_id=patch["id"], preflight=preflight, independent_reader=independent, outputs=outputs)
        path = OUTPUT / "embroidery-proof.json"; path.write_text(json.dumps(report, indent=2))
        print(json.dumps({"passed":True, "report":str(path), **independent}, indent=2))
    finally:
        c.close()

if __name__ == "__main__": main()
