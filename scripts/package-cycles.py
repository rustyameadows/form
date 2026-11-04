#!/usr/bin/env python3
"""Record, verify and bundle the pinned private Cycles engine dependency closure."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Native/LabCycles/engine-lock.json"
DEFAULT_PREFIX = ROOT / ".local/engines/cycles-3eb35f85996b"
RECORD = "LAB-CYCLES-PROVENANCE.json"


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for data in iter(lambda: f.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def inputs():
    return sorted([p for p in (ROOT / "Native/LabCycles").rglob("*") if p.is_file()] +
                  [ROOT / "scripts/install-cycles.sh", ROOT / "scripts/package-cycles.py"])


def artifacts(prefix):
    return [prefix / "lab-cycles-render"] + sorted(
        p for folder in ("lib", "source", "license")
        for p in (prefix / folder).rglob("*") if p.is_file())


def record(prefix):
    lock = json.loads(LOCK.read_text())
    source = ROOT / ".local/cycles/source"
    for location, expected in ((source, lock["source_commit"]),
                               (source / "lib/macos_arm64", lock["dependency_commit"])):
        if run("git", "-C", location, "rev-parse", "HEAD") != expected:
            raise RuntimeError("Engine or dependency checkout differs from lock")
    integration = ('\n# LAB integration: adds the private helper, without modifying engine behavior.\n'
                   'if(LAB_CYCLES_HELPER_SOURCE)\n'
                   '  add_subdirectory("${LAB_CYCLES_HELPER_SOURCE}" lab-helper)\nendif()\n')
    original_cmake = subprocess.check_output(["git", "-C", str(source), "show",
                                              lock["source_commit"] + ":CMakeLists.txt"])
    if (source / "CMakeLists.txt").read_bytes() != original_cmake + integration.encode():
        raise RuntimeError("Unexpected changes to pinned Cycles build integration")
    if run("git", "-C", source, "diff", "--name-only", "HEAD") != "CMakeLists.txt":
        raise RuntimeError("Unrecorded changes to pinned Cycles sources")
    if run("git", "-C", source / "lib/macos_arm64", "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("Unrecorded changes to pinned Cycles dependencies")
    # Keep complete upstream attribution and exact original engine sources available.
    archive = prefix / "cycles-source.tar.gz"
    subprocess.check_call(["git", "-C", str(source), "archive", "--format=tar.gz",
                           "-o", str(archive), lock["source_commit"]])
    manifest = dict(lock)
    compiler = Path(run("xcrun", "--find", "clang++")).resolve()
    manifest.update({
        "compiler": run("xcrun", "clang++", "--version"),
        "compiler_binary_sha256": digest(compiler),
        "sdk": run("xcrun", "--show-sdk-version"),
        "source_archive_sha256": digest(archive),
        "source_inputs": {str(p.relative_to(ROOT)): digest(p) for p in inputs()},
        "installed_files": {str(p.relative_to(prefix)): digest(p) for p in artifacts(prefix)},
        "dependency_git_tree": run("git", "-C", source / "lib/macos_arm64", "rev-parse", "HEAD^{tree}"),
        "features": ["cpu", "metal", "openimagedenoise", "opensubdiv", "openimageio", "opencolorio"],
        "cmake_cache_sha256": digest(ROOT / ".local/cycles/build/CMakeCache.txt"),
    })
    (prefix / RECORD).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Recorded {len(manifest['installed_files'])} pinned Cycles runtime files")


def verify(prefix):
    path = prefix / RECORD
    if not path.is_file():
        raise RuntimeError("Pinned Cycles is not installed; run scripts/install-cycles.sh")
    manifest = json.loads(path.read_text())
    for key, expected in json.loads(LOCK.read_text()).items():
        if manifest.get(key) != expected:
            raise RuntimeError(f"Cycles lock mismatch: {key}")
    if set(manifest["source_inputs"]) != {str(p.relative_to(ROOT)) for p in inputs()}:
        raise RuntimeError("Cycles helper source set changed; rebuild engine")
    for name, expected in manifest["source_inputs"].items():
        path = ROOT / name
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError(f"Cycles helper source changed; rebuild engine: {name}")
    for name, expected in manifest["installed_files"].items():
        path = prefix / name
        if not path.is_file() or not path.resolve().is_relative_to(prefix.resolve()) or digest(path) != expected:
            raise RuntimeError(f"Cycles runtime integrity mismatch: {name}")
    if digest(prefix / "cycles-source.tar.gz") != manifest["source_archive_sha256"]:
        raise RuntimeError("Cycles source archive integrity mismatch")
    return manifest


def dependencies(binary):
    names = [line.strip().split(" (", 1)[0] for line in run("otool", "-L", binary).splitlines()[1:]]
    # A dylib's first entry is its LC_ID_DYLIB, not a dependency.
    if binary.suffix == ".dylib" and names and Path(names[0]).name == binary.name:
        names = names[1:]
    return names


def rpaths(binary):
    lines = run("otool", "-l", binary).splitlines()
    return [lines[i + 2].strip().split("path ", 1)[1].rsplit(" (offset ", 1)[0]
            for i, line in enumerate(lines) if line.strip() == "cmd LC_RPATH"]


def system(path):
    return path.startswith(("/usr/lib/", "/System/Library/"))


def package(bundle, prefix):
    manifest = verify(prefix)
    helper = bundle / "Contents/Helpers/lab-cycles-render"
    libraries = bundle / "Contents/Frameworks/Cycles"
    resources = bundle / "Contents/Resources/Cycles"
    notices = bundle / "Contents/Resources/ThirdPartyNotices/Cycles"
    for folder in (helper.parent, libraries, resources, notices):
        folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prefix / "lab-cycles-render", helper)
    # Include OIDN's dynamically loaded backend modules, which otool alone cannot discover.
    copied = {}
    for source in sorted((prefix / "lib").glob("*.dylib")):
        if not source.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError(f"Unpinned renderer library: {source}")
        destination = libraries / source.name
        shutil.copy2(source.resolve(), destination)
        copied[source.name] = destination
    all_binaries = [*copied.values(), helper]
    for binary in all_binaries:
        for dependency in dependencies(binary):
            if system(dependency):
                continue
            name = Path(dependency).name
            if name not in copied:
                raise RuntimeError(f"Unpackaged Cycles dependency: {dependency}")
            new_name = ("@loader_path/../Frameworks/Cycles/" if binary == helper else "@loader_path/") + name
            subprocess.check_call(["install_name_tool", "-change", dependency, new_name, str(binary)])
        if binary != helper:
            subprocess.check_call(["install_name_tool", "-id", "@rpath/" + binary.name, str(binary)])
        for path in rpaths(binary):
            if path.startswith("/") and not system(path):
                subprocess.check_call(["install_name_tool", "-delete_rpath", path, str(binary)])
        desired = "@loader_path/../Frameworks/Cycles" if binary == helper else "@loader_path"
        if desired not in rpaths(binary):
            subprocess.check_call(["install_name_tool", "-add_rpath", desired, str(binary)])
    shutil.copytree(prefix / "source", resources / "source", dirs_exist_ok=True)
    # This is a code companion, not an unused OCIO look presented as a runtime
    # transform. Its source hash is part of the verified provenance.
    color_configuration = ROOT / "Native/LabCycles/LAB-sRGB-v1.json"
    if json.loads(color_configuration.read_text())["id"] != manifest["display_transform"]:
        raise RuntimeError("Bundled color configuration differs from the pinned display transform")
    shutil.copy2(color_configuration, resources / color_configuration.name)
    shutil.copytree(prefix / "license", notices / "engine-licenses", dirs_exist_ok=True)
    shutil.copytree(ROOT / "Native/LabCycles/ThirdPartyNotices", notices / "dependency-licenses", dirs_exist_ok=True)
    for name in (RECORD, "cycles-source.tar.gz"):
        shutil.copy2(prefix / name, notices / name)
    shutil.copy2(LOCK, notices / "engine-lock.json")
    for name in ("install-cycles.sh", "package-cycles.py"):
        shutil.copy2(ROOT / "scripts" / name, notices / name)
    shutil.copy2(ROOT / ".local/cycles/source/lib/macos_arm64/deps.md", notices / "upstream-dependency-versions.md")
    (notices / "BUNDLED-LIBRARIES.json").write_text(json.dumps(sorted(copied), indent=2) + "\n")
    for binary in all_binaries:
        subprocess.check_call(["codesign", "--force", "--sign", "-", str(binary)], stdout=subprocess.DEVNULL)
        for dependency in dependencies(binary):
            if not system(dependency) and not dependency.startswith("@loader_path/"):
                raise RuntimeError(f"Nonportable renderer linkage: {dependency}")
    print(f"Bundled Cycles {manifest['source_commit'][:12]}, {len(copied)} private libraries and runtime kernels")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", nargs="?", type=Path)
    parser.add_argument("prefix", nargs="?", type=Path, default=DEFAULT_PREFIX)
    parser.add_argument("--record", type=Path)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.record:
        record(args.record.resolve())
    elif args.verify:
        verify(args.verify.resolve())
        print("Pinned Cycles runtime verified")
    elif args.bundle:
        package(args.bundle.resolve(), args.prefix.resolve())
    else:
        parser.error("Provide a bundle path, --record or --verify")
