#!/usr/bin/env python3
"""Bundle only the pinned OCCT dependency closure and remove workspace linkage."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(binary):
    return [line.strip().split(" (", 1)[0]
            for line in run("otool", "-L", str(binary)).splitlines()[1:]]


def package(bundle, prefix, repository):
    subprocess.check_call([sys.executable, str(repository / "scripts/occt-patches.py"),
                           "verify", str(prefix)])
    executable = bundle / "Contents/MacOS/LAB"
    frameworks = bundle / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    queue = [executable]
    copied = {}
    while queue:
        binary = queue.pop()
        for dependency in dependencies(binary):
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            filename = Path(dependency).name
            if filename.startswith("libswift") and dependency.startswith("@rpath/"):
                continue
            if not filename.startswith("libTK") or not filename.endswith(".dylib"):
                raise RuntimeError(f"Unpackaged non-system dependency: {dependency}")
            source = prefix / "lib" / filename
            if not source.is_file() or not source.resolve().is_relative_to(prefix.resolve()):
                raise RuntimeError(f"Missing pinned OCCT library: {filename}")
            if filename not in copied:
                destination = frameworks / filename
                shutil.copyfile(source.resolve(), destination)
                destination.chmod(0o755)
                copied[filename] = destination
                queue.append(destination)
    for filename, binary in copied.items():
        subprocess.check_call(["install_name_tool", "-id", "@rpath/" + filename, str(binary)])
        for dependency in dependencies(binary):
            name = Path(dependency).name
            if name in copied and dependency != "@loader_path/" + name:
                subprocess.check_call(["install_name_tool", "-change", dependency,
                                       "@loader_path/" + name, str(binary)])
    # SwiftPM's development rpath must not remain as a fallback in the app.
    commands = run("otool", "-l", str(executable)).splitlines()
    paths = [commands[i + 2].strip().split("path ", 1)[1].rsplit(" (offset ", 1)[0]
             for i, line in enumerate(commands) if line.strip() == "cmd LC_RPATH"]
    for path in paths:
        if path.startswith("/") and not path.startswith(("/usr/lib/", "/System/Library/")):
            subprocess.check_call(["install_name_tool", "-delete_rpath", path, str(executable)])
    if "@executable_path/../Frameworks" not in paths:
        subprocess.check_call(["install_name_tool", "-add_rpath",
                               "@executable_path/../Frameworks", str(executable)])
    resources = bundle / "Contents/Resources"
    shutil.copytree(prefix / "share/opencascade/resources", resources / "OCCT")
    notices = resources / "ThirdPartyNotices/OCCT"
    notices.mkdir(parents=True, exist_ok=True)
    for filename in ("LICENSE_LGPL_21.txt", "OCCT_LGPL_EXCEPTION.txt", "UPSTREAM.json"):
        shutil.copyfile(repository / "Sources/CFormCADKernel" / filename, notices / filename)
    for filename in ("install-occt.sh", "package-occt.py", "occt-patches.py"):
        shutil.copyfile(repository / "scripts" / filename, notices / filename)
    shutil.copytree(repository / "scripts/patches", notices / "patches")
    shutil.copyfile(prefix / "FORM-OCCT-PROVENANCE.json", notices / "BUILD-PROVENANCE.json")
    shutil.copyfile(repository / "docs/cad-kernel.md", notices / "BUILD-AND-LICENSE.md")
    archive = repository / ".local/cad-kernel/OCCT-V8_0_1.tar.gz"
    provenance = json.loads((notices / "UPSTREAM.json").read_text())
    import hashlib
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != provenance["archive_sha256"]:
        raise RuntimeError("The exact corresponding OCCT source archive is required for packaging")
    shutil.copyfile(archive, notices / archive.name)
    (notices / "BUNDLED-LIBRARIES.json").write_text(json.dumps(sorted(copied), indent=2) + "\n")
    # Each dylib is replaceable independently; sign inside out before the app.
    for binary in copied.values():
        subprocess.check_call(["codesign", "--force", "--sign", "-", str(binary)])
    print(f"Bundled {len(copied)} pinned OCCT shared libraries")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()
    package(args.bundle.resolve(), args.prefix.resolve(), Path(__file__).resolve().parent.parent)
