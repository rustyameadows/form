#!/usr/bin/env python3
"""Exercise the actual bundled Cycles helper with generic geometry and shader channels.

No application launch, document mutation, external renderer or hardware command.
Retains immutable input manifests, images and protocol evidence in --output.
"""
import argparse
import array
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time


def identity(x=0, y=0, z=0):
    return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]


def author(folder, device):
    sequence = 0

    def buffer(values, kind, width=1):
        nonlocal sequence
        sequence += 1
        data = array.array(kind, values)
        if sys.byteorder != "little":
            data.byteswap()
        path = f"buffer-{sequence}.bin"
        (folder / path).write_bytes(data.tobytes())
        return dict(path=path, count=len(data) // width)

    def texture(name, fn, encoding="linear"):
        width = height = 32
        pixels = [value for y in range(height) for x in range(width) for value in fn(x, y)]
        data = array.array("f", pixels)
        if sys.byteorder != "little":
            data.byteswap()
        (folder / (name + ".rgba32f")).write_bytes(data.tobytes())
        return dict(path=name + ".rgba32f", format="rgba32f", width=width, height=height,
                    colorSpace=encoding, channel="rgba", uvIndex=0, wrapS="repeat", wrapT="clamp")

    base = texture("base", lambda x, y: (0.2 + x / 40, 0.15 + y / 40, 0.35, 1))
    artwork = texture("artwork", lambda x, y: (0.95, 0.08, 0.025, 1 if 10 < x < 22 and 6 < y < 26 else 0))
    normal = texture("normal", lambda x, y: (0.5 + 0.1 * math.sin(x), 0.5, 1, 1))
    height = texture("height", lambda x, y: (0.5 + 0.3 * math.sin(x / 2),) * 3 + (1,))
    mask = texture("mask", lambda x, y: (float(x < 16),) * 3 + (1,))
    mask["channel"] = "red"
    hdr = texture("hdr", lambda x, y: (2.5, 0.2, 0.1, 1))
    material = dict(id="surface", baseColor=[0.7, 0.65, 0.5, 1], roughness=0.4, metallic=0.05,
                    diffuseTransmission=0.12, subsurface=0.02, subsurfaceRadiusMM=[0.2, 0.1, 0.05],
                    sheen=0.2, coat=0.15, anisotropy=0.3, alphaMode="blend", useVertexColor=True,
                    bumpStrength=0.15, displacementScaleMM=0.08,
                    textures=dict(baseColor=base, artwork=artwork, normal=normal, normalDetail=normal,
                                  bump=height, displacement=height),
                    physicalLayers=[dict(mask=mask, appearance=dict(metallic=0.8, roughness=0.2, coat=0.5))])
    positions, uv, triangles = [], [], []
    segments = 16
    for y in range(segments + 1):
        for x in range(segments + 1):
            positions.extend([(x / segments - 0.5) * 100, (y / segments - 0.5) * 100, 0])
            uv.extend([x / segments, 1 - y / segments])
    for y in range(segments):
        for x in range(segments):
            a = y * (segments + 1) + x
            triangles.extend([a, a + 1, a + segments + 2, a, a + segments + 2, a + segments + 1])
    count = len(positions) // 3
    mesh = dict(id="grid", positions=buffer(positions, "d", 3), triangles=buffer(triangles, "I"),
                normals=buffer([0, 0, 1] * count, "f", 3), uvs=buffer(uv, "f", 2),
                uvs1=buffer(uv, "f", 2), colors=buffer([0.8, 1, 0.8, 1] * count, "f", 4),
                transform=identity())
    # The second UV set and mixed wrapping must survive the native bridge.
    material["textures"]["normalDetail"] = dict(normal, uvIndex=1, wrapS="mirror", wrapT="clamp")
    curve_points = [v for i in range(25) for v in (-45 + i * 90 / 24, -35 + 2 * math.sin(i), 1.5)]
    curve = dict(id="curve", points=buffer(curve_points, "d", 3), radii=buffer([0.6] * 25, "f"),
                 firstKey=buffer([0], "I"), materialIndex=1, transform=identity())
    camera = identity(0, 0, 220)
    camera[10] = -1
    return dict(version=1, jobID="native-contract", sourceRevision="generic-material-grid-v1",
                device=device, width=256, height=256, samples=32, adaptiveThreshold=0,
                denoise=True, exposureEV=0, maxBounces=8, outputDirectory="output",
                meshes=[mesh], curves=[curve], materials=[material, dict(id="emissive-curve",
                    baseColor=[1, 1, 1, 1], unlit=True, textures=dict(baseColor=hdr))],
                camera=dict(type="perspective", transform=camera, fovRadians=0.65, near=0.1, far=10000),
                lights=[dict(type="area", shape="disk", transform=identity(-20, 40, 120),
                             color=[1, 1, 1], power=0.12, size=[100, 100])],
                background=dict(color=[0.06, 0.06, 0.06], strength=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device", choices=["cpu", "metal"], default="cpu")
    parser.add_argument("--helper-sandbox-profile", type=Path)
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=False)
    manifest = author(folder, args.device)
    path = folder / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    env = dict(PATH="/usr/bin:/bin", LAB_CYCLES_CACHE_DIR=str(folder / "cache"))
    command = [str(args.helper.resolve())]
    if args.helper_sandbox_profile:
        command = ["/usr/bin/sandbox-exec", "-f", str(args.helper_sandbox_profile.resolve()), *command]
    result = subprocess.run([*command, "--render", str(path)], env=env,
                            text=True, capture_output=True, timeout=600)
    (folder / "events.jsonl").write_text(result.stdout)
    (folder / "stderr.log").write_text(result.stderr)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert result.returncode == 0, events[-1] if events else result.stderr
    assert any(e["type"] == "frame" for e in events), "No progressive pixels"
    complete = [e for e in events if e["type"] == "completed"][-1]
    assert complete["device"] == args.device
    for key in ("finalPNG", "finalEXR"):
        assert Path(complete[key]).is_file() and Path(complete[key]).stat().st_size > 128
    # Verify a malicious array path fails rather than reading outside the job.
    bad = dict(manifest, meshes=[dict(manifest["meshes"][0], positions=dict(path="../outside.bin", count=3))])
    bad_path = folder / "invalid.json"
    bad_path.write_text(json.dumps(bad))
    invalid = subprocess.run([*command, "--render", str(bad_path)], env=env,
                             text=True, capture_output=True, timeout=30)
    assert invalid.returncode != 0
    assert any(e.get("type") == "error" and "outside" in e.get("message", "").lower()
               for e in map(json.loads, invalid.stdout.splitlines()))
    # Cancellation is a terminal event; no completed image may be published.
    cancel = dict(manifest, width=512, height=512, samples=65536, denoise=False,
                  outputDirectory="cancelled-output")
    cancel_path = folder / "cancel.json"
    cancel_path.write_text(json.dumps(cancel))
    with (folder / "cancel-events.jsonl").open("w") as output, (folder / "cancel-stderr.log").open("w") as errors:
        process = subprocess.Popen([*command, "--render", str(cancel_path)], env=env,
                                   stdout=output, stderr=errors)
        time.sleep(0.5)
        process.terminate()
        process.wait(timeout=30)
    cancelled = list(map(json.loads, (folder / "cancel-events.jsonl").read_text().splitlines()))
    assert any(e["type"] == "cancelled" for e in cancelled), cancelled[-1:]
    assert not any(e["type"] == "completed" for e in cancelled)
    report = dict(device=args.device, engineVersion=complete["engineVersion"], seconds=complete["seconds"],
                  progressive=True, finalPNG=complete["finalPNG"], finalEXR=complete["finalEXR"],
                  malformedInputRejected=True, cancellation=True)
    (folder / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
