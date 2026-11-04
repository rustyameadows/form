#!/usr/bin/env python3
"""Check actual Cycles input transfer and PNG/EXR alpha against numeric references.

Uses exact constant texels and unlit/background shaders, not a second renderer
or a photographic-tone assumption. Does not launch LAB or modify projects.
"""
import argparse
import array
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import threading
import time
import zlib

from verify_cycles_native import identity


def linear(x):
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


def display(x):
    return math.floor(min(1, max(0, 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055)) * 255 + 0.5)


def write_png(path, rgba):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress((b'\0' + bytes(rgba) * 2) * 2)) + chunk(b'IEND', b''))


def png_center(path):
    raw = path.read_bytes()
    assert raw[:8] == b'\x89PNG\r\n\x1a\n'
    offset, compressed = 8, bytearray()
    while offset < len(raw):
        size = struct.unpack_from('>I', raw, offset)[0]
        kind, data = raw[offset + 4:offset + 8], raw[offset + 8:offset + 8 + size]
        if kind == b'IHDR':
            width, height, bits, color, _, _, interlace = struct.unpack('>IIBBBBB', data)
            assert bits == 8 and color == 6 and interlace == 0
        elif kind == b'IDAT':
            compressed.extend(data)
        offset += size + 12
    data = zlib.decompress(compressed)
    stride, prior = width * 4, bytearray(width * 4)
    for y in range(height):
        kind = data[y * (stride + 1)]
        row = bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a, b, c = row[i - 4] if i >= 4 else 0, prior[i], prior[i - 4] if i >= 4 else 0
            if kind == 4:
                p = a + b - c
                distances = [abs(p - a), abs(p - b), abs(p - c)]
                prediction = [a, b, c][distances.index(min(distances))]
            else:
                assert kind in (0, 1, 2, 3)
                prediction = (0, a, b, (a + b) // 2)[kind]
            row[i] = (row[i] + prediction) & 255
        if y == height // 2:
            return list(row[width // 2 * 4:width // 2 * 4 + 4])
        prior = row


def manifest(folder, device, kind, encoding, rgba, exposure):
    def buffer(name, values, typecode, components=1):
        data = array.array(typecode, values)
        if sys.byteorder != 'little':
            data.byteswap()
        (folder / name).write_bytes(data.tobytes())
        return dict(path=name, count=len(values) // components)
    if kind != 'float':
        write_png(folder / 'texels.png', rgba)
    texture = dict(path='texels.png', colorSpace=encoding, uvIndex=0, wrapS='clamp', wrapT='clamp')
    if kind == 'float':
        buffer('texels.rgba32f', [x / 255 for x in rgba] * 4, 'f', 4)
        texture.update(path='texels.rgba32f', format='rgba32f', width=2, height=2)
    camera = identity(0, 0, 100)
    camera[10] = -1
    scene = dict(version=1, jobID=folder.name, sourceRevision='numeric-color-v1', width=16, height=16,
                 samples=256, device=device, seed=7, adaptiveThreshold=0, denoise=False, exposureEV=exposure,
                 maxBounces=8, outputDirectory='output', meshes=[], materials=[], lights=[],
                 camera=dict(type='orthographic', transform=camera, orthoScale=20, near=0.1, far=1000),
                 background=dict(color=[0, 0, 0], strength=0), transparent=rgba[3] < 255)
    if kind == 'environment':
        scene['background'] = dict(color=[1, 1, 1], strength=1, texture=texture)
    else:
        scene['meshes'] = [dict(id='plane', transform=identity(),
            positions=buffer('positions.bin', [-20, -20, 0, 20, -20, 0, 20, 20, 0, -20, 20, 0], 'd', 3),
            normals=buffer('normals.bin', [0, 0, 1] * 4, 'f', 3),
            uvs=buffer('uv.bin', [0, 0, 1, 0, 1, 1, 0, 1], 'f', 2),
            triangles=buffer('indices.bin', [0, 1, 2, 0, 2, 3], 'I'))]
        material = dict(id='unlit', baseColor=[1, 1, 1, 1], unlit=True, alphaMode='blend', textures=dict(baseColor=texture))
        if kind == 'numeric':
            material.update(baseColor=[x / 255 for x in rgba], textures={})
        scene['materials'] = [material]
    return scene


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', choices=['cpu', 'metal'], default='cpu')
    parser.add_argument('--oiiotool', type=Path, default=Path('.local/cycles/source/lib/macos_arm64/openimageio/bin/oiiotool'))
    args = parser.parse_args()
    root, helper = args.output.resolve(), args.helper.resolve()
    root.mkdir(parents=True, exist_ok=False)
    env = dict(PATH='/usr/bin:/bin', LAB_CYCLES_CACHE_DIR=str(root / 'cache'))
    read_env = dict(os.environ, DYLD_LIBRARY_PATH=str(helper.parent / 'lib'))
    cases = [('image-srgb', 'image', 'srgb', [128, 128, 128, 255], 0),
             ('image-linear', 'image', 'linear', [128, 128, 128, 255], 0),
             ('image-data', 'image', 'data', [128, 128, 128, 255], 0),
             ('environment-srgb', 'environment', 'srgb', [128, 128, 128, 255], 0),
             ('environment-linear', 'environment', 'linear', [128, 128, 128, 255], 0),
             ('srgb-exposure', 'image', 'srgb', [128, 128, 128, 255], 1),
             ('numeric-alpha', 'numeric', 'linear', [64, 23, 3, 128], 0),
             ('srgb-alpha', 'image', 'srgb', [128, 64, 192, 128], 0),
             ('linear-alpha', 'image', 'linear', [128, 64, 192, 128], 0),
             ('data-alpha', 'image', 'data', [128, 64, 192, 128], 0),
             ('float-linear-alpha', 'float', 'linear', [128, 64, 192, 128], 0),
             ('float-srgb-alpha', 'float', 'srgb', [128, 64, 192, 128], 0),
             ('float-data-alpha', 'float', 'data', [128, 64, 192, 128], 0),
             ('float-hdr-alpha', 'float', 'linear', [1020, 128, 32, 128], 0)]
    report = dict(device=args.device, helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(), cases=[], failures=[])
    for name, kind, encoding, rgba, exposure in cases:
        folder = root / name
        folder.mkdir()
        path = folder / 'manifest.json'
        scene = manifest(folder, args.device, kind, encoding, rgba, exposure)
        requires_live_frame = name in ('image-srgb', 'numeric-alpha')
        if requires_live_frame:
            scene.update(width=128, height=128, samples=4096)
        path.write_text(json.dumps(scene, indent=2) + '\n')
        events, retained_frames = [], []
        started = time.monotonic()
        with (folder / 'stderr.log').open('w') as errors, (folder / 'events.jsonl').open('w') as output:
            process = subprocess.Popen([str(helper), '--render', str(path)], env=env, stdout=subprocess.PIPE, stderr=errors, text=True)
            timer = threading.Timer(600, process.kill)
            timer.start()
            try:
                for line in process.stdout:
                    output.write(line); output.flush()
                    event = json.loads(line); events.append(event)
                    if event['type'] == 'frame':
                        copied = folder / f'progressive-{len(retained_frames):03}.png'
                        copied.write_bytes(Path(event['framePath']).read_bytes())
                        retained_frames.append(dict(path=str(copied), sample=event.get('sample'),
                                                    processStillRunning=process.poll() is None, seconds=time.monotonic() - started))
                process.wait(timeout=30)
            finally:
                timer.cancel()
                if process.poll() is None:
                    process.kill(); process.wait(timeout=30)
        stderr = (folder / 'stderr.log').read_text()
        completed = [e for e in events if e['type'] == 'completed']
        if process.returncode or not completed:
            report['failures'].append(dict(case=name, error=events[-1:] or stderr))
            continue
        complete = completed[-1]
        stats = subprocess.check_output([str(args.oiiotool.resolve()), complete['finalEXR'], '--crop', '1x1+8+8', '--printstats'], env=read_env, text=True)
        (folder / 'exr-center.txt').write_text(stats)
        exr = list(map(float, re.search(r'Stats Avg: ([^\n]+) \(float\)', stats).group(1).split()))
        png = png_center(Path(complete['finalPNG']))
        straight = [linear(x / 255) if encoding == 'srgb' else x / 255 for x in rgba[:3]]
        expected_png = [display(x * 2 ** exposure) for x in straight]
        errors = []
        if complete['device'] != args.device:
            errors.append('wrong actual device')
        if abs(exr[3] - rgba[3] / 255) > 0.1:
            errors.append('alpha does not match authored opacity')
        # Pinned Cycles converts integer sRGB to HALF4. For integer linear
        # RGBA it associates in the original8-bit storage, losing at most one
        # integer quantum. Float transport/numeric/data retain tight tolerance.
        expected_exr = [value * exr[3] for value in straight]
        tolerance = 0.0003 if encoding == 'srgb' and kind != 'float' else 0.00003
        if encoding == 'linear' and kind == 'image' and rgba[3] < 255:
            expected_exr = [math.floor(value * rgba[3] / 255) / 255 * exr[3] / (rgba[3] / 255) for value in rgba[:3]]
        if any(abs(exr[c] - expected_exr[c]) > tolerance for c in range(3)):
            errors.append('EXR does not match independently calculated scene-linear premultiplied RGB')
        if any(abs(png[c] - expected_png[c]) > 1 for c in range(3)) or abs(png[3] / 255 - exr[3]) > 1 / 255:
            errors.append('PNG does not match independently calculated straight display RGBA')
        if not retained_frames or (requires_live_frame and not any(f['processStillRunning'] for f in retained_frames)):
            errors.append('no progressive PNG retained while the renderer was active')
        for event in retained_frames:
            sample = png_center(Path(event['path']))
            if sample[3] > 12 and any(abs(sample[c] - expected_png[c]) > 2 for c in range(3)):
                errors.append('progressive PNG differs from the same display/alpha transform')
                break
        if 'not found' in stderr or "can't be converted" in stderr:
            errors.append('unresolved runtime input color space')
        report['cases'].append(dict(name=name, exrCenter=exr, pngCenter=png, expectedStraightLinear=straight,
                                    expectedPNG=expected_png, expectedEXRAfterBoundedStorage=expected_exr, exrAbsoluteTolerance=tolerance,
                                    progressiveFrames=retained_frames, errors=errors))
        report['failures'].extend(dict(case=name, error=e) for e in errors)
    report['status'] = 'failed' if report['failures'] else 'passed'
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return bool(report['failures'])


if __name__ == '__main__':
    sys.exit(main())
