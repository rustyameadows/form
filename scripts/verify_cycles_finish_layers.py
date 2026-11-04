#!/usr/bin/env python3
"""Render masked finish factors against independently authored Cycles references."""
import argparse
import array
import copy
import json
import os
from pathlib import Path
import subprocess

from verify_cycles_curves import pixels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=['cpu', 'metal'], default='cpu')
    args = parser.parse_args()
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    def buffer(name, values, kind, components=1):
        (root / name).write_bytes(array.array(kind, values).tobytes())
        return dict(path=name, count=len(values) // components)

    def texture(name, values, width=1, height=1):
        buffer(name, values, 'f', 4)
        return dict(path=name, format='rgba32f', width=width, height=height,
                    colorSpace='data', channel='red', wrapS='clamp', wrapT='clamp')

    rough = texture('rough.rgba32f', [.96, .96, .96, 1])
    dark = texture('dark.rgba32f', [0, 0, 0, 1])
    own_rough = texture('own-rough.rgba32f', [.25, .25, .25, 1])
    own_metal = texture('own-metal.rgba32f', [.3, .3, .3, 1])
    mask = texture('mask.rgba32f', [c for y in range(8) for x in range(8)
                                  for c in (float(x < 4), float(x < 4), float(x < 4), 1)], 8, 8)
    mesh = dict(id='surface', transform=identity,
                positions=buffer('positions.bin', [-45, -45, 0, 45, -45, 0, 45, 45, 0, -45, 45, 0], 'd', 3),
                normals=buffer('normals.bin', [0, 0, 1] * 4, 'f', 3),
                uvs=buffer('uv.bin', [0, 0, 1, 0, 1, 1, 0, 1], 'f', 2),
                triangles=buffer('triangles.bin', [0, 1, 2, 0, 2, 3], 'I'))
    camera = identity.copy(); camera[10], camera[14] = -1, 200
    light = identity.copy(); light[12], light[13], light[14] = 20, 30, 100
    material = dict(id='substrate', baseColor=[.55, .24, .07, 1], roughness=1, metallic=1,
                    sheen=.2, coat=.15, textures=dict(roughness=rough, metallic=dark),
                    physicalLayers=[dict(mask=mask, roughness=.18, metallic=1)])
    scene = dict(version=1, jobID='finish-layer-test', sourceRevision='finish-layer-v1',
                 device=args.device, width=128, height=128, samples=256, seed=42,
                 adaptiveThreshold=0, denoise=False, maxBounces=6, exposureEV=0,
                 meshes=[mesh], curves=[], materials=[material],
                 camera=dict(type='orthographic', transform=camera, orthoScale=100, near=.1, far=10000),
                 lights=[dict(type='area', transform=light, color=[1, 1, 1], power=.08, size=[40, 60])],
                 background=dict(color=[.05, .05, .05], strength=1))

    def render(name, source):
        manifest = copy.deepcopy(source); manifest['outputDirectory'] = name
        path = root / (name + '.json'); path.write_text(json.dumps(manifest, indent=2) + '\n')
        result = subprocess.run([str(args.helper.resolve()), '--render', str(path)],
                                env=dict(os.environ, LAB_CYCLES_CACHE_DIR=str(root / 'cache')),
                                capture_output=True, text=True, timeout=600)
        (root / (name + '.events.jsonl')).write_text(result.stdout)
        (root / (name + '.stderr.log')).write_text(result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert result.returncode == 0, events[-1] if events else result.stderr
        complete = [item for item in events if item['type'] == 'completed'][-1]
        assert complete['device'] == args.device
        return pixels(Path(complete['finalPNG']))[2]

    original = render('stock-map-with-finish', scene)
    changed = copy.deepcopy(scene)
    changed['materials'][0]['textures'] = dict(roughness=dark, metallic=rough)
    altered = render('changed-stock-map', changed)
    reference = copy.deepcopy(scene)
    reference['materials'][0].pop('physicalLayers'); reference['materials'][0].pop('textures')
    reference['materials'][0].update(roughness=.18, metallic=1)
    expected = render('independent-finish-reference', reference)
    own = copy.deepcopy(scene)
    own['materials'][0]['physicalLayers'][0]['appearance'] = dict(textures=dict(roughness=own_rough, metallic=own_metal))
    own_pixels = render('finish-own-map', own)
    reference['materials'][0].update(roughness=.18 * .25, metallic=.3)
    own_expected = render('finish-own-map-reference', reference)

    def error(first, second, xs):
        values = [abs(first[(y*128+x)*4+c] - second[(y*128+x)*4+c])
                  for y in range(20, 108) for x in xs for c in range(3)]
        return dict(mean=sum(values)/len(values), maximum=max(values))

    report = dict(device=args.device,
                  finishIgnoresChangedStockMaps=error(original, altered, range(18, 46)),
                  finishMatchesIndependentReference=error(original, expected, range(18, 46)),
                  finishOwnMapsMatchReference=error(own_pixels, own_expected, range(18, 46)),
                  changedStockRemainsVisible=error(original, altered, range(82, 110)),
                  finishOwnMapsRemainVisible=error(original, own_pixels, range(18, 46)))
    for key in ('finishIgnoresChangedStockMaps', 'finishMatchesIndependentReference', 'finishOwnMapsMatchReference'):
        assert report[key]['mean'] < 1.5, (key, report[key])
    for key in ('changedStockRemainsVisible', 'finishOwnMapsRemainVisible'):
        assert report[key]['mean'] > 4, (key, report[key])
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
