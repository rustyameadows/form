#!/usr/bin/env python3
"""Measure the real edit-to-image loop against an already running LAB app.

Use the same --fixtures file, quality, view and image dimensions on both builds.
Works with the original form_cad commands so before/after results are comparable.
Launch LAB against an isolated library; this script creates private CAD reviews
and cancels them, never commits models or changes the project.
"""
import argparse
import hashlib
import json
import math
import pathlib
import platform
import subprocess
import time
import uuid


ROOT = pathlib.Path(__file__).resolve().parents[1]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def summary(values):
    ordered = sorted(values)
    return {"median_ms": round((ordered[(len(ordered)-1)//2] + ordered[len(ordered)//2])/2, 3),
            "p95_ms": round(ordered[max(0, math.ceil(len(ordered)*.95)-1)], 3), "samples": len(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mcp-path", type=pathlib.Path, default=ROOT/"build/LAB.app/Contents/MacOS/lab-mcp")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--fixtures", type=pathlib.Path, required=True)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--quality", choices=["preview", "inspection", "fabrication"], default="preview")
    parser.add_argument("--view", choices=["front", "top", "perspective"], default="front")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--app-pid", type=int, help="Tracked app PID for RSS snapshots outside timed spans.")
    parser.add_argument("--staging-root", type=pathlib.Path,
                        help="Private app temporary root; count its lab-cad-* review files outside timed spans.")
    args = parser.parse_args()
    if not 1 <= args.iterations <= 100:
        parser.error("Use 1–100 iterations.")
    if args.app_pid is not None and args.app_pid <= 0:
        parser.error("app-pid must be a positive process ID.")
    args.output.mkdir(parents=True, exist_ok=False)
    submissions = 0

    def resources():
        sample = {}
        if args.app_pid is not None:
            result = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(args.app_pid)],
                                    capture_output=True, text=True, timeout=10, check=True)
            sample["app_rss_bytes"] = int(result.stdout.strip())*1024
        if args.staging_root is not None:
            folders = [path for path in args.staging_root.glob("lab-cad-*") if path.is_dir() and not path.is_symlink()]
            files = [path for folder in folders for path in folder.rglob("*") if path.is_file() and not path.is_symlink()]
            sample["staged_review_folders"] = len(folders)
            sample["staged_review_files"] = len(files)
            sample["staged_review_bytes"] = sum(path.stat().st_size for path in files)
        return sample

    def call(command, **fields):
        nonlocal submissions
        submissions += 1
        result = subprocess.run([str(args.mcp_path.resolve()), "--call", "form_cad",
                                 json.dumps({"command": command, **fields})], capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return json.loads(result.stdout)

    def ready(job, image=None):
        deadline = time.monotonic() + 120
        while True:
            if job["state"] in ["failed", "cancelled"]:
                raise RuntimeError(json.dumps(job))
            if job["state"] == "ready" and (image is None or job.get("result", {}).get("path") == str(image)):
                return job
            if time.monotonic() > deadline:
                raise TimeoutError(json.dumps(job))
            time.sleep(.01)
            job = call("status", job_id=job["job_id"])

    if args.fixtures.exists():
        fixtures = json.loads(args.fixtures.read_text())
    else:
        fixtures = []
        for template, parameter in [("enclosure", "width"), ("clockEnclosure", "diameter"), ("vase", "height")]:
            definition = call("plan", template=template)["definition"]
            ids = [definition["id"]] + [feature["id"] for feature in definition["features"]]
            remap = {source: str(uuid.uuid5(uuid.NAMESPACE_URL, f"lab-agent-benchmark:{template}:{index}"))
                     for index, source in enumerate(ids)}

            def stable(value):
                if isinstance(value, dict):
                    return {key: stable(item) for key, item in value.items()}
                if isinstance(value, list):
                    return [stable(item) for item in value]
                return remap.get(value, value) if isinstance(value, str) else value

            fixtures.append({"name": template, "parameter": parameter, "definition": stable(definition)})
        args.fixtures.parent.mkdir(parents=True, exist_ok=True)
        args.fixtures.write_text(json.dumps(fixtures, indent=2) + "\n")

    try:
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        revision = None
    report = {"benchmark": "form_cad legacy-compatible edit-to-image", "checkout_revision": revision,
              "executable_sha256": hashlib.sha256(args.mcp_path.read_bytes()).hexdigest(),
              "host": {"platform": platform.platform(), "machine": platform.machine()},
              "quality": args.quality, "view": args.view, "image_dimensions": [args.width, args.height],
              "fixture_sha256": hashlib.sha256(canonical(fixtures)).hexdigest(),
              "resource_sampling": {"app_pid": args.app_pid,
                  "staging_root": str(args.staging_root) if args.staging_root else None,
                  "method": "RSS and review-file snapshots before/after each case, outside all timed evaluation/render spans; not continuous peak memory."},
              "cases": []}
    all_samples = []
    for fixture in fixtures:
        definition = fixture["definition"]
        nominal = next(item["value"] for item in definition["parameters"] if item["name"] == fixture["parameter"])
        job = None
        try:
            before_resources = resources()
            cold_start = time.perf_counter()
            job = ready(call("create", definition=definition, quality=args.quality))
            cold_ms = (time.perf_counter()-cold_start)*1000
            samples = []
            for iteration in range(args.iterations):
                previous = job["job_id"]
                image = (args.output/f"{fixture['name']}-{iteration+1:02}.png").resolve()
                initial_submissions = submissions
                start = time.perf_counter()
                job = ready(call("parameter", job_id=previous, name=fixture["parameter"], value=nominal+iteration+1, quality=args.quality))
                evaluated_ms = (time.perf_counter()-start)*1000
                call("render", job_id=job["job_id"], path=str(image), view=args.view, width=args.width, height=args.height)
                job = ready(call("status", job_id=job["job_id"]), image=image)
                elapsed_ms = (time.perf_counter()-start)*1000
                samples.append({"parameter_value": nominal+iteration+1, "evaluation_ms": round(evaluated_ms, 3),
                                "edit_to_evidence_ms": round(elapsed_ms, 3), "submissions": submissions-initial_submissions,
                                "revision": job.get("revision"), "rebuilt_features": job.get("rebuilt_features"),
                                "timings_ms": job.get("timings_ms"), "image": str(image)})
                # New runtimes may retire superseded reviews automatically.
                try:
                    call("cancel", job_id=previous)
                except RuntimeError:
                    pass
            values = [sample["edit_to_evidence_ms"] for sample in samples]
            all_samples.extend(values)
            case = {"name": fixture["name"], "definition_sha256": hashlib.sha256(canonical(definition)).hexdigest(),
                    "cold_evaluation_ms": round(cold_ms, 3), "summary": summary(values), "iterations": samples,
                    "resources_before": before_resources, "resources_after": resources()}
            report["cases"].append(case)
            print(json.dumps({"name": fixture["name"], **case["summary"]}), flush=True)
        finally:
            if job:
                try:
                    call("cancel", job_id=job["job_id"])
                except RuntimeError:
                    pass
    report["aggregate"] = summary(all_samples)
    report["tool_submissions"] = submissions
    (args.output/"report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["aggregate"]), flush=True)


if __name__ == "__main__":
    main()
