#!/usr/bin/env python3
"""Compare transformed mesh tangent normals with independently authored vectors."""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import subprocess

from verify_cycles_color import manifest
from verify_cycles_curves import pixels
from verify_cycles_native import identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', choices=['cpu', 'metal'], default='cpu')
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    env = dict(PATH='/usr/bin:/bin', LAB_CYCLES_CACHE_DIR=str(root / 'cache'))
    report = dict(device=args.device, helperSHA256=hashlib.sha256(args.helper.read_bytes()).hexdigest(), comparisons={}, failures=[])

    def render(name, vector, uv=0, **mapping):
        folder = root / name
        folder.mkdir()
        scene = manifest(folder, args.device, 'image', 'data', [255, 255, 255, 255], 0)
        scene.update(width=128, height=64, samples=64, transparent=True)
        scene['camera']['orthoScale'] = 40
        scene['background'] = dict(color=[0.02, 0.02, 0.02], strength=1)
        scene['lights'] = [dict(type='area', transform=identity(-35, 25, 70), power=0.1, color=[1, 1, 1], size=[50, 50])]
        (folder / 'uv1.bin').write_bytes(array.array('f', [1, 0, 0, 0, 0, 1, 1, 1]).tobytes())
        scene['meshes'][0]['uvs1'] = dict(path='uv1.bin', count=4)
        (folder / 'normal.rgba32f').write_bytes(array.array('f', [v * 0.5 + 0.5 for v in vector] + [1]).tobytes())
        texture = dict(path='normal.rgba32f', format='rgba32f', width=1, height=1, colorSpace='data', uvIndex=uv,
                       wrapS='repeat', wrapT='repeat', scale=[1, 1], offset=[0, 0], **{})
        texture.update(mapping)
        scene['materials'] = [dict(id='surface', baseColor=[0.5, 0.5, 0.5, 1], roughness=0.5, textures=dict(normal=texture))]
        path = folder / 'manifest.json'
        path.write_text(json.dumps(scene, indent=2) + '\n')
        run = subprocess.run([str(args.helper.resolve()), '--render', str(path)], env=env, text=True, capture_output=True, timeout=600)
        (folder / 'events.jsonl').write_text(run.stdout)
        (folder / 'stderr.log').write_text(run.stderr)
        events = [json.loads(line) for line in run.stdout.splitlines()]
        assert run.returncode == 0 and events[-1]['type'] == 'completed', events[-1:]
        assert events[-1]['device'] == args.device
        return pixels(Path(events[-1]['finalPNG']))[2]

    def compare(name, actual, expected, indices):
        error = max(abs(actual[i] - expected[i]) for i in indices)
        report['comparisons'][name] = dict(maximumByteError=error, checkedChannels=len(indices))
        if error > 2:
            report['failures'].append(dict(case=name, maximumByteError=error))

    inside = [(y * 128 + x) * 4 + c for y in range(8, 56) for x in range(40, 88) for c in range(3)]
    references = {}
    for uv in (0, 1):
        positive = render(f'uv{uv}-positive-reference', [0.7, 0, 1], uv)
        negative = render(f'uv{uv}-negative-reference', [-0.7, 0, 1], uv)
        vertical = render(f'uv{uv}-vertical-reference', [0, 0.7, 1], uv)
        references[uv] = (positive, negative, vertical)
        mean_difference = sum(abs(positive[i] - negative[i]) for i in inside) / len(inside)
        report[f'uv{uv}ReferenceMeanDifference'] = mean_difference
        assert mean_difference > 5, 'Lighting does not distinguish the independent tangent references'
        compare(f'uv{uv}-rotation90', render(f'uv{uv}-rotation90', [0.7, 0, 1], uv, rotationDegrees=90), vertical, inside)
        compare(f'uv{uv}-negative-scale', render(f'uv{uv}-negative-scale', [0.7, 0, 1], uv, scale=[-1, 1]), negative, inside)
        # Nonuniform texture scale changes the rotated tangent direction.
        direction = [0.7 / math.sqrt(5), 1.4 / math.sqrt(5), 1]
        reference = render(f'uv{uv}-nonuniform-reference', direction, uv)
        compare(f'uv{uv}-nonuniform-rotation', render(f'uv{uv}-nonuniform-rotation', [0.7, 0, 1], uv, scale=[2, 1], rotationDegrees=45), reference, inside)
        mirrored = render(f'uv{uv}-mirror', [0.7, 0, 1], uv, scale=[4, 1], offset=[0.13, 0], wrapS='mirror')
        error, samples = 0, 0
        for x in range(40, 88):
            u = (((x + 0.5) - 64) * 80 / 128 + 20) / 40
            if uv == 1:
                u = 1 - u
            mapped = u * 4 + 0.13
            if min(mapped % 1, 1 - mapped % 1) < 0.12:
                continue
            expected = positive if math.floor(mapped) % 2 == 0 else negative
            for y in (16, 32, 48):
                for c in range(3):
                    i = (y * 128 + x) * 4 + c
                    error = max(error, abs(mirrored[i] - expected[i])); samples += 1
        report['comparisons'][f'uv{uv}-mirrored-repeat'] = dict(maximumByteError=error, checkedChannels=samples)
        if error > 2:
            report['failures'].append(dict(case=f'uv{uv}-mirrored-repeat', maximumByteError=error))
    compare('reversed-UV1-basis', references[1][0], references[0][1], inside)
    compare('UV1-vertical-basis', references[1][2], references[0][2], inside)
    report['status'] = 'failed' if report['failures'] else 'passed'
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return bool(report['failures'])


if __name__ == '__main__':
    raise SystemExit(main())
