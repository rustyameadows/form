#!/usr/bin/env python3
"""Render generic coarse open/closed meshes to verify bounded texture displacement."""
import argparse
import array
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def alpha_pixels(path):
    raw = path.read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    offset, compressed = 8, bytearray()
    while offset < len(raw):
        size = struct.unpack_from(">I", raw, offset)[0]
        kind, data = raw[offset + 4:offset + 8], raw[offset + 8:offset + 8 + size]
        if kind == b"IHDR":
            width, height, bits, color, _, _, interlace = struct.unpack(">IIBBBBB", data)
            assert bits == 8 and color == 6 and interlace == 0
        elif kind == b"IDAT":
            compressed.extend(data)
        offset += size + 12
    data = zlib.decompress(compressed)
    stride, prior, pixels = width * 4, bytearray(width * 4), []
    for y in range(height):
        filter_type = data[y * (stride + 1)]
        row = bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a, b, c = row[i - 4] if i >= 4 else 0, prior[i], prior[i - 4] if i >= 4 else 0
            if filter_type == 1:
                predictor = a
            elif filter_type == 2:
                predictor = b
            elif filter_type == 3:
                predictor = (a + b) // 2
            elif filter_type == 4:
                p = a + b - c
                distances = [abs(p - a), abs(p - b), abs(p - c)]
                predictor = [a, b, c][distances.index(min(distances))]
            else:
                assert filter_type == 0
                predictor = 0
            row[i] = (row[i] + predictor) & 255
        pixels.extend(value > 127 for value in row[3::4])
        prior = row
    return width, height, pixels


def extent(image):
    w, h, mask = image
    positions = [(i % w, i // w) for i, p in enumerate(mask) if p]
    assert positions
    return [min(p[0] for p in positions), min(p[1] for p in positions),
            max(p[0] for p in positions), max(p[1] for p in positions)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device", choices=["cpu", "metal"], default="cpu")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    env = dict(PATH="/usr/bin:/bin", LAB_CYCLES_CACHE_DIR=str(root / "cache"))
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    report = {}
    for shape in ("plane", "closed-polyhedron"):
        folder = root / shape
        folder.mkdir()

        def buffer(name, data, kind, components):
            a = array.array(kind, data)
            if sys.byteorder != "little":
                a.byteswap()
            (folder / name).write_bytes(a.tobytes())
            return dict(path=name, count=len(a) // components)

        if shape == "plane":
            positions = [-50, -50, 0, 50, -50, 0, 50, 50, 0, -50, 50, 0]
            indices = [0, 1, 2, 0, 2, 3]
            normals, uvs = [0, 0, 1] * 4, [0, 1, 1, 1, 1, 0, 0, 0]
            # Camera +Z looks into the scene; +Y is screen up.
            f = (0, 200 / math.sqrt(43600), -60 / math.sqrt(43600))
            camera = [1, 0, 0, 0, 0, -f[2], f[1], 0, *f, 0, 0, -200, 60, 1]
            scale = 20
        else:
            positions = [0, 35, 0, 0, -35, 0, 35, 0, 0, 0, 0, 35, -35, 0, 0, 0, 0, -35]
            indices = [0, 3, 2, 0, 4, 3, 0, 5, 4, 0, 2, 5, 1, 2, 3, 1, 3, 4, 1, 4, 5, 1, 5, 2]
            normals = [x / 35 for x in positions]
            uvs = [0.5, 0.5] * 6
            camera = identity.copy()
            camera[10], camera[14] = -1, 200
            scale = 8
            edge_counts = {}
            for i in range(0, len(indices), 3):
                for a, b in ((indices[i], indices[i + 1]), (indices[i + 1], indices[i + 2]), (indices[i + 2], indices[i])):
                    edge = tuple(sorted((a, b)))
                    edge_counts[edge] = edge_counts.get(edge, 0) + 1
            assert set(edge_counts.values()) == {2}, "The unrelated closed source must be a two-manifold"
        mesh = dict(id=shape, positions=buffer("positions.bin", positions, "d", 3),
                    triangles=buffer("triangles.bin", indices, "I", 1),
                    normals=buffer("normals.bin", normals, "f", 3), uvs=buffer("uvs.bin", uvs, "f", 2), transform=identity)
        heights = []
        for y in range(64):
            for x in range(64):
                value = 0.5 + 0.5 * math.sin(x / 63 * math.pi * 8) if shape == "plane" else 1
                heights.extend([value, value, value, 1])
        buffer("height.rgba32f", heights, "f", 4)
        texture = dict(path="height.rgba32f", format="rgba32f", width=64, height=64,
                       colorSpace="linear", channel="red", wrapS="clamp", wrapT="clamp")
        buffer("mask.rgba32f", [1, 1, 1, 1], "f", 4)
        mask = dict(path="mask.rgba32f", format="rgba32f", width=1, height=1,
                    colorSpace="linear", channel="red")
        base = dict(version=1, jobID=shape, sourceRevision="generic-silhouette-v1", device=args.device,
                    width=256, height=256, samples=16, denoise=False, transparent=True,
                    displacementDicingRate=2, displacementMaxTriangles=2000000, displacementMaxSubdivisions=10,
                    meshes=[mesh], camera=dict(type="orthographic", transform=camera, orthoScale=130, near=0.1, far=10000),
                    background=dict(color=[0, 0, 0], strength=0), lights=[])
        images, triangle_counts = [], []
        for variant, amplitude in (("baseline", 0), ("displaced", scale), ("layer-clears", scale)):
            manifest = dict(base, outputDirectory=variant, materials=[dict(baseColor=[0.8, 0.5, 0.2, 1], unlit=True,
                             displacementScaleMM=amplitude, displacementMidlevel=0.5, textures=dict(displacement=texture))])
            if variant == "layer-clears":
                manifest["materials"][0]["physicalLayers"] = [dict(mask=mask, appearance=dict(displacementScaleMM=0))]
            path = folder / (variant + ".json")
            path.write_text(json.dumps(manifest, indent=2))
            result = subprocess.run([str(args.helper.resolve()), "--render", str(path)], env=env,
                                    text=True, capture_output=True, timeout=600)
            (folder / (variant + "-events.jsonl")).write_text(result.stdout)
            (folder / (variant + "-stderr.log")).write_text(result.stderr)
            events = list(map(json.loads, result.stdout.splitlines()))
            assert result.returncode == 0, events[-1:]
            images.append(alpha_pixels(folder / variant / "final.png"))
            triangle_counts.append(max((e.get("renderTriangles", 0) for e in events), default=0))
        changed = sum(a != b for a, b in zip(images[0][2], images[1][2]))
        assert changed > 300, f"Displacement failed to change {shape} silhouette: {changed} pixels"
        assert triangle_counts[0] == 0 and triangle_counts[1] > len(indices) // 3
        cleared = sum(a != b for a, b in zip(images[0][2], images[2][2]))
        assert cleared < 20, f"Explicit zero displacement layer did not restore {shape}: {cleared} pixels"
        report[shape] = dict(changedSilhouettePixels=changed, bounds=[extent(i) for i in images],
                             sourceTriangles=len(indices) // 3, renderTriangles=triangle_counts[1],
                             layerClearsDisplacement=True, clearedDifferencePixels=cleared)
        limited = dict(manifest, displacementMaxTriangles=1)
        path = folder / "over-budget.json"
        path.write_text(json.dumps(limited))
        result = subprocess.run([str(args.helper.resolve()), "--render", str(path)], env=env,
                                text=True, capture_output=True, timeout=30)
        assert result.returncode != 0 and "budget" in result.stdout.lower()
    (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
