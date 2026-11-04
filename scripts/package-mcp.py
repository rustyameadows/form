#!/usr/bin/env python3
"""Record the packaged helper's exact offline catalog and build provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def package(bundle, configuration, repository):
    helper = bundle / "Contents/MacOS/lab-mcp"
    # --catalog is deliberately offline: it never reads projects or the socket.
    raw = subprocess.check_output([str(helper.resolve()), "--catalog"])
    try:
        catalog = json.loads(raw)
    except (ValueError, UnicodeError) as error:
        raise RuntimeError("Packaged helper did not return valid catalog JSON") from error
    if not isinstance(catalog, dict) or not catalog.get("schema_fingerprint") or not catalog.get("tools"):
        raise RuntimeError("Packaged helper did not return an authoritative catalog")
    # The offline CLI prints readable JSON. Bound the actual bundled data,
    # preserving every tool/schema value and its authoritative fingerprint.
    data = json.dumps(catalog, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(data) > 1024 * 1024:
        raise RuntimeError("Packaged MCP catalog exceeds 1 MiB")
    try:
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
        dirty = bool(subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"],
            cwd=repository, text=True).strip())
    except (OSError, subprocess.CalledProcessError):
        revision, dirty = None, None
    manifest = {
        "format_version": 1,
        "configuration": configuration,
        "source_revision": revision,
        "source_dirty": dirty,
        "schema_fingerprint": catalog["schema_fingerprint"],
        "app_pre_package_signing_sha256": digest(bundle / "Contents/MacOS/LAB"),
        "helper_pre_package_signing_sha256": digest(helper),
    }
    encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    manifest["build_id"] = "sha256:" + hashlib.sha256(encoded).hexdigest()
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "MCP-CATALOG.json").write_bytes(data)
    (resources / "LABBuild.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("configuration", choices=["debug", "release"])
    args = parser.parse_args()
    package(args.bundle.resolve(), args.configuration, Path(__file__).resolve().parent.parent)
