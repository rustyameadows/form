#!/usr/bin/env python3
"""Verify declared folded-stock checks through a packaged app's real local bridge."""
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def source(project):
    value = copy.deepcopy(project)
    # Native window sizing changes only this camera presentation attribute.
    value.get("camera", {}).pop("viewportAspect", None)
    return value


def main():
    app = Path(os.environ.get("LAB_APP_PATH", ROOT / "build/LAB-engine-verified.app")).resolve()
    binary, helper = app / "Contents/MacOS/LAB", app / "Contents/MacOS/lab-mcp"
    token = uuid.uuid4().hex[:12]
    folder = ROOT / ".local/validation" / ("planar-solid-checks-" + token)
    library = folder / "Library"
    library.mkdir(parents=True)
    socket = "/tmp/lab-planar-solids-" + token + ".sock"
    env = dict(os.environ, LAB_LIBRARY_PATH=str(library), FORM_LIBRARY_PATH=str(library),
               LAB_SOCKET_PATH=socket, FORM_SOCKET_PATH=socket)
    report = {"application": str(app), "application_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    process = None

    def call(name, arguments=None):
        result = subprocess.run([str(helper), "--call", name, json.dumps(arguments or {})],
                                env=env, capture_output=True, text=True, timeout=45)
        assert result.returncode == 0, (name, arguments, result.returncode, result.stderr, result.stdout)
        return json.loads(result.stdout)

    def construction(command, **arguments):
        return call("form_construction", dict(command=command, **arguments))

    def close(actual, expected):
        assert math.isclose(actual, expected, rel_tol=1e-9, abs_tol=1e-6), (actual, expected)

    with (folder / "app.log").open("w") as log:
        try:
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while not Path(socket).exists():
                assert process.poll() is None, "The private app exited before its bridge was ready"
                assert time.monotonic() < deadline, "Private bridge startup exceeded 30 seconds"
                time.sleep(.05)
            status = call("form_status")
            assert Path(status["library_path"]).resolve() == library.resolve(), status
            project = call("form_create_project", {"name": "Declared finite-stock contact", "template": "blank"})
            capability = construction("capabilities")
            assert 2 in capability["source_versions"], capability
            definition = capability["solid_check_example"]
            assert definition["version"] == 2 and len(definition["solidChecks"]) == 2
            created = construction("create", definition=definition)
            object_id = created["object_id"]
            assert created["solid_checks_status"] == "not_evaluated", created
            call("form_edit_artwork", {"object_id": object_id, "command": "add", "elements": [
                {"id": str(uuid.uuid4()), "kind": "text", "x": 5, "y": 8,
                 "width": 30, "height": 8, "text": "SAME SOURCE", "fontSize": 11, "color": "#245BFF"}]})
            time.sleep(.3)  # Let the preceding normal edit's scheduled save settle.
            before, selection = call("form_get_project"), call("form_status")["selected_objects"]
            cases = construction("validate_cases", object_id=object_id, cases=[
                {"name": "declared-contact", "values": {}},
                {"name": "overlap", "values": {"layer": 0}},
                {"name": "mating-gap", "values": {"layer": .7}}])
            assert cases["source_revision"] == created["revision"]
            assert cases["passed"] is False and [item["passed"] for item in cases["cases"]] == [True, False, True], cases
            assert "Only explicitly declared" in cases["solid_model"]
            checks = [item["solid_checks"] for item in cases["cases"]]
            assert checks[1][0]["id"] == "material-separation" and checks[1][0]["units"] == "mm3"
            close(checks[0][0]["measured"], 0)
            close(checks[1][0]["measured"], 800)
            close(checks[2][1]["measured"], .3)
            assert source(call("form_get_project")) == source(before), "Case validation changed accepted source/history/artwork"
            assert call("form_status")["selected_objects"] == selection, "Case validation changed selection"
            # Make the failed state concrete, repair through ordinary source controls,
            # then prove that one Undo restores exactly the preceding source state.
            construction("parameter", object_id=object_id, values={"layer": 0})
            failed = call("form_get_project")
            assert construction("validate_cases", object_id=object_id)["passed"] is False
            construction("parameter", object_id=object_id, values={"layer": .4})
            repaired = construction("validate_cases", object_id=object_id)
            assert repaired["passed"] is True and repaired["source_revision"] == created["revision"]
            accepted = call("form_get_project")
            call("form_undo")
            undone = call("form_get_project")
            assert undone["objects"] == failed["objects"], "One Undo did not restore the failed source"
            call("form_redo")
            assert call("form_get_project")["objects"] == accepted["objects"]
            call("form_open_project", {"project_id": project["id"]})
            reopened = call("form_get_project")
            assert reopened["objects"] == accepted["objects"], "Reopen changed source, checks, IDs or artwork"
            assert construction("validate_cases", object_id=object_id)["passed"] is True
            report.update(passed=True, object_id=object_id, definition=definition, cases=cases,
                          repaired=repaired, read_only_source=True, selection_unchanged=True,
                          undo_redo=True, save_reopen=True,
                          app_exit_before_cleanup=process.poll())
        except BaseException as error:
            report.update(passed=False, error=repr(error),
                          app_exit_before_cleanup=process.poll() if process else None)
            raise
        finally:
            (folder / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True))
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            Path(socket).unlink(missing_ok=True)
            print(folder / "report.json", flush=True)


if __name__ == "__main__":
    main()
