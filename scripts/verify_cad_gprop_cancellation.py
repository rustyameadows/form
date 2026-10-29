#!/usr/bin/env python3
"""Verify real native GProp cancellation and uncancelled old/new bit identity.

Compiles standalone Tests/Native programs; does not build the app or change either
engine prefix. Every output belongs to a fresh ignored workspace directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
LIBRARIES = ["TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKBRep",
             "TKGeomAlgo", "TKTopAlgo", "TKPrim", "TKBO", "TKBool", "TKFillet",
             "TKOffset", "TKMesh", "TKShHealing", "TKXSBase", "TKDESTEP",
             "TKLCAF", "TKCAF", "TKXCAF", "TKCDF"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def library_hashes(prefix):
    return {p.name: sha(p) for p in sorted((prefix / "lib").glob("*.8.0.1.dylib"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path(os.environ.get(
        "LAB_OCCT_ROOT", ROOT / ".local/engines/occt-8.0.1-form-gprop2")))
    parser.add_argument("--old-prefix", type=Path,
                        default=ROOT / ".local/engines/occt-8.0.1")
    parser.add_argument("--fixture", type=Path, action="append", default=[],
                        help="Additional exact BRep; also exercises in-GProp cancellation.")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=180,
                        help="Per native command, recorded without silent retries.")
    args = parser.parse_args()
    prefix, old = args.prefix.resolve(), args.old_prefix.resolve()
    output = args.output.resolve()
    assert prefix != old, "Old and patched prefixes must be distinct."
    assert output.is_relative_to(ROOT / ".local"), "Use a new ignored .local output directory."
    assert 1 <= args.timeout <= 600, "Choose a finite explicit native command budget."
    assert (old / "lib/libTKTopAlgo.dylib").is_file()
    assert (prefix / "lib/libTKTopAlgo.dylib").is_file()
    output.mkdir(parents=True, exist_ok=False)
    binaries, fixtures = output / "bin", output / "fixtures"
    binaries.mkdir(); fixtures.mkdir()
    original_hashes = {"old": library_hashes(old), "patched": library_hashes(prefix)}
    report = dict(status="running", old_prefix=str(old), patched_prefix=str(prefix),
                  epsilon=1e-9, numeric_algorithm_or_tolerance_changes=False,
                  libraries_before=original_hashes, commands=[], cancellation=[], fixtures=[])

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def invoke(name, command, env=None):
        started = time.monotonic()
        entry = dict(name=name, args=[str(p) for p in command],
                     timeout_seconds=args.timeout)
        try:
            result = subprocess.run(entry["args"], text=True, capture_output=True,
                                    env=env, timeout=args.timeout)
            entry.update(returncode=result.returncode, seconds=time.monotonic() - started)
            (output / (name + ".stdout")).write_text(result.stdout)
            (output / (name + ".stderr")).write_text(result.stderr)
        except subprocess.TimeoutExpired as error:
            entry.update(timed_out=True, seconds=time.monotonic() - started)
            for field in ("stdout", "stderr"):
                data = getattr(error, field) or ""
                if isinstance(data, bytes):
                    data = data.decode(errors="replace")
                (output / (name + "." + field)).write_text(data)
            report["commands"].append(entry); save()
            raise
        report["commands"].append(entry); save()
        assert result.returncode == 0, (name, result.returncode, result.stderr)
        return result, entry

    save()
    try:
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        compiler = subprocess.check_output(["xcrun", "--find", "clang++"], text=True).strip()
        environment = os.environ.copy()
        environment["CPLUS_INCLUDE_PATH"] = sdk + "/usr/include/c++/v1"
        common = [compiler, "-std=c++17", "-O2", "-fexceptions", "-arch", "arm64",
                  "-isysroot", sdk, "-mmacosx-version-min=14.0"]
        native = ROOT / "Tests/Native"
        adapter = ROOT / "Sources/CFormCADKernel/FormCADKernel.cpp"
        report["source_sha256"] = {str(p.relative_to(ROOT)): sha(p) for p in
                                  [adapter, native / "CADGPropCancellation.cpp",
                                   native / "CADGPropNumericControl.cpp",
                                   native / "CADGPropAnalyticFixtures.cpp"]}
        programs = [
            ("numeric-old", "CADGPropNumericControl.cpp", old, []),
            ("numeric-new", "CADGPropNumericControl.cpp", prefix, []),
            ("numeric-new-production-probe", "CADGPropNumericControl.cpp", prefix,
             ['-DADAPTER_SOURCE="' + str(adapter) + '"',
              "-I" + str(adapter.parent / "include")]),
            ("analytic-fixtures", "CADGPropAnalyticFixtures.cpp", old, []),
            ("cancel-probe", "CADGPropCancellation.cpp", prefix,
             ["-I" + str(adapter.parent / "include")])]
        for name, source, engine, extra in programs:
            command = common + ["-I" + str(engine / "include/opencascade")] + extra
            command += [str(native / source), "-L" + str(engine / "lib"),
                        "-Wl,-rpath," + str(engine / "lib")]
            command += ["-l" + library for library in LIBRARIES] + ["-o", str(binaries / name)]
            invoke("compile-" + name, command, environment)
        report["binaries_sha256"] = {p.name: sha(p) for p in binaries.iterdir()}
        invoke("make-analytic-fixtures", [binaries / "analytic-fixtures", fixtures])
        versioned = ROOT / "Tests/FormCADKernelTests/Fixtures"
        holed = versioned / "offset-bspline-holed.brep"
        paths = sorted(fixtures.glob("*.brep")) + [
            holed, versioned / "offset-bspline-holed-reversed.brep"]
        extra = [p.resolve() for p in args.fixture]
        paths.extend(extra)
        for index, path in enumerate([holed] + extra):
            name = "cancel-" + str(index) + "-" + path.stem
            result, timing = invoke(name, [binaries / "cancel-probe", path])
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            assert len(rows) == 3
            assert all(r["status"] == 6 and r["polls"] == 50 and r["source_unchanged"]
                       and r["output_unpublished"] for r in rows[:2])
            assert all(rows[2].values()), rows[2]
            report["cancellation"].append(dict(fixture=str(path), sha256=sha(path),
                                               seconds=timing["seconds"], results=rows))
            save(); print(name, "PASS", flush=True)
        for index, path in enumerate(paths):
            name = str(index) + "-" + path.stem
            row = dict(name=name, fixture=str(path), input_sha256=sha(path), variants=[])
            outputs, serialized = [], []
            for variant in ("numeric-old", "numeric-new", "numeric-new-production-probe"):
                dump = output / (name + "-" + variant + ".brep")
                result, timing = invoke(name + "-" + variant, [binaries / variant, path, dump])
                tokens = result.stdout.split()
                assert len(tokens) == 26 and all(len(t) == 16 and int(t, 16) >= 0 for t in tokens)
                outputs.append(result.stdout); serialized.append(dump.read_bytes())
                row["variants"].append(dict(name=variant, seconds=timing["seconds"],
                    numeric_stdout_sha256=hashlib.sha256(result.stdout.encode()).hexdigest(),
                    serialized_brep_sha256=sha(dump), probe_evidence=result.stderr.strip()))
            row.update(all_26_double_bit_patterns_identical=outputs[0] == outputs[1] == outputs[2],
                       serialized_brep_bytes_identical=serialized[0] == serialized[1] == serialized[2],
                       input_file_unchanged=sha(path) == row["input_sha256"])
            assert all(row[k] for k in ("all_26_double_bit_patterns_identical",
                       "serialized_brep_bytes_identical", "input_file_unchanged")), row
            report["fixtures"].append(row); save()
            print(name, "old/null/production-probe bit+BRep identity PASS", flush=True)
        report["prefixes_unchanged"] = original_hashes == {
            "old": library_hashes(old), "patched": library_hashes(prefix)}
        assert report["prefixes_unchanged"]
        report["status"] = "passed"; save()
        print(json.dumps(dict(status="passed", fixtures=len(paths), report=str(output / "report.json"))))
    except Exception as error:
        report.update(status="failed", error=str(error)); save()
        raise


if __name__ == "__main__":
    main()
