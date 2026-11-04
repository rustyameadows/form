#!/usr/bin/env python3
"""Verify physical texture coordinates and tangent normal maps on real Cycles curves."""
import argparse
import array
import copy
import json
import math
from pathlib import Path
import struct
import subprocess
import zlib


def pixels(path):
    raw, compressed, offset = path.read_bytes(), bytearray(), 8
    while offset < len(raw):
        count = struct.unpack_from('>I', raw, offset)[0]
        kind, data = raw[offset + 4:offset + 8], raw[offset + 8:offset + 8 + count]
        if kind == b'IHDR':
            w, h, bits, color, _, _, interlace = struct.unpack('>IIBBBBB', data)
            assert bits == 8 and color == 6 and interlace == 0
        elif kind == b'IDAT':
            compressed.extend(data)
        offset += count + 12
    data, stride = zlib.decompress(compressed), w * 4
    previous, result = bytearray(stride), bytearray()
    for y in range(h):
        method, row = data[y * (stride + 1)], bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a, b, c = row[i - 4] if i >= 4 else 0, previous[i], previous[i - 4] if i >= 4 else 0
            if method == 0: prediction = 0
            elif method == 1: prediction = a
            elif method == 2: prediction = b
            elif method == 3: prediction = (a + b) // 2
            else:
                assert method == 4
                p = a + b - c
                distances = [abs(p - a), abs(p - b), abs(p - c)]
                prediction = [a, b, c][distances.index(min(distances))]
            row[i] = (row[i] + prediction) & 255
        result.extend(row)
        previous = row
    return w, h, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=['cpu', 'metal'], default='cpu')
    args = parser.parse_args()
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    identity = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
    camera = identity.copy(); camera[10], camera[14] = -1, 140

    def buffer(name, values, kind, components=1):
        data = array.array(kind, values)
        (root / name).write_bytes(data.tobytes())
        return dict(path=name, count=len(data)//components)

    def texture(name, values, width, height):
        buffer(name, values, 'f', 4)
        return dict(path=name, format='rgba32f', width=width, height=height, colorSpace='linear',
                    scale=[1/20, 1/(2*math.pi*5)], wrapS='repeat', wrapT='repeat')

    colors = [v for y in range(32) for x in range(32)
              for v in (1 if x<16 else 0.01, 0.01 if x<16 else 1, .2+.8*y/31, 1)]
    color = texture('color.rgba32f', colors, 32, 32)
    normal = texture('normal.rgba32f', [.85,.5,1,1], 1, 1)
    detail = texture('detail.rgba32f', [.5,.8,1,1], 1, 1)
    points = [v for i in range(9) for v in (-40+i*10,0,0)]
    curve = dict(id='strand', points=buffer('points.bin', points, 'd', 3),
                 radii=buffer('radii.bin', [5]*9, 'f'), firstKey=buffer('first.bin', [0], 'I'),
                 uvs=buffer('uv0.bin', [v for i in range(9) for v in (i*10,0)], 'f', 2),
                 uvs1=buffer('uv1.bin', [v for i in range(9) for v in (i*10+10,0)], 'f', 2),
                 materialIndex=0, transform=identity)
    base = dict(version=1, jobID='curve-physical-mapping', sourceRevision='generic-curve-v1',
                device=args.device, width=256, height=128, samples=32, denoise=False,
                adaptiveThreshold=0, transparent=True, curves=[curve], meshes=[],
                materials=[dict(id='strand',baseColor=[1,1,1,1],unlit=True,textures=dict(baseColor=color))],
                camera=dict(type='orthographic',transform=camera,orthoScale=60,near=.1,far=10000),
                lights=[], background=dict(color=[0,0,0],strength=0))
    env = dict(PATH='/usr/bin:/bin', LAB_CYCLES_CACHE_DIR=str(root/'cache'))

    def render(name, manifest):
        manifest = copy.deepcopy(manifest); manifest['outputDirectory'] = name
        path = root/(name+'.json'); path.write_text(json.dumps(manifest,indent=2)+'\n')
        result = subprocess.run([str(args.helper.resolve()),'--render',str(path)],env=env,
                                text=True,capture_output=True,timeout=600)
        (root/(name+'-events.jsonl')).write_text(result.stdout)
        (root/(name+'-stderr.log')).write_text(result.stderr)
        events = list(map(json.loads,result.stdout.splitlines()))
        assert result.returncode == 0 and events[-1]['type'] == 'completed', events[-1:]
        return pixels(root/name/'final.png')[2]

    uv0 = render('uv0',base)
    variant = copy.deepcopy(base); variant['materials'][0]['textures']['baseColor']['uvIndex'] = 1
    uv1 = render('uv1',variant)
    variant = copy.deepcopy(base)
    rotation = [0,1,0,0, -1,0,0,0, 0,0,1,0, 0,0,0,1]
    variant['curves'][0]['transform'] = rotation
    variant['camera']['transform'] = [0,1,0,0, -1,0,0,0, 0,0,-1,0, 0,0,140,1]
    rotated = render('rotated',variant)
    index = lambda x,y: (y*256+x)*4
    red = sum(uv0[index(x,64)] > uv0[index(x,64)+1]+40 for x in range(50,206))
    green = sum(uv0[index(x,64)+1] > uv0[index(x,64)]+40 for x in range(50,206))
    blue_difference = abs(uv0[index(120,57)+2]-uv0[index(120,70)+2])
    swapped = sum((uv0[index(x,64)]>uv0[index(x,64)+1]) != (uv1[index(x,64)]>uv1[index(x,64)+1]) for x in range(50,206))
    rotation_error = max(abs(a-b) for a,b in zip(uv0,rotated))
    assert red>30 and green>30, (red,green)
    assert blue_difference>30, blue_difference
    assert swapped>130, swapped
    assert rotation_error<=3, rotation_error
    lit = copy.deepcopy(base)
    lit['materials']=[dict(id='strand',baseColor=[.5,.5,.5,1],roughness=.4)]
    light=identity.copy();light[12:15]=[-45,20,80]
    lit['lights']=[dict(type='area',transform=light,power=.1,color=[1,1,1],size=[80,80])]
    baseline = render('normal-baseline',lit)
    lit['materials'][0]['textures']=dict(normal=normal)
    mapped = render('normal-mapped',lit)
    lit['materials'][0]['normalStrength']=0
    disabled = render('normal-disabled',lit)
    lit['materials'][0]['normalStrength']=1
    lit['materials'][0]['textures']['normalDetail']=detail
    detailed = render('normal-detail',lit)
    lit['materials'][0]['normalStrength']=0
    detail_disabled = render('normal-detail-disabled',lit)
    inside=[i+c for i in range(0,len(baseline),4) if baseline[i+3]>250 for c in range(3)]
    normal_difference=sum(abs(baseline[i]-mapped[i]) for i in inside)/len(inside)
    detail_difference=sum(abs(mapped[i]-detailed[i]) for i in inside)/len(inside)
    assert normal_difference>8, normal_difference
    assert detail_difference>3, detail_difference
    disabled_error=max(abs(baseline[i]-disabled[i]) for i in inside)
    detail_disabled_error=max(abs(mapped[i]-detail_disabled[i]) for i in inside)
    assert disabled_error<=1, disabled_error
    assert detail_disabled_error<=1, detail_disabled_error
    # Tangent-space vectors must follow UV direction and the texture affine,
    # including constant maps whose color samples alone cannot expose the bug.
    normal_case=copy.deepcopy(lit)
    normal_case['materials'][0]['textures']=dict(normal=copy.deepcopy(normal))
    normal_case['materials'][0]['normalStrength']=1
    negative=texture('negative-normal.rgba32f',[.15,.5,1,1],1,1)
    green_normal=texture('green-normal.rgba32f',[.5,.85,1,1],1,1)
    variant=copy.deepcopy(normal_case);variant['materials'][0]['textures']['normal']=negative
    negative_result=render('normal-negative-reference',variant)
    variant=copy.deepcopy(normal_case);variant['materials'][0]['textures']['normal']=green_normal
    green_result=render('normal-green-reference',variant)
    variant=copy.deepcopy(normal_case)
    variant['curves'][0]['uvs1']=buffer('uv1-reversed.bin',[v for i in range(9) for v in (80-i*10,0)],'f',2)
    variant['materials'][0]['textures']['normal']['uvIndex']=1
    reversed_result=render('normal-reversed-uv1',variant)
    variant=copy.deepcopy(normal_case);variant['materials'][0]['textures']['normal']['scale'][0]*=-1
    reflected_result=render('normal-reflected-scale',variant)
    variant=copy.deepcopy(normal_case);variant['materials'][0]['textures']['normal']['rotationDegrees']=90
    rotated_normal_result=render('normal-texture-rotation',variant)
    uv_reverse_error=max(abs(negative_result[i]-reversed_result[i]) for i in inside)
    reflection_error=max(abs(negative_result[i]-reflected_result[i]) for i in inside)
    normal_rotation_error=max(abs(green_result[i]-rotated_normal_result[i]) for i in inside)
    assert uv_reverse_error<=2,uv_reverse_error
    assert reflection_error<=2,reflection_error
    # Equal physical coordinate scales isolate a pure 90 degree rotation.
    # Constant maps are independent of the sampling location.
    assert normal_rotation_error<=2,normal_rotation_error
    variant=copy.deepcopy(normal_case);variant['materials'][0]['textures']['normal']['wrapS']='mirror'
    mirrored_result=render('normal-mirrored-repeat',variant)
    mirror_error=0
    for x in [70,110,150,190]:
        physical_u=((x+.5)-128)*120/256+40
        expected=mapped if int(math.floor(physical_u/20))%2==0 else negative_result
        mirror_error=max(mirror_error,max(abs(mirrored_result[index(x,64)+c]-expected[index(x,64)+c]) for c in range(3)))
    assert mirror_error<=2,mirror_error
    report=dict(device=args.device,alongRedPixels=red,alongGreenPixels=green,
                circumferenceBlueDifference=blue_difference,uv1SwappedPixels=swapped,
                rotationMaximumByteError=rotation_error,normalMeanByteDifference=normal_difference,
                detailMeanByteDifference=detail_difference,disabledNormalMaximumByteError=disabled_error,
                disabledDetailMaximumByteError=detail_disabled_error,
                normalReversedUV1MaximumByteError=uv_reverse_error,normalReflectedScaleMaximumByteError=reflection_error,
                normalTextureRotationMaximumByteError=normal_rotation_error,normalMirroredRepeatMaximumByteError=mirror_error)
    (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
