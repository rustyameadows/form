#!/usr/bin/env python3
"""Apply and verify the recorded fixes to the pinned OCCT build."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

REPOSITORY = Path(__file__).resolve().parent.parent
PROVENANCE = "FORM-OCCT-PROVENANCE.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def guarded_sources(entry):
    # Keep the existing one-file numeric patch representation readable while
    # requiring every target of a multi-file patch to have its own exact guard.
    targets = entry.get("sources")
    if targets is None:
        targets = [{key: entry[key] for key in
                    ("source", "source_before_sha256", "source_after_sha256")}]
    if not targets or len({target["source"] for target in targets}) != len(targets):
        raise RuntimeError("OCCT patch requires unique source checksum guards")
    for target in targets:
        path = Path(target["source"])
        if path.is_absolute() or ".." in path.parts:
            raise RuntimeError("OCCT patch target must stay inside its source tree")
    return targets


def expected():
    result = json.loads((REPOSITORY / "Sources/CFormCADKernel/UPSTREAM.json").read_text())
    for entry in result["patches"]:
        patch = REPOSITORY / entry["path"]
        if digest(patch) != entry["sha256"]:
            raise RuntimeError("Recorded OCCT patch digest mismatch")
        changed = {line[6:].split("\t", 1)[0] for line in patch.read_text().splitlines()
                   if line.startswith("+++ b/")}
        guarded = {target["source"] for target in guarded_sources(entry)}
        if changed != guarded:
            raise RuntimeError("Every OCCT patch target needs an exact checksum guard")
    return result


def apply(source):
    planned = []
    # Preflight the complete set first. A bad later patch cannot leave an
    # earlier patch applied to an otherwise unverified source tree.
    for entry in expected()["patches"]:
        states = []
        for target in guarded_sources(entry):
            current = digest(source / target["source"])
            if current == target["source_after_sha256"]:
                states.append("after")
            elif current == target["source_before_sha256"]:
                states.append("before")
            else:
                raise RuntimeError(f"Unexpected OCCT source content: {target['source']}")
        if len(set(states)) != 1:
            raise RuntimeError(f"Partially applied OCCT patch: {entry['path']}; restore its pinned source files")
        planned.append((entry, states[0]))
    for entry, state in planned:
        if state == "after":
            continue
        subprocess.run(["/usr/bin/patch", "--batch", "--fuzz=0", "-p1", "-i",
                        str(REPOSITORY / entry["path"])], cwd=source, check=True)
        for target in guarded_sources(entry):
            if digest(source / target["source"]) != target["source_after_sha256"]:
                raise RuntimeError("Patched OCCT source digest mismatch")


def verify_required_symbols(prefix, provenance):
    # A copied old library cannot acquire the new runtime tag merely because
    # somebody edited the source tree/provenance. The new adapter needs this ABI.
    for name, symbols in provenance.get("required_exported_symbols", {}).items():
        library = prefix / "lib" / name
        if Path(name).name != name or not library.is_file():
            raise RuntimeError(f"Missing required OCCT ABI library: {name}")
        exported = subprocess.check_output(["/usr/bin/nm", "-gU", str(library)], text=True)
        for symbol in symbols:
            if symbol not in exported:
                raise RuntimeError(f"OCCT library is missing required patched ABI {symbol}: {name}")


def record(prefix, source):
    provenance = expected()
    for entry in provenance["patches"]:
        for target in guarded_sources(entry):
            if digest(source / target["source"]) != target["source_after_sha256"]:
                raise RuntimeError("Cannot record an OCCT build from unpatched sources")
    verify_required_symbols(prefix, provenance)
    libraries = sorted({path.resolve() for path in (prefix / "lib").glob("libTK*.dylib")})
    if not libraries:
        raise RuntimeError("No installed OCCT libraries")
    provenance["installed_library_sha256"] = {path.name: digest(path) for path in libraries}
    (prefix / PROVENANCE).write_text(json.dumps(provenance, indent=2) + "\n")


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
    verify_required_symbols(prefix, recorded)


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
