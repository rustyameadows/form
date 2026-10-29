#!/usr/bin/env python3
"""Apply and verify the recorded numerical fixes to the pinned OCCT build."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


REPOSITORY = Path(__file__).resolve().parent.parent
PROVENANCE = "FORM-OCCT-PROVENANCE.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected():
    result = json.loads((REPOSITORY / "Sources/CFormCADKernel/UPSTREAM.json").read_text())
    for entry in result["patches"]:
        if digest(REPOSITORY / entry["path"]) != entry["sha256"]:
            raise RuntimeError("Recorded OCCT patch digest mismatch")
    return result


def apply(source):
    for entry in expected()["patches"]:
        patch = REPOSITORY / entry["path"]
        target = source / entry["source"]
        if digest(patch) != entry["sha256"]:
            raise RuntimeError("Recorded OCCT patch digest mismatch")
        current = digest(target)
        if current == entry["source_after_sha256"]:
            continue
        if current != entry["source_before_sha256"]:
            raise RuntimeError(f"Unexpected OCCT source content: {entry['source']}")
        subprocess.run(["/usr/bin/patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)],
                       cwd=source, check=True)
        if digest(target) != entry["source_after_sha256"]:
            raise RuntimeError("Patched OCCT source digest mismatch")


def record(prefix, source):
    for entry in expected()["patches"]:
        if digest(source / entry["source"]) != entry["source_after_sha256"]:
            raise RuntimeError("Cannot record an OCCT build from unpatched sources")
    libraries = sorted({path.resolve() for path in (prefix / "lib").glob("libTK*.dylib")})
    if not libraries:
        raise RuntimeError("No installed OCCT libraries")
    result = expected()
    result["installed_library_sha256"] = {path.name: digest(path) for path in libraries}
    (prefix / PROVENANCE).write_text(json.dumps(result, indent=2) + "\n")


def verify(prefix):
    path = prefix / PROVENANCE
    if not path.is_file():
        raise RuntimeError("Missing OCCT build provenance; run scripts/install-occt.sh")
    recorded = json.loads(path.read_text())
    libraries = recorded.pop("installed_library_sha256", {})
    if recorded != expected() or not libraries:
        raise RuntimeError("OCCT build does not match the pinned patches; run scripts/install-occt.sh")
    for name, sha256 in libraries.items():
        library = prefix / "lib" / name
        if Path(name).name != name or not library.is_file() or digest(library) != sha256:
            raise RuntimeError(f"OCCT installed library digest mismatch: {name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["apply", "record", "verify"])
    parser.add_argument("path", type=Path)
    parser.add_argument("source", type=Path, nargs="?")
    args = parser.parse_args()
    if args.command == "apply":
        apply(args.path.resolve())
    elif args.command == "record":
        if args.source is None:
            parser.error("record requires the pinned source directory")
        record(args.path.resolve(), args.source.resolve())
    else:
        verify(args.path.resolve())
