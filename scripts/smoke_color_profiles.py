#!/usr/bin/env python3
"""Packaged local ICC workflow. Refuses to mutate an ordinary user library."""
import hashlib
import json
import pathlib
import re
import uuid
import zlib
from smoke_mcp import Client, OUTPUT, ROOT


def main():
    c = Client()
    try:
        status = c.call("form_status")
        library = pathlib.Path(status["library_path"]).resolve()
        assert library.is_relative_to((ROOT / ".local").resolve()), "Use a disposable .local library."
        tools = c.rpc("tools/list")["tools"]
        assert "form_color_profile" in {t["name"] for t in tools}
        profiles = c.call("form_color_profile")["profiles"]
        profile = next(p for p in profiles if p["model"] == "CMYK" and "Generic" in p["name"])
        project = c.call("form_create_project", {"name": "CHROMA / Print conditions"})
        sheet = c.call("form_add_object", {"recipe_id": "artboard", "name": "CHROMA / ICC color card",
            "parameters": {"width": 180, "depth": 130}})
        def element(kind, x, y, w, h, **values):
            result = dict(id=str(uuid.uuid4()).upper(), kind=kind, x=x, y=y, width=w, height=h,
                text="", fontSize=14, color="#243B46")
            result.update(values)
            return result
        title = element("text", 12, 12, 156, 20, text="CHROMA / Print studies", fontSize=24, typography={"fontName": "Georgia"})
        note = element("text", 12, 35, 156, 12, text="Editable source sRGB · intentional ICC output", fontSize=10,
            typography={"fontName": "Helvetica"})
        elements = [title, note]
        for i, color in enumerate(["#CC2610", "#137DA2", "#7C9C64", "#D3AD43"]):
            card = element("rectangle", 12 + i * 40, 57, 34, 38); card["color"] = color; elements.append(card)
            elements.append(element("text", 12 + i * 40, 99, 34, 8, text=color, fontSize=9, typography={"fontName": "Menlo-Regular"}))
        elements.append(element("text", 12, 116, 156, 8,
            text="180 × 130 MM / GENERIC CMYK CONVERSION STUDY", fontSize=8, typography={"fontName": "Helvetica"}))
        c.call("form_set_artwork", {"object_id": sheet["id"], "artwork": {"background": "#F7F3E8", "bleed": 0, "elements": elements}})
        product = c.call("form_add_object", {"recipe_id": "box", "name": "CHROMA / Linked color sample",
            "parameters": {"width": 180, "depth": 130, "height": 8}, "position": [210, 0, 0]})
        c.call("form_link_artwork", {"object_id": product["id"], "source_object_id": sheet["id"]})
        c.call("form_set_view", {"view": "table", "object_id": product["id"]})
        package = library / (project["id"] + ".form")
        def refs():
            return {o["id"]: o["file"] for o in json.loads((package / "Manifest.json").read_text())["objects"]}
        def export(fmt, label, **args):
            path = OUTPUT / (label + "." + fmt)
            return c.call("form_export_artwork", {"object_id": product["id"], "format": fmt, "path": str(path), "dpi": 150, **args})
        baseline = c.call("form_get_project"); old = refs()
        baseline_art = c.call("form_get_artwork", {"object_id": sheet["id"]})
        preview = export("png", "color-profile-source"); rgb_png = pathlib.Path(preview["path"]).read_bytes()
        renderer_before = c.call("form_status")["renderer"]
        assigned = c.call("form_color_profile", {"command": "set", "object_id": product["id"], "profile_path": profile["path"]})
        assert assigned["object_id"] == sheet["id"]
        assert {key for key in old if refs()[key] != old[key]} == {sheet["id"]}
        saved = c.call("form_get_project")
        source = c.call("form_get_artwork", {"object_id": sheet["id"]})
        reference = source["outputColorProfile"]
        assert saved["schemaVersion"] == 30 and reference["model"] == "CMYK"
        assert source["elements"] == baseline_art["elements"] and source["background"] == "#F7F3E8"
        assert hashlib.sha256((package / "Assets" / reference["asset"]).read_bytes()).hexdigest() == reference["sha256"]
        renderer_after = c.call("form_status")["renderer"]
        assert renderer_after["geometry_builds"] == renderer_before["geometry_builds"]
        preview = export("png", "color-profile-assigned-source")
        assert pathlib.Path(preview["path"]).read_bytes() == rgb_png
        c.call("form_color_profile", {"command": "set", "object_id": sheet["id"], "profile_path": "/missing-profile.icc"}, expect_error=True)
        assert c.call("form_get_project") == saved
        c.call("form_undo"); assert c.call("form_get_project") == baseline
        c.call("form_redo"); assert c.call("form_get_project") == saved
        outputs = {}
        for name, args in [("artwork", {}), ("roles", {"roles": ["print"]})]:
            result = export("pdf", "color-profile-" + name, **args); data = pathlib.Path(result["path"]).read_bytes()
            assert b"/N 4" in data and ("FORM-ICC-" + reference["sha256"]).encode() in data
            streams = []
            for match in re.finditer(rb"<<([^<>]*)>>\s*stream\r?\n(.*?)endstream", data, re.S):
                if b"FlateDecode" in match[1]:
                    try: streams.append(zlib.decompress(match[2]))
                    except zlib.error: pass
            assert any(re.search(rb"(?:[0-9.]+\s+){4}sc\b", s) for s in streams), "Expected actual four-component vector paint."
            outputs[name] = result
        assert c.call("form_get_project") == saved
        c.call("form_open_project", {"project_id": project["id"]})
        reopened = c.call("form_get_project")
        assert reopened["schemaVersion"] == 30 and reopened["objects"] == saved["objects"]
        report = dict(project_id=project["id"], sheet_id=sheet["id"], product_id=product["id"], profile=reference,
            exports=outputs, geometry_builds_before=renderer_before["geometry_builds"],
            geometry_builds_after=renderer_after["geometry_builds"], source_srgb_unchanged=True, native_profile_validation_pending=True)
        (OUTPUT / "color-profiles-report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        c.close()


if __name__ == "__main__":
    main()
