#!/usr/bin/env python3
"""Launch this worktree's packaged app with a disposable library/socket, verify, exit.

No interaction with the ordinary app instance, user projects, inventory, or hardware.
"""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    token = uuid.uuid4().hex[:12]
    folder = ROOT / ".local" / "validation" / ("object-library-" + token)
    library = folder / "Library"
    library.mkdir(parents=True)
    socket = "/tmp/object-library-" + token + ".sock"
    app = ROOT / "build/LAB.app"
    if not app.exists():
        app = ROOT / "build/FORM.app"
    binaries = app / "Contents/MacOS"
    executable = binaries / ("LAB" if (binaries / "LAB").exists() else "FORM")
    helper = binaries / ("lab-mcp" if (binaries / "lab-mcp").exists() else "form-mcp")
    env = dict(os.environ, FORM_LIBRARY_PATH=str(library), FORM_SOCKET_PATH=socket,
               LAB_LIBRARY_PATH=str(library), LAB_SOCKET_PATH=socket)

    def call(name, arguments=None, fail=False):
        result = subprocess.run([str(helper), "--call", name, json.dumps(arguments or {})],
                                env=env, capture_output=True, text=True, timeout=20)
        if fail:
            assert result.returncode != 0, result.stdout
            return
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    with (folder / "app.log").open("w") as log:
        process = subprocess.Popen([str(executable)], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            while not Path(socket).exists():
                assert process.poll() is None, (folder / "app.log").read_text()
                assert time.monotonic() < deadline, "Isolated app did not start its bridge"
                time.sleep(.1)
            assert Path(call("form_status")["library_path"]).resolve() == library.resolve()
            discovery = subprocess.run([str(helper)], input=json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/list"})+"\n",
                                       env=env, capture_output=True, text=True, timeout=20)
            tools = json.loads(discovery.stdout)["result"]["tools"]
            assert any(t["name"] == "form_object_library" for t in tools)
            report = call("form_object_library", {"command":"list","limit":211})
            assert report["total"] == 211 and len(report["items"]) == 211
            project = call("form_create_project", {"name":"Starter library acceptance", "template":"giftShop"})
            assert len(project["objects"]) == 7
            before = call("form_get_project")
            call("form_object_library", {"command":"get","entry_id":"heavy-tee"})
            assert call("form_get_project") == before
            host = next(o for o in project["objects"] if o["librarySelection"]["entry"]["id"] == "jersey-tee")
            decoration = call("form_add_object", {"recipe_id":"textilePrint", "parameters":{"width":240,"depth":100},
                "textile":{"kind":"patch","process":"directPrint","attachment":{"garmentID":host["id"],"zone":"front","clearance":0}}})
            before = call("form_get_project")
            call("form_object_library", {"command":"replace","object_id":host["id"],"entry_id":"heavy-tee"})
            current = call("form_get_project")
            assert next(o for o in current["objects"] if o["id"] == decoration["id"]) == decoration
            call("form_undo")
            assert call("form_get_project") == before
            call("form_redo")
            call("form_object_library", {"command":"state","object_id":host["id"],"state":"chosenBlank"})
            call("form_update_object", {"object_id":host["id"],"parameters":{"depth":700}})
            current = call("form_get_project")
            selected = next(o for o in current["objects"] if o["id"] == host["id"])
            assert selected["librarySelection"]["state"] == "custom"
            call("form_object_library", {"command":"state","object_id":host["id"],"state":"chosenBlank"}, fail=True)
            call("form_open_project", {"project_id":project["id"]})
            reopened = call("form_get_project")
            assert reopened["objects"] == current["objects"] and reopened["schemaVersion"] == 51
            result = {"project_id":project["id"], "tool_count":len(tools), "references":211, "assortment_objects":7,
                      "checks":["packaged resource and tool discovery", "isolated native socket", "read-only catalog", "real proposed product snapshots",
                                "source/physical placement preservation", "Undo/Redo", "choice/custom transition", "saved reopen"]}
            (folder / "report.json").write_text(json.dumps(result,indent=2)+"\n")
            print(json.dumps(dict(result, report=str(folder / "report.json")),indent=2))
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
