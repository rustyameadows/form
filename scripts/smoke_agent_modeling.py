#!/usr/bin/env python3
"""Exercise agent-authored constructions, repairable CAD and linked surfaces in an isolated LAB."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    app = Path(os.environ.get("LAB_APP_PATH", ROOT / "build/LAB.app"))
    output = ROOT / ".local/validation" / ("agent-engine-" + uuid.uuid4().hex[:12])
    library = output / "Library"
    library.mkdir(parents=True)
    socket = "/tmp/lab-agent-" + uuid.uuid4().hex[:12] + ".sock"
    env = dict(os.environ, LAB_LIBRARY_PATH=str(library), LAB_SOCKET_PATH=socket)
    helper = app / "Contents/MacOS/lab-mcp"
    report = {"application": str(app),
              "application_sha256": hashlib.sha256((app / "Contents/MacOS/LAB").read_bytes()).hexdigest(),
              "checks": []}

    def call(name, args=None, fail=False):
        result = subprocess.run([str(helper), "--call", name, json.dumps(args or {})],
                                env=env, capture_output=True, text=True, timeout=90)
        if fail:
            assert result.returncode != 0, (name, args, result.stdout)
            return result.stderr
        assert result.returncode == 0, (name, args, result.stderr)
        return json.loads(result.stdout)

    def cad(command, **args):
        return call("form_cad", dict(command=command, **args))

    def wait_job(job, desired="ready"):
        deadline = time.monotonic() + 90
        while job["state"] not in (desired, "failed", "cancelled"):
            assert time.monotonic() < deadline, job
            time.sleep(.02)
            job = cad("status", job_id=job["job_id"])
        assert job["state"] == desired, job
        return job

    def wait_evidence(request):
        deadline = time.monotonic() + 90
        while request["state"] == "pending":
            assert time.monotonic() < deadline, request
            time.sleep(.02)
            request = cad("evidence_status", request_id=request["request_id"])
        assert request["state"] == "complete", request
        return request

    def add_graphic(name, width, height, text):
        artwork = call("form_add_object", {"recipe_id": "artboard", "name": name,
            "parameters": {"width": width, "depth": height}})
        call("form_edit_artwork", {"object_id": artwork["id"], "command": "add", "elements": [
            {"id": str(uuid.uuid4()), "kind": "text", "x": 5, "y": 18 if height == 45 else 6,
             "width": width-10, "height": 18, "text": text, "color": "#245BFF", "fontSize": 11}]})
        return artwork

    def verify_fitted_lid():
        fixture = ROOT / "Tests/Fixtures/AgentModeling/fitted-lid.json"
        definition = json.loads(fixture.read_text())
        job = wait_job(cad("create", definition=definition, quality="preview"))
        checks = wait_evidence(cad("validate", job_id=job["job_id"], cases=[
            {"name": "nominal", "values": {}},
            {"name": "wide-thin", "values": {"width": 180, "wall": 1.5, "fit": .2}},
            {"name": "small-thick", "values": {"width": 80, "height": 25, "depth": 50, "wall": 4, "fit": .8}}
        ]))
        assert checks["results"][0]["report"]["allPassed"], checks
        measured = wait_evidence(cad("evidence", job_id=job["job_id"], requests=[
            {"kind": "clearance", "first_output_id": definition["outputs"][0], "second_output_id": definition["outputs"][1]},
            {"kind": "summary"}]))
        committed = wait_job(cad("commit", job_id=job["job_id"]), "committed")
        object_id = committed["result"]["object_id"]
        sources = {}
        for surface, width, height, text in [("front", 100, 45, "FRONT UPRIGHT"),
                ("right", 70, 45, "RIGHT UPRIGHT"), ("lid", 106.8, 76.8, "LID UPRIGHT")]:
            artwork = add_graphic("Cap assembly · " + surface, width, height, text)
            sources[surface] = artwork["id"]
            call("form_surface", {"command": "bind", "object_id": object_id,
                "surface_id": surface, "source_object_id": artwork["id"]})
        original = call("form_surface", {"command": "inspect", "object_id": object_id})
        assert len(original["surfaces"]) == 4 and len(original["bindings"]) == 3, original
        wider = wait_job(cad("parameter", object_id=object_id, name="width", value=140, quality="preview"))
        wait_job(cad("commit", job_id=wider["job_id"]), "committed")
        resized = call("form_surface", {"command": "inspect", "object_id": object_id})
        assert resized["bindings"] == original["bindings"] and not resized["unresolved_bindings"], resized
        smaller = wait_job(cad("parameter", object_id=object_id, name="height", value=25, quality="preview"))
        wait_job(cad("commit", job_id=smaller["job_id"]), "committed")
        review = call("form_surface", {"command": "inspect", "object_id": object_id})
        assert review.get("surface_artwork_issues"), review
        restored = wait_job(cad("parameter", object_id=object_id, name="height", value=45, quality="preview"))
        wait_job(cad("commit", job_id=restored["job_id"]), "committed")
        call("form_set_view", {"view": "perspective"})
        call("form_set_view", {"view": "isolate", "object_id": object_id})
        call("form_set_view", {"view": "focus", "object_id": object_id})
        image = output / "fitted-lid-upright-artwork.png"
        call("form_export", {"format": "png", "path": str(image), "object_id": object_id})
        assert image.is_file() and image.stat().st_size > 1000
        with Image.open(image) as pixels:
            blue_pixels = sum(b > r+35 and b > g+20 and b > 100
                              for r, g, b in pixels.convert("RGB").getdata())
        assert blue_pixels > 100, ("Named surface artwork is missing from the actual rendered image", blue_pixels)
        return dict(object_id=object_id, fixture=str(fixture.relative_to(ROOT)),
            validation=checks, evidence=measured, sources=sources, placement_review=review,
            image=str(image), blue_artwork_pixels=blue_pixels)

    def verify_curved_vessel():
        fixture = ROOT / "Tests/Fixtures/AgentModeling/curved-vessel.json"
        definition = json.loads(fixture.read_text())
        job = wait_job(cad("create", definition=definition, quality="preview"))
        cases = [{"name": "nominal", "values": {}},
                 {"name": "narrow-rim-wide-body", "values": {"rimRadius": 28, "bulgeRadius": 95}}]
        failed = wait_evidence(cad("validate", job_id=job["job_id"], cases=cases))
        result = failed["results"][0]["report"]
        assert not result["allPassed"] and result["cases"][1]["requirementID"] == "rim-bulge-ratio", result
        profile = next(f for f in definition["features"] if f["operation"]["kind"] == "curveProfile")

        def widen_rim(value):
            if isinstance(value, dict):
                return {key: widen_rim(item) for key, item in value.items()}
            if isinstance(value, list):
                return [widen_rim(item) for item in value]
            return value.replace("rimRadius", "max(rimRadius,bulgeRadius/2)") if isinstance(value, str) else value

        requirements = copy.deepcopy(definition["requirements"])
        requirements[0]["lhs"] = "max(rimRadius,bulgeRadius/2)"
        repaired = wait_job(cad("patch", job_id=job["job_id"], expected_revision=job["draft_revision"], patches=[
            {"action": "replace", "feature_id": profile["id"], "operation": widen_rim(profile["operation"])},
            {"action": "requirements", "requirements": requirements}]))
        passed = wait_evidence(cad("validate", job_id=repaired["job_id"], cases=cases))
        assert passed["results"][0]["report"]["allPassed"], passed
        committed = wait_job(cad("commit", job_id=repaired["job_id"]), "committed")
        return dict(object_id=committed["result"]["object_id"], fixture=str(fixture.relative_to(ROOT)),
            failed_cases=failed, repaired_cases=passed)

    def verify_legacy_conversion(original_project_id):
        results = []
        for template, recipe in [("cyanotype", "paperEnvelope"), ("cosmetics", "tuckCarton")]:
            project = call("form_create_project", {"name": "Authored conversion · " + template, "template": template})
            before = call("form_get_project")
            original = next(o for o in before["objects"] if o["recipeID"] == recipe)
            converted = call("form_construction", {"command": "convert", "object_id": original["id"]})
            after = call("form_get_project")
            current = next(o for o in after["objects"] if o["id"] == original["id"])
            assert current.get("artwork") == original.get("artwork")
            assert current["paperConstruction"]["kind"] == "authored"
            for key in ["insideArtworkSourceID", "insideArtwork", "annotations", "stock"]:
                assert current["paperConstruction"].get(key) == original["paperConstruction"].get(key), key
            call("form_undo")
            assert call("form_get_project")["objects"] == before["objects"]
            call("form_redo")
            assert call("form_get_project")["objects"] == after["objects"]
            call("form_open_project", {"project_id": project["id"]})
            assert call("form_get_project")["objects"] == after["objects"]
            results.append(dict(template=template, object_id=original["id"], revision=converted["revision"]))
        call("form_open_project", {"project_id": original_project_id})
        return results

    with (output / "app.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/LAB")], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 40
            while not Path(socket).exists():
                assert process.poll() is None, "LAB exited before opening its bridge"
                assert time.monotonic() < deadline, "LAB bridge startup timed out"
                time.sleep(.1)
            assert call("form_status")["library_path"] == str(library)
            project = call("form_create_project", {"name": "Agent modeling acceptance", "template": "blank"})

            # This five-face construction is supplied as document content to the frozen app.
            capabilities = call("form_construction", {"command": "capabilities"})
            construction = copy.deepcopy(capabilities["example"])
            construction["name"] = "Five-face display tray"
            construction["size"]["y"] = "height+2*depth"
            construction["panels"].append({"id": "bottom", "name": "Bottom", "role": "body", "artworkRotationDegrees": 0,
                "polygon": [{"x": "depth", "y": "depth+height"}, {"x": "depth+width", "y": "depth+height"},
                            {"x": "depth+width", "y": "height+2*depth"}, {"x": "depth", "y": "height+2*depth"}]})
            construction["hinges"].append({"id": "base-bottom", "parentPanelID": "base", "childPanelID": "bottom",
                "start": {"x": "depth", "y": "depth+height"}, "end": {"x": "depth+width", "y": "depth+height"}, "angleDegrees": 90})
            constructed = call("form_construction", {"command": "create", "definition": construction})
            construction_id = constructed["object_id"]
            assert len(constructed["net"]["panels"]) == 5
            assert len(constructed["poses"]) == 5
            call("form_set_view", {"view": "canvas", "object_id": construction_id})
            cases = call("form_construction", {"command": "validate_cases", "object_id": construction_id, "extrema": True})
            assert cases["passed"], cases
            changed = call("form_construction", {"command": "parameter", "object_id": construction_id,
                "expected_revision": constructed["revision"], "values": {"width": 140, "fold": 35}})
            assert changed["parameters"]["width"] == 140 and changed["parameters"]["fold"] == 35
            call("form_undo")
            assert call("form_construction", {"command": "inspect", "object_id": construction_id})["revision"] == constructed["revision"]
            report["construction"] = dict(object_id=construction_id, parameter_cases=cases)
            report["checks"].append("unregistered construction, arbitrary added face, fold transforms, parameter extrema, Undo")

            glued = call("form_construction", {"command": "create", "definition": capabilities["fold_and_glue_example"]})
            assert glued["connections_passed"] and glued["connection_checks"], glued
            connection_cases = call("form_construction", {"command": "validate_cases", "object_id": glued["object_id"],
                "cases": [{"name": "flat", "values": {"fold": 0}}, {"name": "half", "values": {"fold": 50}},
                          {"name": "closed", "values": {"fold": 100}}]})
            assert not connection_cases["cases"][0]["passed"] and connection_cases["cases"][2]["passed"], connection_cases
            report["fold_and_glue"] = dict(object_id=glued["object_id"], checks=connection_cases)

            feature_id, model_id = str(uuid.uuid4()), str(uuid.uuid4())
            definition = {"id": model_id, "version": 2, "revision": 0, "name": "Surface-ready body",
                "parameters": [{"name": "width", "value": 100, "minimum": 60, "maximum": 160, "unit": "mm"}],
                "features": [{"id": feature_id, "name": "Body", "operation": {"kind": "box", "inputs": [],
                              "values": {"width": "width", "height": 20, "depth": 50}}}], "outputs": [feature_id],
                "surfaces": [{"id": "top", "name": "Top", "outputFeatureID": feature_id,
                    "selection": {"faceAtMaximum": {"axis": "y"}}, "origin": {"x": 0, "y": 20, "z": 50},
                    "uAxis": {"x": 1, "y": 0, "z": 0}, "vAxis": {"x": 0, "y": 0, "z": -1}, "width": "width", "height": 50}]}
            job = wait_job(cad("create", definition=definition, quality="preview"))
            assert len(job.get("surface_issues", [])) == 0, job
            one = cad("evidence", job_id=job["job_id"], requests=[{"kind": "summary"}, {"kind": "topology", "feature_id": feature_id}])
            two = cad("evidence", job_id=job["job_id"], requests=[{"kind": "render", "path": str(output / "cad-preview.png"), "width": 800, "height": 600, "view": "perspective"}])
            report["evidence"] = [wait_evidence(one), wait_evidence(two)]
            assert len(report["evidence"][0]["results"]) == 2
            failed_id = str(uuid.uuid4())
            bad = cad("patch", job_id=job["job_id"], expected_revision=job["draft_revision"], patches=[
                {"action": "append", "feature": {"id": failed_id, "name": "Impossible finish", "operation": {"kind": "fillet", "inputs": [feature_id], "values": {"radius": 1000}}}},
                {"action": "outputs", "outputs": [feature_id, failed_id]}])
            bad = wait_job(bad, "failed")
            assert uuid.UUID(bad["diagnostic"]["feature_id"]) == uuid.UUID(failed_id), bad
            repaired = cad("patch", job_id=bad["job_id"], expected_revision=bad["draft_revision"], patches=[
                {"action": "remove", "feature_id": failed_id}, {"action": "outputs", "outputs": [feature_id]}])
            repaired = wait_job(repaired)
            validation = wait_evidence(cad("validate", job_id=repaired["job_id"], include_extrema=True))
            assert validation["results"][0]["report"]["allPassed"], validation
            report["parameter_validation"] = validation
            committed = wait_job(cad("commit", job_id=repaired["job_id"]), "committed")
            model_object_id = committed["result"]["object_id"]
            artwork = call("form_add_object", {"recipe_id": "artboard", "name": "Upright top graphic", "parameters": {"width": 100, "depth": 50}})
            call("form_edit_artwork", {"object_id": artwork["id"], "command": "add", "elements": [
                {"id": str(uuid.uuid4()), "kind": "text", "x": 8, "y": 8, "width": 80, "height": 20, "text": "ONE SHARED SOURCE", "color": "#245BFF", "fontSize": 15}]})
            call("form_surface", {"command": "bind", "object_id": model_object_id, "surface_id": "top", "source_object_id": artwork["id"]})
            bound = call("form_surface", {"command": "inspect", "object_id": model_object_id})
            assert bound["bindings"][0]["sourceObjectID"] == artwork["id"] and not bound["unresolved_bindings"], bound
            report["fitted_lid"] = verify_fitted_lid()
            report["curved_vessel"] = verify_curved_vessel()
            report["legacy_conversion"] = verify_legacy_conversion(project["id"])
            report["checks"].append("fitted cap measured clearance/interference, three upright artwork sources, dimension continuity and placement review")
            report["checks"].append("curved vessel boundary failure, local profile/requirement repair, identical cases rerun, persistent handoff")
            call("form_set_view", {"view": "isolate", "object_id": construction_id})
            call("form_set_view", {"view": "split", "object_id": construction_id})
            call("form_set_view", {"view": "focus", "object_id": construction_id})
            saved = call("form_get_project")
            call("form_open_project", {"project_id": project["id"]})
            restored = call("form_get_project")
            assert restored["objects"] == saved["objects"]
            report["checks"].append("independent evidence, failed-draft repair, parameter validation, exact commit, named artwork binding, save/reopen")
            report["model_object_id"] = model_object_id
            report["status"] = call("form_status")
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"report": str(output / "report.json"), "checks": report["checks"]}, indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            Path(socket).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
