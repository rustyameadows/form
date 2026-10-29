#!/usr/bin/env python3
"""Exercise a previously unregistered sewn source through the packaged native app."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    app = Path(os.environ.get("LAB_APP_PATH", ROOT / "build/LAB.app")).resolve()
    binary, helper = app / "Contents/MacOS/LAB", app / "Contents/MacOS/lab-mcp"
    token = uuid.uuid4().hex[:12]
    folder = ROOT / ".local/validation" / ("artwork-parameters-" + token)
    library = folder / "Library"
    library.mkdir(parents=True)
    socket = "/tmp/lab-artwork-parameters-" + token + ".sock"
    env = dict(os.environ, LAB_LIBRARY_PATH=str(library), FORM_LIBRARY_PATH=str(library),
               LAB_SOCKET_PATH=socket, FORM_SOCKET_PATH=socket)
    report = {"application": str(app), "application_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    process = None
    started = time.monotonic()

    def invoke(name, args=None):
        remaining = 180 - (time.monotonic() - started)
        assert remaining > 0, "The complete isolated source-authoring smoke exceeded 180 seconds"
        return subprocess.run([str(helper), "--call", name, json.dumps(args or {})], env=env,
                              capture_output=True, text=True, timeout=min(45, remaining))

    def call(name, args=None):
        result = invoke(name, args)
        assert result.returncode == 0, (name, result.stderr, result.stdout)
        return json.loads(result.stdout)

    def exact_project(actual, expected):
        if actual == expected:
            return
        a, b = copy.deepcopy(actual), copy.deepcopy(expected)
        aspect_a = a.get("camera", {}).pop("viewportAspect", None)
        aspect_b = b.get("camera", {}).pop("viewportAspect", None)
        assert a == b, "The read-only case batch changed accepted project state"
        report["only_camera_presentation_difference"] = [aspect_b, aspect_a]

    with (folder / "app.log").open("w") as log:
        try:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            until = time.monotonic() + 30
            while not Path(socket).exists():
                assert process.poll() is None, "The owned private app exited"
                assert time.monotonic() < until, "The private bridge did not start"
                time.sleep(.05)
            status = call("form_status")
            assert Path(status["library_path"]).resolve() == library.resolve()
            capability = call("form_construction", {"command": "capabilities"})
            assert "seamAllowance" in capability.get("artwork_binding_properties", []), "This binary predates canonical artwork parameter bindings"
            project = call("form_create_project", {"name": "Unregistered sewn parameter source", "template": "blank"})
            parameters = [("width", 350, 200, 600), ("depth", 160, 80, 250), ("span", 85, 35, 130),
                          ("rise", 65, 40, 100), ("allowance", 8, 2, 12), ("mismatch", 0, 0, 12)]
            recipe_id = "agentWing" + token
            recipe = dict(id=recipe_id, name="Unregistered curved wing source", symbol="scissors", parts=[],
                          parameters=[dict(id=k, name={"width":"Source width","depth":"Source height","span":"Panel span","rise":"Panel rise","allowance":"Cut allowance","mismatch":"Back span offset"}[k], value=float(v), minimum=float(lo), maximum=float(hi), unit="mm", step=1)
                                      for k, v, lo, hi in parameters])
            call("form_create_recipe", {"recipe": recipe})
            source = call("form_add_object", {"recipe_id": recipe_id})
            source_id = source["id"]
            elements = []
            for x in [20, 140]:
                points = [dict(anchor=dict(x=0, y=0)), dict(anchor=dict(x=100, y=0), outgoing=dict(x=102, y=28)),
                          dict(anchor=dict(x=92, y=70), incoming=dict(x=103, y=45), outgoing=dict(x=71, y=86)),
                          dict(anchor=dict(x=18, y=78), incoming=dict(x=40, y=83), outgoing=dict(x=2, y=61))]
                nodes = [dict(id=str(uuid.uuid4()), **item) for item in points]
                elements.append(dict(id=str(uuid.uuid4()), kind="path", x=x, y=20, width=85, height=65, text="", fontSize=12, color="#367385",
                                     path=dict(width=100, height=80, evenOdd=False, contours=[dict(id=str(uuid.uuid4()), closed=True, nodes=nodes)])))
            call("form_edit_artwork", {"object_id": source_id, "command": "add", "elements": elements})
            materials = call("form_list_materials")
            fabric = next(item for item in materials if item["category"] == "Fabric" and item.get("fabric", {}).get("weightGSM") is not None)
            for i, e in enumerate(elements):
                call("form_edit_artwork", {"object_id": source_id, "command": "pattern_piece", "element_ids": [e["id"]],
                                          "piece": dict(name="Wing " + str(i + 1), seamAllowance=8, materialID=fabric["id"])})
            seam_id = str(uuid.uuid4())
            call("form_edit_artwork", {"object_id": source_id, "command": "seam_pair", "seam": dict(id=seam_id,
                                      name="Shared opening", first=dict(elementID=elements[0]["id"], edge=0, copy=1),
                                      second=dict(elementID=elements[1]["id"], edge=0, copy=1), reversed=True, tolerance=.2)})
            bindings = []
            for i, e in enumerate(elements):
                for prop, expr in [("width", "span" if i == 0 else "span+mismatch"), ("height", "rise"), ("seamAllowance", "allowance")]:
                    bindings.append(dict(id=f"panel-{i}-{prop}", elementID=e["id"], property=prop, value=expr))
            bindings.append(dict(id="back-position", elementID=elements[1]["id"], property="x", value="span+55"))
            call("form_update_object", {"object_id": source_id, "artwork_parameter_bindings": bindings})
            assembled = call("form_cloth", {"command": "assemble", "object_id": source_id, "element_ids": [e["id"] for e in elements]})
            assembly_id = assembled["object_id"]
            declaration = copy.deepcopy(assembled["assembly"])
            declaration["seamIDs"] = [seam_id]
            declaration["pins"] = []
            call("form_cloth", {"command": "configure", "object_id": assembly_id, "assembly": declaration})
            label = call("form_add_object", {"recipe_id": "textileLabel", "parameters": {"width": 20, "depth": 10}})
            call("form_cloth", {"command": "attach", "object_id": label["id"], "surface_object_id": assembly_id,
                                "panel": 0, "material_x_mm": 45, "material_y_mm": 20, "offset_mm": 1})
            cases = [dict(name="small", values=dict(span=60, allowance=4)), dict(name="large", values=dict(span=110, allowance=11)),
                     dict(name="bad-seam", values=dict(mismatch=8)), dict(name="anchor-outside", values=dict(span=35))]
            time.sleep(.3)
            before, selected = call("form_get_project"), call("form_status")["selected_objects"]
            result = call("form_construction", {"command": "validate_cases", "object_id": source_id, "cases": cases})
            assert [v["outcome"] for v in result["cases"]] == ["passed", "passed", "failed", "failed"], result
            exact_project(call("form_get_project"), before)
            assert call("form_status")["selected_objects"] == selected
            a, b = result["cases"][:2]
            assert b["pieces"][0]["stitchBoundsMM"]["width"] > a["pieces"][0]["stitchBoundsMM"]["width"] + 40
            assert b["pieces"][0]["cutAreaMM2"] > a["pieces"][0]["cutAreaMM2"]
            assert a["pieces"][0]["edgeIDs"] == b["pieces"][0]["edgeIDs"]
            assert a["attachments"][0]["anchor"] == b["attachments"][0]["anchor"]
            assert b["assemblies"][0]["sourceDigest"] != a["assemblies"][0]["sourceDigest"]
            assert result["cases"][2]["seams"][0]["differenceMM"] > 7.9
            assert label["id"] in result["cases"][3]["error"]
            raw = call("form_get_artwork", {"object_id": source_id})
            conflict = copy.deepcopy(raw); conflict["elements"][0]["width"] += 1
            rejected = invoke("form_set_artwork", {"object_id": source_id, "artwork": conflict})
            assert rejected.returncode != 0 and "binding" in (rejected.stderr + rejected.stdout).lower()
            assert call("form_get_artwork", {"object_id": source_id}) == raw
            call("form_update_object", {"object_id": source_id, "parameters": {"span": 110}})
            changed = call("form_get_project")
            original_source = next(v for v in before["objects"] if v["id"] == source_id)
            changed_source = next(v for v in changed["objects"] if v["id"] == source_id)
            def nodes(art):
                return [n["id"] for e in art["elements"] for c in e.get("path", {}).get("contours", []) for n in c["nodes"]]
            assert nodes(original_source["artwork"]) == nodes(changed_source["artwork"])
            assert original_source["artworkParameterBindings"] == changed_source["artworkParameterBindings"]
            assert changed_source["artwork"]["elements"][0]["width"] == 110
            call("form_undo")
            assert call("form_get_project")["objects"] == before["objects"], "The parameter change was not one Undo"
            call("form_redo")
            assert call("form_get_project")["objects"] == changed["objects"]
            call("form_update_object", {"object_id": source_id, "parameters": {"span": 85}})
            for rule in bindings:
                if rule["id"] == "panel-1-width":
                    rule["value"] = "span"
            call("form_update_object", {"object_id": source_id, "artwork_parameter_bindings": bindings})
            call("form_cloth", {"command": "attach", "object_id": label["id"], "surface_object_id": assembly_id,
                                "panel": 0, "material_x_mm": 20, "material_y_mm": 20, "offset_mm": 1})
            repaired = call("form_construction", {"command": "validate_cases", "object_id": source_id, "cases": cases})
            assert repaired["passed"] is True and all(v["outcome"] == "passed" for v in repaired["cases"])
            accepted = call("form_get_project")
            call("form_open_project", {"project_id": project["id"]})
            assert call("form_get_project")["objects"] == accepted["objects"]
            assert call("form_construction", {"command": "validate_cases", "object_id": source_id, "cases": cases})["passed"] is True
            report.update(passed=True, source_id=source_id, assembly_id=assembly_id, recipe=recipe, bindings=bindings,
                          before=before, cases=result, repaired=repaired, canonical_field_conflict_rejected=True,
                          source_node_edge_ids_preserved=True, read_only_cases=True, selection_unchanged=True,
                          one_undo=True, save_reopen=True)
        except BaseException as error:
            report.update(passed=False, error=repr(error));raise
        finally:
            report["app_exit_before_cleanup"] = process.poll() if process else None
            report["duration_seconds"] = time.monotonic() - started
            keep = os.environ.get("LAB_SMOKE_KEEP_APP") == "1" and report.get("passed") is True and process is not None and process.poll() is None
            if keep:
                report["retained_native_process"] = {"pid": process.pid, "socket": socket, "library": str(library), "application": str(app)}
            (folder / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True))
            if keep:
                print(folder / "report.json", flush=True)
                # Keep the exec parent alive for the explicitly requested native
                # probe; session cleanup otherwise reaps its owned app on exit.
                until = time.monotonic() + 600
                while process.poll() is None and time.monotonic() < until and not (folder / "native-ui-complete").exists():
                    time.sleep(.2)
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill();process.wait(timeout=5)
            Path(socket).unlink(missing_ok=True)
            print(folder / "report.json", flush=True)


if __name__ == "__main__":
    main()
