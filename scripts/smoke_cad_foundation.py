#!/usr/bin/env python3
"""Exercise a packaged LAB in a disposable library. Never sends or starts prints."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    token = uuid.uuid4().hex[:12]
    folder = ROOT / ".local/validation" / ("cad-foundation-" + token)
    library = folder / "Library"
    library.mkdir(parents=True)
    app = Path(os.environ.get("LAB_APP_PATH", ROOT / "build/LAB-cad-candidate.app"))
    binary = app / "Contents/MacOS/LAB"
    helper = app / "Contents/MacOS/lab-mcp"
    socket = "/tmp/lab-cad-" + token + ".sock"
    env = dict(os.environ, LAB_LIBRARY_PATH=str(library), FORM_LIBRARY_PATH=str(library),
               LAB_SOCKET_PATH=socket, FORM_SOCKET_PATH=socket)
    orca=ROOT/".local/engines/OrcaSlicer.app"
    if orca.exists():
        env["LAB_ORCA_APP_PATH"]=str(orca)
    report = {"app": str(app), "printer_commands": [], "models": {}}

    def call(name, args=None, fail=False):
        result = subprocess.run([str(helper), "--call", name, json.dumps(args or {})],
                                env=env, capture_output=True, text=True, timeout=60)
        if fail:
            assert result.returncode != 0, result.stdout
            return result.stderr
        assert result.returncode == 0, (name, result.stderr)
        return json.loads(result.stdout)

    def wait_job(tool, job, wanted="ready"):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            current = call(tool, {"command": "status", "job_id": job["job_id"]})
            if current["state"] == wanted:
                return current
            assert current["state"] not in ("failed", "cancelled"), current
            time.sleep(.1)
        raise AssertionError(("Job timeout", tool, current))

    def exact(template):
        started = time.monotonic()
        job = call("form_cad", {"command": "create", "template": template, "quality": "fabrication"})
        ready = wait_job("form_cad", job)
        preview=folder/(template+"-preview.png")
        before_preview=call("form_get_project")
        call("form_cad",{"command":"render","job_id":job["job_id"],"path":str(preview),"view":"perspective","width":900,"height":720,"transparent":True})
        deadline=time.monotonic()+45
        while True:
            observed=call("form_cad",{"command":"status","job_id":job["job_id"]})
            assert not observed.get("error") and not observed["result"].get("error"),observed
            if observed["result"].get("path"):break
            assert time.monotonic()<deadline,"Uncommitted CAD preview timeout"
            time.sleep(.1)
        assert struct.unpack(">II",preview.read_bytes()[16:24])==(900,720)
        assert call("form_get_project")==before_preview
        call("form_cad",{"command":"render","job_id":job["job_id"],"path":str(preview),"view":"front"},fail=True)
        clearance=None
        if template=="lamp":
            ids=[part["id"] for part in ready["representation"]["components"]]
            call("form_cad",{"command":"clearance","job_id":job["job_id"],"first_output_id":ids[0],"second_output_id":ids[1]})
            deadline=time.monotonic()+30
            while True:
                inspected=call("form_cad",{"command":"status","job_id":job["job_id"]})
                assert not inspected.get("error"),inspected
                if "distance_mm" in inspected["result"]:clearance=inspected["result"];break
                assert time.monotonic()<deadline
                time.sleep(.1)
            assert clearance["distance_mm"]>=0 and clearance["interference_volume_mm3"]>=0
        call("form_cad", {"command": "commit", "job_id": job["job_id"]})
        wait_job("form_cad", job, "committed")
        project = call("form_get_project")
        object_ = next(o for o in project["objects"] if o.get("cadModel", {}).get("id") == job["model_id"])
        representation = object_["cadRepresentation"]
        assert all(c["valid"] and c["closed"] and c["volumeMM3"] > 0 for c in representation["components"])
        report["models"][template] = {"object_id": object_["id"], "elapsed_seconds": time.monotonic() - started,
                                        "representation": representation, "features": len(object_["cadModel"]["features"]),"clearance_inspection":clearance}
        return object_, job, ready

    def launch(log):
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while not Path(socket).exists():
            assert process.poll() is None, "Candidate exited before opening its bridge"
            assert time.monotonic() < deadline, "Bridge startup timeout"
            time.sleep(.1)
        assert Path(call("form_status")["library_path"]).resolve() == library.resolve()
        return process

    with (folder / "app.log").open("w") as log:
        process = launch(log)
        try:
            assert "OCCT" in call("form_cad", {"command": "capabilities"})["kernel"]
            assert "glb" in call("form_model_asset", {"command": "formats"})["formats"]
            created = call("form_create_project", {"name": "CAD foundation acceptance", "template": "blank"})
            project_id = created["id"]
            clock, clock_job, _ = exact("clockEnclosure")
            original = call("form_get_project")
            call("form_cad", {"command": "parameter", "object_id": clock["id"], "name": "diameter", "value": True}, fail=True)
            assert call("form_get_project") == original
            edit = call("form_cad", {"command": "parameter", "object_id": clock["id"], "name": "diameter", "value": 190})
            ready = wait_job("form_cad", edit)
            call("form_cad", {"command": "commit", "job_id": edit["job_id"]})
            wait_job("form_cad", edit, "committed")
            changed = call("form_get_project")
            next_clock = next(o for o in changed["objects"] if o["id"] == clock["id"])
            diameter = next(p["value"] for p in next_clock["cadModel"]["parameters"] if p["name"] == "diameter")
            assert diameter == 190
            call("form_undo")
            assert call("form_get_project")["objects"] == original["objects"]
            call("form_redo")
            assert call("form_get_project")["objects"] == changed["objects"]
            report["models"]["clockEnclosure"]["edited_diameter_mm"] = diameter
            report["models"]["clockEnclosure"]["rebuilt_features"] = ready["rebuilt_features"]
            # Invalid feature/parameter work remains a draft and cannot damage source.
            before_failure = call("form_get_project")
            call("form_cad", {"command": "parameter", "object_id": clock["id"], "name": "wall", "value": 1000}, fail=True)
            assert call("form_get_project") == before_failure
            for template in ("vase", "lamp", "enclosure"):
                exact(template)
            # The vessel goes only through local mesh/slice preview, never hardware.
            setup=call("form_open_print",{"object_id":report["models"]["vase"]["object_id"]})
            deadline=time.monotonic()+45
            while setup["preparing"]:
                assert time.monotonic()<deadline,"CAD print mesh preparation timeout"
                time.sleep(.1);setup=call("form_get_print_setup")
            assert setup["validation_error"] is None and setup["mesh_size_mm"] and setup["print_commands_enabled"] is False,setup
            report["vase_print_preparation"]=setup
            if setup["engine_available"]:
                call("form_slice")
                deadline=time.monotonic()+180
                while True:
                    sliced=call("form_get_slice_status")
                    if not sliced["busy"]:break
                    assert time.monotonic()<deadline,"Local vessel slicing timeout"
                    time.sleep(.5)
                assert sliced["validation_error"] is None and sliced["layers"]>0,sliced
                report["vase_local_slice"]=sliced
            # Exact exchange is measured by importing the actual written STEP back.
            evaluation = call("form_cad", {"command": "evaluate", "object_id": clock["id"]})
            ready = wait_job("form_cad", evaluation)
            output_id = ready["representation"]["components"][0]["id"]
            step = folder / "clock.step"
            call("form_cad", {"command": "export", "job_id": evaluation["job_id"], "output_id": output_id,
                              "format": "step", "path": str(step)})
            deadline = time.monotonic() + 30
            while not step.exists():
                assert time.monotonic() < deadline
                time.sleep(.1)
            imported = call("form_cad", {"command": "import_step", "path": str(step), "source_up_axis": "y"})
            imported_ready = wait_job("form_cad", imported)
            original_component = ready["representation"]["components"][0]
            exchanged = imported_ready["representation"]["components"][0]
            assert abs(exchanged["volumeMM3"] - original_component["volumeMM3"]) < .02
            for bound in ("minimum", "maximum"):
                assert all(abs(exchanged[bound][axis] - original_component[bound][axis]) < .001 for axis in ("x", "y", "z"))
            call("form_cad", {"command": "cancel", "job_id": imported["job_id"]})
            call("form_cad", {"command": "cancel", "job_id": evaluation["job_id"]})
            report["step_roundtrip"] = {"bytes": step.stat().st_size, "sha256": hashlib.sha256(step.read_bytes()).hexdigest(),
                                        "volume_error_mm3": abs(exchanged["volumeMM3"] - original_component["volumeMM3"])}
            jacket_path = Path(os.environ.get("LAB_JACKET_GLB", ROOT / ".local/cad-foundation/fixtures/blender/LAB-Blender-flight-jacket.glb"))
            if jacket_path.exists():
                job = call("form_model_asset", {"command": "import", "path": str(jacket_path)})
                wait_job("form_model_asset", job)
                call("form_model_asset", {"command": "commit", "job_id": job["job_id"]})
                committed = wait_job("form_model_asset", job, "committed")
                imported = next(o for o in call("form_get_project")["objects"] if o["id"] == committed["object_id"])
                slots=imported["meshAsset"]["materials"]
                shell=next((m["index"] for m in slots if "shell" in m["name"].lower()),0)
                call("form_model_asset", {"command": "material", "object_id": imported["id"], "material_index": shell, "color": "#C56836"})
                patch=next((m["index"] for m in slots if "patch" in m["name"].lower()),None)
                if patch is not None:
                    frame=call("form_add_object",{"recipe_id":"artboard","name":"Imported patch artwork source","parameters":{"width":85,"depth":55}})
                    art=frame.get("artwork") or {"background":"#C56836","elements":[],"bleed":0}
                    art["background"]="#C56836"
                    art["elements"].append({"id":str(uuid.uuid4()),"kind":"text","x":8,"y":12,"width":69,"height":25,"text":"LAB / FLIGHT 02","fontSize":10,"color":"#FFF3D8"})
                    call("form_set_artwork",{"object_id":frame["id"],"artwork":art})
                    call("form_model_asset",{"command":"artwork","object_id":imported["id"],"material_index":patch,"source_object_id":frame["id"]})
                variant = call("form_duplicate_object", {"object_id": imported["id"], "mode": "variant"})
                call("form_model_asset", {"command": "material", "object_id": variant["id"], "material_index": shell, "color": "#32483B"})
                report["jacket"] = {"object_id": imported["id"], "source": str(jacket_path), "metadata": imported["meshAsset"]}
            device_path=ROOT/".local/cad-foundation/fixtures/blender-device/LAB-Blender-receiver.glb"
            if device_path.exists():
                device_job=call("form_model_asset",{"command":"import","path":str(device_path)})
                wait_job("form_model_asset",device_job)
                call("form_model_asset",{"command":"commit","job_id":device_job["job_id"]})
                device_state=wait_job("form_model_asset",device_job,"committed")
                report["device"]=call("form_model_asset",{"command":"inspect","object_id":device_state["object_id"]})
                call("form_set_view",{"view":"front"})
                call("form_set_view",{"view":"isolate","object_id":device_state["object_id"]})
                call("form_set_view",{"view":"focus","object_id":device_state["object_id"]})
                call("form_export",{"format":"png","path":str(folder/"receiver-native.png")})
                call("form_set_view",{"view":"show_all"})
            assembly_job=call("form_cad",{"command":"import_step","path":str(ROOT/"Tests/FormCADKernelTests/Fixtures/colored-assembly.step"),"source_up_axis":"y"})
            assembly_ready=wait_job("form_cad",assembly_job)
            assert len(assembly_ready["representation"]["components"])==3
            call("form_cad",{"command":"commit","job_id":assembly_job["job_id"]})
            assembly_state=wait_job("form_cad",assembly_job,"committed")
            assembly_object=next(o for o in call("form_get_project")["objects"] if o["id"]==assembly_state["result"]["object_id"])
            tree=assembly_object["cadModel"]["importedAssemblies"][0]
            assert any(node["faceColors"] for node in tree["nodes"])
            assert len([n for n in tree["nodes"] if n.get("outputFeatureID")])==3
            report["step_assembly"]={"object_id":assembly_object["id"],"source":tree}
            # A mixed project also contains existing product recipes and references.
            materials=call("form_list_materials")
            fabric=next((m["id"] for m in materials if m.get("fabric")),"chalk")
            call("form_add_object",{"recipe_id":"swatch","material_id":fabric,"name":"Fabric material study"})
            reference=call("form_import_reference",{"path":str(ROOT/".local/cad-foundation/fixtures/blender/LAB-Blender-flight-jacket-source.png"),"name":"Blender source reference"})
            # Arrange the visual studies separately from the smaller engineering parts.
            current=call("form_get_project")
            mesh_count=0;other_count=0
            for item in current["objects"]:
                if item.get("meshAsset"):
                    if "jacket" in item["meshAsset"]["name"].lower():
                        x=-780 if mesh_count==0 else 780;z=450;mesh_count+=1
                    else:x=550;z=-220
                else:
                    x=-650+(other_count%5)*290;z=-250-(other_count//5)*280;other_count+=1
                y=0
                if item.get("cadRepresentation"):
                    parts=item["cadRepresentation"]["components"]
                    lo={axis:min(p["minimum"][axis] for p in parts) for axis in ("x","y","z")}
                    hi={axis:max(p["maximum"][axis] for p in parts) for axis in ("x","y","z")}
                    x-=(lo["x"]+hi["x"])/2;z-=(lo["z"]+hi["z"])/2;y=-lo["y"]
                call("form_update_object",{"object_id":item["id"],"position":[x,y,z]})
            call("form_set_view", {"view": "perspective"})
            render = folder / "mixed-scene.png"
            call("form_export", {"format": "png", "path": str(render)})
            assert render.stat().st_size > 10000
            # Flush via the shared bridge, then actually stop/relaunch before reopen.
            call("form_add_note", {"text": "CAD acceptance source persisted; no printer commands issued."})
            before = call("form_get_project")
            source_files = {str(p.relative_to(library)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in library.rglob("Assets/*") if p.is_file()}
            process.terminate(); process.wait(timeout=15)
            if Path(socket).exists():
                Path(socket).unlink()
            process = launch(log)
            call("form_open_project", {"project_id": project_id})
            reopened = call("form_get_project")
            assert reopened["objects"] == before["objects"]
            assert reopened["camera"] == before["camera"]
            assert reopened["schemaVersion"] == 52
            assert all(hashlib.sha256((library / name).read_bytes()).hexdigest() == digest for name, digest in source_files.items())
            report.update(project_id=project_id, source_resources=len(source_files), renderer=call("form_status").get("renderer"),
                          checks=["native packaged bridge", "real exact operations", "parameter edit", "Undo/Redo", "failed edit unchanged",
                                  "STEP volume/bounds roundtrip", "imported visual colorway", "actual PNG", "process restart/reopen", "resource hashes unchanged"])
            (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"report": str(folder / "report.json"), "project_id": project_id, "models": list(report["models"])}, indent=2))
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)


if __name__ == "__main__":
    main()
