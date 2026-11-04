#!/usr/bin/env python3
"""Audit a relocated LAB bundle and render with empty LAB caches and minimal environment.

Never launches LAB. Invoke under sandbox-exec with `(deny network*)` for the offline
gate; Metal access itself requires a host process allowed to access the GPU.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device", choices=["cpu", "metal"], default="cpu")
    parser.add_argument("--require-app", action="store_true")
    parser.add_argument("--deny-development", action="store_true",
                        help="Deny helper network and reads from source/build/deps/Homebrew/Xcode; audit tools stay outside the sandbox")
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    helper = bundle / "Contents/Helpers/lab-cycles-render"
    if args.require_app:
        assert (bundle / "Contents/Info.plist").is_file(), "Full LAB bundle required"
        assert (bundle / "Contents/MacOS/LAB").is_file(), "LAB executable missing"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    roots = [helper, bundle / "Contents/Frameworks/Cycles", bundle / "Contents/Resources/Cycles",
             bundle / "Contents/Resources/ThirdPartyNotices/Cycles"]
    files = [p for root in roots for p in ([root] if root.is_file() else sorted(root.rglob("*"))) if p.is_file()]
    before = {str(p.relative_to(bundle)): digest(p) for p in files}
    assert before and helper.is_file()
    color_configuration = bundle / "Contents/Resources/Cycles/LAB-sRGB-v1.json"
    configuration = json.loads(color_configuration.read_text())
    provenance = json.loads((bundle / "Contents/Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json").read_text())
    assert configuration["id"] == provenance["display_transform"] == "LAB-sRGB-v1"
    assert configuration["loadedByRenderer"] is False and configuration["png"]["sameTransformForPreviewAndFinal"] is True
    assert digest(color_configuration) == provenance["source_inputs"]["Native/LabCycles/LAB-sRGB-v1.json"], "Bundled display-transform companion differs from provenance"
    libraries = sorted((bundle / "Contents/Frameworks/Cycles").glob("*.dylib"))
    for binary in [helper, *libraries]:
        subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
        lines = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
        names = [line.strip().split(" (", 1)[0] for line in lines]
        if binary != helper:
            names = names[1:]  # LC_ID_DYLIB
        for name in names:
            if name.startswith(("/System/Library/", "/usr/lib/")):
                continue
            assert name.startswith("@loader_path/"), f"External dependency: {name}"
            resolved = (binary.parent / name.removeprefix("@loader_path/")).resolve()
            assert resolved.is_relative_to(bundle) and resolved.is_file(), name
    native_command = [sys.executable, str(Path(__file__).with_name("verify_cycles_native.py")),
                      "--helper", str(helper), "--output", str(output), "--device", args.device]
    denied, probes = [], []
    profile = None
    if args.deny_development:
        repository = Path(__file__).resolve().parent.parent
        denied = [repository / ".local/cycles", repository / ".local/engines", repository / ".build",
                  Path("/opt/homebrew"), Path("/Applications/Xcode.app"), Path("/Library/Developer")]
        assert not any(bundle.is_relative_to(p) or output.is_relative_to(p) for p in denied), "Bundle and evidence must be outside denied development paths"
        output.parent.mkdir(parents=True, exist_ok=True)
        profile = output.with_suffix(".sb")
        assert not profile.exists(), "Retain previous sandbox evidence; choose a new output"
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n' +
                           '\n'.join('(deny file-read* (subpath ' + json.dumps(str(p)) + '))' for p in denied) + '\n')
        candidates = [repository / ".local/cycles/source/LICENSE",
                      repository / ".local/cycles/build/CMakeCache.txt",
                      repository / ".local/cycles/source/lib/macos_arm64/deps.md",
                      repository / ".local/engines/cycles-3eb35f85996b/lab-cycles-render",
                      repository / ".build/workspace-state.json", Path("/opt/homebrew/bin/brew"),
                      Path("/Applications/Xcode.app/Contents/Info.plist")]
        for path in candidates:
            assert path.is_file(), f"Sandbox read probe needs an existing development file: {path}"
            probe = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), "/usr/bin/head", "-c", "1", str(path)], capture_output=True)
            assert probe.returncode != 0 and b"Operation not permitted" in probe.stderr, f"Development read was not denied: {path}"
            probes.append(dict(path=str(path), readDenied=True))
        native_command.extend(["--helper-sandbox-profile", str(profile)])
    subprocess.run(native_command, check=True)
    after = {str(p.relative_to(bundle)): digest(p) for p in files}
    assert before == after, "Renderer modified its signed bundle"
    assert sorted(str(p) for root in roots for p in ([root] if root.is_file() else sorted(root.rglob("*"))) if p.is_file()) == sorted(str(p) for p in files), "Renderer wrote files inside its bundle"
    report = dict(bundle=str(bundle), fullApplication=args.require_app, runtimeFiles=len(files),
                  bundledLibraries=len(libraries), device=args.device, runtimeUnchanged=True,
                  cacheDirectory=str(output / "cache"), cleanEnvironment=True,
                  externalRuntimeDependencies=False, deniedDevelopmentPaths=[str(p) for p in denied],
                  deniedReadProbes=probes, networkDenied=args.deny_development,
                  helperSandboxProfile=str(profile) if profile else None)
    (output / "bundle-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
