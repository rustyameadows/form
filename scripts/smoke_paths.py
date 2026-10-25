#!/usr/bin/env python3
"""Exercise real native path commands, linked variants, and physical outputs.

Use a disposable FORM_LIBRARY_PATH. No hardware or external model calls.
"""
import json
import uuid

from smoke_mcp import Client, OUTPUT
from smoke_artwork import element


def node(x, y, **handles):
    return {"id": str(uuid.uuid4()), "anchor": {"x": x, "y": y}, **handles}


def main():
    client = Client()
    try:
        assert len(client.rpc("tools/list")["tools"]) == 43
        project = client.call("form_create_project", {"name": "Curve atelier"})
        frame = client.call("form_add_object", {"recipe_id": "artboard", "name": "Lines with intent / 8 × 10", "parameters": {"width": 203.2, "depth": 254}})
        group = element("group", 18, 40, 165, 60, name="Transformed typography", contentSize={"x": 165, "y": 60}, rotation=-9,
                        affine={"a": 1, "b": 0, "c": 0.12, "d": 1, "tx": 0, "ty": 0})
        title = element("text", 0, 0, 165, 60, text="Lines with\nintent.", fontSize=43, parentID=group["id"],
                        typography={"fontName": "Georgia", "tracking": -0.5, "leading": 46})
        anchors = [node(0, 35, outgoing={"x": 27, "y": -20}),
                   node(75, 40, incoming={"x": 45, "y": 105}, outgoing={"x": 105, "y": -15}),
                   node(160, 50, incoming={"x": 125, "y": 110})]
        curve = element("path", 20, 122, 160, 80, name="Editable gesture", fillEnabled=False,
                        path={"width": 160, "height": 80, "evenOdd": False, "contours": [{"closed": False, "nodes": anchors}]},
                        stroke={"color": "#C65E3D", "width": 1.5, "cap": "round", "join": "round"})
        header = element("text", 18, 18, 170, 10, text="FORM / CURVE ATELIER / 01", fontSize=8,
                         typography={"fontName": "HelveticaNeue-Medium", "tracking": 1})
        footer = element("text", 18, 225, 170, 14, text="A curve is a decision you can keep making.", fontSize=9,
                         typography={"fontName": "HelveticaNeue"})
        artwork = {"background": "#F2EDE1", "bleed": 3, "unit": "mm", "elements": [group, title, curve, header, footer]}
        client.call("form_set_artwork", {"object_id": frame["id"], "artwork": artwork})
        variant = client.call("form_duplicate_object", {"object_id": frame["id"], "mode": "variant", "name": "Linked gesture"})
        base = {"object_id": frame["id"], "element_id": curve["id"]}

        def edit(operation, ids=None, **args):
            return client.call("form_edit_path", {**base, "operation": operation, "node_ids": ids or [], **args})

        inserted = edit("insert", [anchors[0]["id"]], t=0.37)["selected_nodes"]
        assert len(inserted) == 1
        split = edit("split", inserted)["selected_nodes"]
        assert len(split) == 2
        edit("join", split)
        edit("reverse")
        edit("reverse")
        saved = client.call("form_get_artwork", {"object_id": frame["id"]})
        current = next(e for e in saved["elements"] if e["id"].lower() == curve["id"].lower())
        assert len(current["path"]["contours"]) == 1
        assert len(current["path"]["contours"][0]["nodes"]) == 4
        assert client.call("form_get_artwork", {"object_id": variant["id"]}) == saved
        client.call("form_edit_path", {**base, "operation": "split", "node_ids": [anchors[0]["id"]]}, expect_error=True)
        assert client.call("form_get_artwork", {"object_id": frame["id"]}) == saved
        client.call("form_undo")
        client.call("form_redo")
        assert client.call("form_get_artwork", {"object_id": frame["id"]}) == saved
        outputs = {}
        for fmt in ("svg", "pdf", "png"):
            path = OUTPUT / f"curve-atelier.{fmt}"
            outputs[fmt] = client.call("form_export_artwork", {"object_id": frame["id"], "format": fmt, "path": str(path), "dpi": 150})
        client.call("form_open_project", {"project_id": project["id"]})
        assert client.call("form_get_artwork", {"object_id": frame["id"]}) == saved
        client.call("form_set_view", {"view": "artwork", "object_id": frame["id"], "element_ids": [title["id"]]})
        report = {"project_id": project["id"], "frame_id": frame["id"], "variant_id": variant["id"],
                  "title_id": title["id"], "group_id": group["id"], "path_id": curve["id"], "inserted_node_id": inserted[0],
                  "original_nodes": [n["id"] for n in anchors], "exports": outputs,
                  "checks": "43 MCP tools, cubic insertion/split/join/reversal, invalid-edit rollback, linked artwork variants, undo/redo, physical exports, save/reopen, transformed native text setup"}
        (OUTPUT / "paths.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        client.close()


if __name__ == "__main__":
    main()
