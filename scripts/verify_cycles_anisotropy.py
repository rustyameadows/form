#!/usr/bin/env python3
"""Verify real Cycles anisotropy follows material UVs, not triangle ordering.

Independent UV charts and scalar rotations provide the reference directions.
Constant strength texels isolate direction from texture sampling and color.
No LAB/project mutation or third-party Python dependencies are required.
"""
import argparse
import array
import copy
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
    root, helper = args.output.resolve(), args.helper.resolve()
    root.mkdir(parents=True, exist_ok=False)
    env = dict(PATH='/usr/bin:/bin', LAB_CYCLES_CACHE_DIR=str(root / 'cache'))
    report = dict(device=args.device, helperSHA256=hashlib.sha256(helper.read_bytes()).hexdigest(),
                  comparisons={}, renders={}, failures=[])
    inside = [(y * 128 + x) * 4 + c for y in range(8, 56) for x in range(40, 88) for c in range(3)]
    uv0 = [0, 0, 1, 0, 1, 1, 0, 1]
    uv90 = [0, 1, 0, 0, 1, 0, 1, 1]

    def render(name, *, indices=None, uv=uv0, mapping=None, rotation=0, isotropic=False,
               curve=False, pole=False):
        folder = root / name
        folder.mkdir()
        scene = manifest(folder, args.device, 'image', 'data', [255, 255, 255, 255], 0)
        scene.update(width=128, height=64, samples=128, transparent=True)
        scene['camera']['orthoScale'] = 40
        scene['background'] = dict(color=[0.02, 0.02, 0.02], strength=1)
        scene['lights'] = [dict(type='area', transform=identity(-35, 25, 70), power=0.005,
                               color=[1, 1, 1], size=[15, 15])]
        material = dict(id='surface', baseColor=[0.5, 0.5, 0.5, 1], roughness=0.3, metallic=1,
                        anisotropy=0 if isotropic else 0.85, anisotropyRotation=rotation)
        if mapping is not None:
            (folder / 'strength.rgba32f').write_bytes(array.array('f', [1, 1, 1, 1]).tobytes())
            descriptor = dict(path='strength.rgba32f', format='rgba32f', width=1, height=1,
                              colorSpace='data', uvIndex=0, scale=[1, 1], wrapS='repeat', wrapT='repeat')
            descriptor.update(mapping)
            material['textures'] = dict(anisotropy=descriptor)
        scene['materials'] = [material]

        def buffer(name, values, kind, dimensions=1):
            (folder / name).write_bytes(array.array(kind, values).tobytes())
            return dict(path=name, count=len(values) // dimensions)

        mesh = scene['meshes'][0]
        if indices is not None:
            mesh['triangles'] = buffer('indices.bin', indices, 'I')
        if uv is None:
            mesh.pop('uvs')
        else:
            mesh['uvs'] = buffer('uv.bin', uv, 'f', 2)
        mesh['uvs1'] = buffer('uv1.bin', uv90, 'f', 2)
        if pole:
            # Rigidly rotate the actual vertex/normal chart, camera and lights,
            # leaving object space unchanged: projected object X is now a pole.
            mesh['positions'] = buffer('positions.bin', [v for x, y in [(-20, -20), (20, -20), (20, 20), (-20, 20)]
                                                        for v in (0, x, y)], 'd', 3)
            mesh['normals'] = buffer('normals.bin', [1, 0, 0] * 4, 'f', 3)
            for record in [scene['camera'], *scene['lights']]:
                matrix = record['transform']
                for column in range(4):
                    i = column * 4
                    matrix[i:i + 3] = [matrix[i + 2], matrix[i], matrix[i + 1]]
        if curve:
            scene['meshes'] = []
            scene['curves'] = [dict(id='strand', transform=identity(), materialIndex=0,
                points=buffer('points.bin', [v for i in range(9) for v in (-20 + i * 5, 0, 0)], 'd', 3),
                radii=buffer('radii.bin', [3] * 9, 'f'), firstKey=buffer('first.bin', [0], 'I'),
                uvs=buffer('curve-uv0.bin', [v for i in range(9) for v in (i * 5, 0)], 'f', 2),
                uvs1=buffer('curve-uv1.bin', [v for i in range(9) for v in (-i * 5, 0)], 'f', 2))]
        path = folder / 'manifest.json'
        path.write_text(json.dumps(scene, indent=2) + '\n')
        run = subprocess.run([str(helper), '--render', str(path)], env=env,
                             text=True, capture_output=True, timeout=600)
        (folder / 'events.jsonl').write_text(run.stdout)
        (folder / 'stderr.log').write_text(run.stderr)
        events = [json.loads(line) for line in run.stdout.splitlines()]
        assert run.returncode == 0 and events[-1]['type'] == 'completed', events[-1:]
        assert events[-1]['device'] == args.device
        image_path = Path(events[-1]['finalPNG'])
        image = pixels(image_path)[2]
        values = [image[i + c] for i in range(0, len(image), 4) if image[i + 3] > 250 for c in range(3)]
        clipped = sum(value == 255 for value in values)
        report['renders'][name] = dict(pngSHA256=hashlib.sha256(image_path.read_bytes()).hexdigest(),
                                      maximumByte=max(values), clippedChannels=clipped)
        if clipped:
            report['failures'].append(dict(case=name, reason='Fixture highlights must remain unclipped', clippedChannels=clipped))
        return image

    def compare(name, actual, expected, indices=inside):
        errors = [abs(actual[i] - expected[i]) for i in indices]
        result = dict(maximumByteError=max(errors), meanByteError=sum(errors) / len(errors),
                      checkedChannels=len(indices))
        report['comparisons'][name] = result
        if result['maximumByteError'] > 3:
            report['failures'].append(dict(case=name, **result))

    base = render('uv0-reference')
    quarter = render('quarter-turn-reference', rotation=0.25)
    distinction = sum(abs(base[i] - quarter[i]) for i in inside) / len(inside)
    report['quarterTurnMeanDifference'] = distinction
    if distinction < 5:
        report['failures'].append(dict(case='lighting-must-resolve-direction', meanDifference=distinction))
    compare('cyclic-triangle-order', render('cyclic-triangle-order', indices=[1, 2, 0, 2, 3, 0]), base)
    compare('other-diagonal', render('other-diagonal', indices=[0, 1, 3, 1, 2, 3]), base)
    compare('rotated-UV0', render('rotated-UV0', uv=uv90), quarter)
    compare('UV1-selection', render('UV1-selection', mapping=dict(uvIndex=1)), quarter)
    compare('texture-rotation90', render('texture-rotation90', mapping=dict(rotationDegrees=90)), quarter)
    angle = math.atan2(2, 1) / (2 * math.pi)
    negative = render('negative-angle-reference', rotation=-angle)
    positive = render('positive-angle-reference', rotation=angle)
    compare('nonuniform-texture-rotation', render('nonuniform-texture-rotation',
            mapping=dict(scale=[2, 1], rotationDegrees=45)), negative)
    compare('negative-texture-scale', render('negative-texture-scale',
            mapping=dict(scale=[-2, 1], rotationDegrees=45)), positive)
    compare('mirrored-UV-chart', render('mirrored-UV-chart', uv=[1-u if i % 2 == 0 else u for i, u in enumerate(uv0)],
            mapping=dict(scale=[2, 1], rotationDegrees=45)), positive)
    compare('mirrored-repeats', render('mirrored-repeats',
            mapping=dict(scale=[2, 1], rotationDegrees=45, offset=[0.13, 0.27], wrapS='mirror', wrapT='mirror')), negative)
    compare('rectangular-UV-metric', render('rectangular-UV-metric',
            uv=[u * 2 if i % 2 == 0 else u for i, u in enumerate(uv0)], mapping=dict(rotationDegrees=45)), negative)
    skew = render('skew-angle-reference', rotation=-math.atan2(1, 1.5) / (2 * math.pi))
    compare('skewed-UV-metric', render('skewed-UV-metric', uv=[0, 0, 1, 0, 1.5, 1, 0.5, 1],
            mapping=dict(rotationDegrees=45)), skew)
    compare('UV1-and-texture-rotation', render('UV1-and-texture-rotation',
            mapping=dict(uvIndex=1, rotationDegrees=90)), base)
    compare('no-UV-fallback', render('no-UV-fallback', uv=None), base)
    compare('no-UV-triangle-order', render('no-UV-triangle-order', uv=None, indices=[1, 2, 0, 2, 3, 0]), base)
    compare('no-UV-object-X-pole', render('no-UV-object-X-pole', uv=None, pole=True), render('object-X-pole-reference', pole=True))
    isotropic = render('isotropic-reference', isotropic=True)
    compare('legacy-isotropic-no-UV', render('legacy-isotropic-no-UV', uv=None, isotropic=True), isotropic)
    strand = render('curve-reference', curve=True)
    curve_inside = [(y * 128 + x) * 4 + c for y in range(30, 34) for x in range(40, 88) for c in range(3)]
    compare('curve-keeps-longitudinal-axis', render('curve-mapped-strength', curve=True,
            mapping=dict(uvIndex=1, scale=[-2, 1], rotationDegrees=90)), strand, curve_inside)
    report['status'] = 'failed' if report['failures'] else 'passed'
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return bool(report['failures'])


if __name__ == '__main__':
    raise SystemExit(main())
