#!/usr/bin/env python3
"""Run the packaged fabric regression gate in disposable per-workflow libraries.

No running LAB process or existing library is reused. Each workflow gets a fresh
app process, socket, library, output folder and logs. Only the processes started
here are stopped. The existing smokes exercise local source/edit/Undo/reopen,
physical exports, materials, attachments and cloth; no equipment is contacted.

Use a Python environment with Pyembroidery==1.5.1, pypdf and Pillow, and put
Poppler's pdfinfo/pdftotext/pdftoppm on PATH. --list needs no dependencies.
Example:
  python scripts/verify_fabric_workflows.py --app build/LAB.app
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = (
    "cloth", "pattern_assembly", "sewing_patterns", "curved_patterns",
    "fabric_patterns", "garment_blocks", "sewing_tiles", "cutting_layouts",
    "textiles", "merchandise", "embroidery", "embroidery_surface",
    "decoration_preparation", "production_jobs", "production_roles",
    "collections", "production_inks",
)
# Set the shared smoke module's output directory before loading a smoke. Their
# original ROOT and private-library safety assertions remain intact.
SMOKE_WRAPPER = """
import json, os, pathlib, runpy, subprocess, sys, time
script, output = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(script).parent))
import smoke_mcp
smoke_mcp.OUTPUT = pathlib.Path(output)
sys.argv = [script]
try:
    runpy.run_path(script, run_name="__main__")
except Exception as error:
    frames, trace = [], error.__traceback__
    while trace:
        frame = trace.tb_frame
        if frame.f_code.co_filename == script:
            cameras, projects = {}, {}
            for key, value in frame.f_locals.items():
                if isinstance(value, dict) and "camera" in value:
                    cameras[key] = value["camera"]
                    projects[key] = value
                elif "camera" in key.lower():
                    try:
                        json.dumps(value)
                        cameras[key] = value
                    except (TypeError,ValueError):
                        pass
            progress = {}
            for key in ("frame","batch","command","state","preparation","progressed"):
                value = frame.f_locals.get(key)
                if isinstance(value,dict):
                    progress[key] = value.get("diagnostics",value if key in ("state","preparation") else {})
                elif isinstance(value,(str,int,float)):
                    progress[key] = value
            frames.append(dict(line=trace.tb_lineno,cameras=cameras,projects=projects,progress=progress))
        trace = trace.tb_next
    status_started=time.monotonic()
    try:
        status=subprocess.run([os.environ["LAB_MCP_PATH"],"--call","form_status","{}"],
                              capture_output=True,text=True,timeout=10)
        direct_status=dict(returncode=status.returncode,stderr=status.stderr,
                           stdout=status.stdout,elapsed_seconds=time.monotonic()-status_started)
    except subprocess.TimeoutExpired:
        direct_status=dict(returncode=None,stderr="Diagnostic status timed out",elapsed_seconds=time.monotonic()-status_started)
    current_started=time.monotonic()
    try:
        current = subprocess.run([os.environ["LAB_MCP_PATH"],"--call","form_get_project","{}"],
                                 capture_output=True,text=True,timeout=10)
        actual = json.loads(current.stdout) if current.returncode == 0 else {}
    except subprocess.TimeoutExpired:
        current, actual = None, {}
    pathlib.Path(output,"failure-context.json").write_text(json.dumps(
        dict(error=str(error),frames=frames,current_camera=actual.get("camera"),current_project=actual,
             direct_status=direct_status,current_bridge_elapsed_seconds=time.monotonic()-current_started,
             current_bridge_returncode=current.returncode if current else None,
             current_bridge_error=current.stderr if current else "Diagnostic bridge read timed out"),indent=2))
    raise
"""


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stop(process, process_group=True):
    if process is None or process.poll() is not None:
        return
    # CLI children own groups (including stdio MCP/PDF readers). An AppKit app
    # keeps the current GUI login session and is stopped only by its own PID.
    try:
        if process_group:
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if process_group:
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait(timeout=5)


def command(argv, env, log, timeout):
    start = time.monotonic()
    with log.open("w") as stream:
        process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            returncode = process.wait(timeout=timeout)
            issue = None if returncode == 0 else f"Exit status {returncode}"
        except subprocess.TimeoutExpired:
            stop(process)
            returncode, issue = None, f"Exceeded {timeout:g} seconds"
        except BaseException:
            stop(process)
            raise
    return dict(passed=issue is None, returncode=returncode, issue=issue,
                duration_seconds=round(time.monotonic()-start, 3), log=str(log))


def ready(app, helper, env, library):
    deadline, last = time.monotonic()+30, ""
    while time.monotonic() < deadline:
        if app.poll() is not None:
            raise RuntimeError(f"App exited before readiness: {app.returncode}")
        try:
            result = subprocess.run([str(helper), "--call", "form_status", "{}"],
                                    cwd=ROOT, env=env, text=True,
                                    capture_output=True, timeout=3)
            if result.returncode == 0:
                status = json.loads(result.stdout)
                actual = pathlib.Path(status["library_path"]).resolve()
                if actual != library:
                    raise RuntimeError(f"App library mismatch: {actual} != {library}")
                return status
            last = result.stderr.strip()
        except subprocess.TimeoutExpired:
            last = "Readiness call timed out"
        time.sleep(.1)
    raise RuntimeError("App did not become ready: "+last)


def independent_commands(name, output, python):
    scripts = ROOT/"scripts"
    if name == "garment_blocks":
        return [[str(python), str(scripts/"verify_garment_blocks.py"),
                 str(output/"garment-block-smoke")]]
    if name == "sewing_tiles":
        folder = output/"sewing-tiles-smoke"
        return [[str(python), str(scripts/"verify_sewing_tiles.py"),
                 str(path.with_name(path.name.removesuffix("-metadata.json")+".pdf")),
                 str(path), str(folder/"authoritative-source.pdf")]
                for path in sorted(folder.glob("*-metadata.json"))]
    if name == "collections":
        return [[str(python), str(scripts/"verify_collection_packet.py"), str(folder),
                 "--embroidery-python", str(python), "--render"]
                for folder in sorted(output.glob("collection45-*"))]
    if name == "production_inks":
        return [[str(python), str(scripts/"verify_production_inks.py"),
                 str(output/"production-inks-smoke-report.json")]]
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=ROOT/"build/LAB.app")
    parser.add_argument("--python", type=pathlib.Path, default=pathlib.Path(sys.executable))
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--only", nargs="+", choices=WORKFLOWS)
    parser.add_argument("--timeout", type=float, default=1800,
                        help="Per smoke/independent-reader timeout in seconds")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--sample-failures", action="store_true",
                        help="On failure, sample only this runner's still-running app PID before cleanup")
    args = parser.parse_args()
    if args.list:
        print("\n".join("scripts/smoke_"+name+".py" for name in WORKFLOWS))
        return
    assert args.timeout > 0
    app = args.app.resolve()
    info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
    executable = app/"Contents/MacOS"/info["CFBundleExecutable"]
    helper = app/"Contents/MacOS/lab-mcp"
    assert executable.is_file() and helper.is_file(), "Build and package LAB first."
    python = args.python.absolute()
    dependency_check = subprocess.run(
        [str(python), "-c", "import PIL,pypdf,importlib.metadata,json,sys;"
         "assert importlib.metadata.version('pyembroidery')=='1.5.1';"
         "print(json.dumps(dict(python=sys.version,Pillow=PIL.__version__,"
         "pypdf=pypdf.__version__,pyembroidery=importlib.metadata.version('pyembroidery'))))"],
        check=True, capture_output=True, text=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or ROOT/".local/validation"/("fabric-"+stamp)).resolve()
    assert output.is_relative_to((ROOT/".local").resolve()), "Use a private output under repo/.local."
    output.mkdir(parents=True, exist_ok=False)
    report = dict(app=str(app), app_sha256=sha(executable), mcp_sha256=sha(helper),
                  started_at=stamp, isolated_library_per_workflow=True,
                  hardware_calls=0, readers=json.loads(dependency_check.stdout), workflows=[])

    def save():
        report["passed"] = all(row["passed"] for row in report["workflows"])
        (output/"report.json").write_text(json.dumps(report, indent=2)+"\n")

    for name in args.only or WORKFLOWS:
        started = time.monotonic()
        folder = output/name
        folder.mkdir()
        artifacts = folder/"output"
        artifacts.mkdir()
        library = (folder/"Library").resolve()
        socket = pathlib.Path("/tmp")/("lab-fabric-"+uuid.uuid4().hex+".sock")
        env = dict(os.environ, LAB_LIBRARY_PATH=str(library), FORM_LIBRARY_PATH=str(library),
                   LAB_SOCKET_PATH=str(socket), FORM_SOCKET_PATH=str(socket),
                   LAB_MCP_PATH=str(helper), PYTHONUNBUFFERED="1")
        row = dict(name=name, script="scripts/smoke_"+name+".py", library=str(library),
                   socket=str(socket), output=str(artifacts), passed=False,
                   independent_readers=[])
        app_process = None
        try:
            with (folder/"app.log").open("w") as app_log:
                app_process = subprocess.Popen([str(executable)], cwd=ROOT, env=env,
                                               stdout=app_log, stderr=subprocess.STDOUT)
                row["app_pid"] = app_process.pid
                status = ready(app_process, helper, env, library)
                row["initial_project_id"] = status.get("project_id")
                row["smoke"] = command(
                    [str(python), "-c", SMOKE_WRAPPER,
                     str(ROOT/row["script"]), str(artifacts)], env,
                    folder/"smoke.log", args.timeout)
                row["passed"] = row["smoke"]["passed"]
                if row["passed"]:
                    readers = independent_commands(name, artifacts, python)
                    if name in ("sewing_tiles", "collections") and not readers:
                        raise RuntimeError("Smoke did not produce its independent-reader inputs.")
                    for index, argv in enumerate(readers):
                        outcome = command(argv, env, folder/f"reader-{index+1}.log", args.timeout)
                        row["independent_readers"].append(dict(command=argv, **outcome))
                        row["passed"] = row["passed"] and outcome["passed"]
        except Exception as error:
            row["issue"] = str(error)
            row["passed"] = False
        finally:
            if app_process is not None:
                row["app_exit_before_cleanup"]=app_process.poll()
                if args.sample_failures and not row["passed"] and app_process.poll() is None:
                    row["owned_app_sample"]=command(
                        ["/usr/bin/sample",str(app_process.pid),"3","-file",str(folder/"app.sample.txt")],
                        env,folder/"sample.log",15)
                    row["app_exit_after_sample"]=app_process.poll()
            stop(app_process,process_group=False)
            socket.unlink(missing_ok=True)
        row["duration_seconds"] = round(time.monotonic()-started, 3)
        report["workflows"].append(row)
        save()
        print(json.dumps(dict(name=name, passed=row["passed"],
                              duration_seconds=row["duration_seconds"],
                              log=str(folder/"smoke.log"), issue=row.get("issue"))),
              flush=True)
    print(json.dumps(dict(passed=report["passed"],
                          passed_workflows=sum(x["passed"] for x in report["workflows"]),
                          workflows=len(report["workflows"]), report=str(output/"report.json"))))
    sys.exit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
