#!/usr/bin/env python3
"""Schema31 actual cloth runtime proof through the packaged local MCP.
Refuses ordinary libraries. No printer, slicer, network or machine operation.
"""
import hashlib
import json
import math
import pathlib
import time
from smoke_mcp import Client, OUTPUT, ROOT


def vector(point):
    return tuple(point[key] for key in ("x", "y", "z"))


def sub(a, b): return tuple(x-y for x, y in zip(a, b))
def add(a, b): return tuple(x+y for x, y in zip(a, b))
def scale(a, s): return tuple(x*s for x in a)
def dot(a, b): return sum(x*y for x, y in zip(a, b))


def triangle_distance(point, a, b, c):
    """Independent closest distance: interior projection or one of three edges."""
    ab, ac, ap = sub(b, a), sub(c, a), sub(point, a)
    d00, d01, d11 = dot(ab, ab), dot(ab, ac), dot(ac, ac)
    denominator = d00*d11-d01*d01
    candidates = [a, b, c]
    if denominator > max(1e-20, d00*d11*1e-12):
        v = (d11*dot(ap, ab)-d01*dot(ap, ac))/denominator
        w = (d00*dot(ap, ac)-d01*dot(ap, ab))/denominator
        if min(1-v-w, v, w) >= 0:
            candidates.append(add(a, add(scale(ab, v), scale(ac, w))))
    for p, q in ((a, b), (b, c), (c, a)):
        axis = sub(q, p)
        t = min(1, max(0, dot(sub(point, p), axis)/dot(axis, axis))) if dot(axis, axis) else 0
        candidates.append(add(p, scale(axis, t)))
    return math.sqrt(min(dot(sub(point, p), sub(point, p)) for p in candidates))


def verify_mesh(snapshot, definition):
    mesh = snapshot["mesh"]
    positions = [vector(p) for p in mesh["positionsMm"]]
    assert len(positions) == len(definition["mesh"]["restPositionsMm"])
    assert mesh["uv"] == definition["mesh"]["uv"]
    assert mesh["triangles"] == definition["mesh"]["triangles"]
    assert all(math.isfinite(value) for point in positions for value in point)
    assert all(abs(dot(vector(n), vector(n))-1) < 1e-7 for n in mesh["normals"])
    for pin in definition["mesh"]["pins"]:
        assert max(abs(x-y) for x, y in zip(positions[pin["vertex"]], vector(pin["targetMm"]))) < 1e-7
    maximum_penetration = 0.0
    for collider in definition["colliders"]:
        center = vector(collider["centerMm"])
        if collider["kind"] == "sphere":
            radius = collider["radiusMm"]
            for t in mesh["triangles"]:
                d = triangle_distance(center, positions[t["a"]], positions[t["b"]], positions[t["c"]])
                maximum_penetration = max(maximum_penetration, radius-d)
        else:
            normal = vector(collider["normal"])
            normal = scale(normal, 1/math.sqrt(dot(normal, normal)))
            maximum_penetration = max(maximum_penetration, *(-dot(sub(p, center), normal) for p in positions))
    assert maximum_penetration <= 1e-5, maximum_penetration
    return {"vertices": len(positions), "triangles": len(mesh["triangles"]), "physical_collider_penetration_mm": maximum_penetration}


def main():
    c = Client()
    try:
        library = pathlib.Path(c.call("form_status")["library_path"])
        assert library.resolve().is_relative_to((ROOT/".local").resolve()), "Use an isolated .local validation library."
        c.discover(["form_cloth", "form_add_object", "form_open_print"])
        project = c.call("form_create_project", {"name": "NASA / Flexible materials lab", "template": "blank"})
        drape = c.call("form_add_object", {"recipe_id": "clothPanel", "name": "NASA / Supported fabric drape", "material_id": "flight-sage", "parameters": {"resolution": 8}, "position": [0, 0, 0]})
        tote = c.call("form_add_object", {"recipe_id": "clothTote", "name": "NASA / Two-panel seam study", "material_id": "linen", "parameters": {"resolution": 8}, "position": [440, 0, 0]})
        for item in (drape, tote):
            c.call("form_set_artwork", {"object_id": item["id"], "artwork": {"background": "#E5D8B5", "bleed": 0, "elements": [
                {"id": "6F2FD132-128C-4DCC-91CA-998089E6A412", "kind": "text", "x": 22, "y": 45, "width": 170, "height": 60, "text": "NASA", "color": "#213D5C", "fontSize": 58},
                {"id": "2B6BFC0D-DB14-44BE-A227-92221F4CF029", "kind": "text", "x": 22, "y": 135, "width": 170, "height": 35, "text": "MATERIALS LAB\nCLOTH STUDY / 31", "color": "#C05A37", "fontSize": 13}
            ]}})
        c.call("form_set_view", {"view": "table", "object_id": drape["id"]})
        def cloth(command, item=drape, **extra):
            return c.call("form_cloth", dict(command=command, object_id=item["id"], **extra))
        label=c.call("form_add_object", {"recipe_id":"textileLabel", "name":"Material-point label", "parameters":{"width":42,"depth":22},"position":[700,0,0]})
        cloth("attach",item=label,surface_object_id=tote["id"],u=0.7,v=0.25,panel=0,offset_mm=2)
        label_before=cloth("get",item=label)["placement"]
        definition = cloth("get")["definition"]
        assert c.call("form_get_project")["schemaVersion"] >= 31
        initial = cloth("snapshot")["mesh"]["positionsMm"]
        before = c.call("form_get_project")
        baseline_camera = before["camera"]
        frame = cloth("step", frames=30)
        assert frame["diagnostics"]["completedFrames"] == 30
        assert frame["diagnostics"]["status"] == "stopped"
        snapshot = cloth("snapshot")
        assert snapshot["mesh"]["positionsMm"] != initial
        verified = verify_mesh(snapshot, definition)
        assert c.call("form_get_project") == before, "Runtime motion wrote project/history or changed the camera."
        snapshot_path = OUTPUT/"cloth-drape-snapshot.json"
        saved = cloth("snapshot", path=str(snapshot_path))
        assert saved["bytes"] == snapshot_path.stat().st_size
        assert saved["sha256"] == hashlib.sha256(snapshot_path.read_bytes()).hexdigest()
        assert json.loads(snapshot_path.read_text())["positionsMm"] == snapshot["mesh"]["positionsMm"]
        cloth("reset");assert cloth("snapshot")["mesh"]["positionsMm"] == initial
        assert c.call("form_get_project") == before
        configured = cloth("configure", settings={"friction": 0.47})
        edited = c.call("form_get_project")
        assert len(edited["history"]) == len(before["history"])+1
        c.call("form_undo");assert c.call("form_get_project") == before
        c.call("form_redo");assert c.call("form_get_project") == edited
        cloth("step", frames=5)
        c.call("form_open_project", {"project_id": project["id"]})
        assert cloth("get")["diagnostics"]["completedFrames"] == 0
        assert c.call("form_get_project")["camera"] == baseline_camera
        tote_definition = cloth("get", item=tote)["definition"]
        for _ in range(30):
            seam = cloth("step", item=tote, frames=1)
        assert seam["diagnostics"]["maximumSeamGapMm"] < 2
        tote_verified = verify_mesh(cloth("snapshot", item=tote), tote_definition)
        assert cloth("get",item=label)["placement"] != label_before
        # Run is explicit and bounded; Stop prevents further publication.
        cloth("run", item=tote)
        for _ in range(60):
            running = cloth("get", item=tote)
            if running["diagnostics"]["completedFrames"] > 30: break
            time.sleep(0.05)
        assert running["diagnostics"]["completedFrames"] > 30
        stopped = cloth("stop", item=tote)["diagnostics"]
        time.sleep(0.12);assert cloth("get", item=tote)["diagnostics"] == stopped
        setup = c.call("form_open_print", {"object_id": drape["id"]})
        assert "open flexible surface" in (setup.get("validation_error") or "")
        assert setup["print_commands_enabled"] is False
        c.call("form_set_view", {"view": "perspective"})
        c.call("form_export", {"format": "png", "path": str(OUTPUT/"cloth-native-studies.png")})
        report = {"passed": True, "project_id": project["id"], "drape": verified, "two_panel": tote_verified,
                  "drape_diagnostics": frame["diagnostics"], "seam_diagnostics": seam["diagnostics"], "snapshot": saved,
                  "settings_digest": configured["definition_digest"], "runtime_saved": False, "hardware_calls": 0}
        path = OUTPUT/"cloth-report.json";path.write_text(json.dumps(report, indent=2))
        print(json.dumps({"passed": True, "report": str(path), "drape": verified, "two_panel": tote_verified}, indent=2))
    finally:
        c.close()


if __name__ == "__main__":
    main()
