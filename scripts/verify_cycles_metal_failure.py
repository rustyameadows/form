#!/usr/bin/env python3
"""Force an actual Metal compilation error in an isolated copy; keep original bundle intact."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
from verify_cycles_native import author


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=False)
    bundle = folder / "intentional-failure/LAB.app"
    shutil.copytree(args.bundle.resolve(), bundle)
    kernel = bundle / "Contents/Resources/Cycles/source/kernel/device/metal/kernel.metal"
    original = kernel.read_bytes()
    kernel.write_bytes(b"#error LAB_ISOLATED_METAL_INITIALIZATION_TEST\n" + original)
    manifest = author(folder, "metal")
    helper = bundle / "Contents/Helpers/lab-cycles-render"
    env = dict(PATH="/usr/bin:/bin", LAB_CYCLES_CACHE_DIR=str(folder / "cache"))
    results = {}
    for device in ("metal", "auto", "cpu"):
        manifest["device"] = device
        manifest["outputDirectory"] = "output-" + device
        path = folder / (device + ".json")
        path.write_text(json.dumps(manifest, indent=2) + "\n")
        run = subprocess.run([str(helper), "--render", str(path)], env=env, capture_output=True,
                             text=True, timeout=180)
        (folder / (device + "-events.jsonl")).write_text(run.stdout)
        (folder / (device + "-stderr.log")).write_text(run.stderr)
        events = [json.loads(line) for line in run.stdout.splitlines()]
        final = events[-1]
        if device == "cpu":
            assert run.returncode == 0 and final["type"] == "completed", final
            assert final["device"] == "cpu"
        else:
            assert run.returncode != 0 and final["type"] == "error", final
            assert final["device"] == "metal" and final["category"] == "metalInitialization", final
            assert "LAB_ISOLATED_METAL_INITIALIZATION_TEST" in final["message"], final
            assert not any(e["type"] == "completed" for e in events)
        results[device] = dict(returncode=run.returncode, finalType=final["type"],
                               category=final.get("category"), device=final["device"])
    assert (args.bundle / "Contents/Resources/Cycles/source/kernel/device/metal/kernel.metal").read_bytes() == original
    (folder / "report.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
