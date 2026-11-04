#!/usr/bin/env python3
"""Author small, explicitly estimated cut-edge texture data; no LAB/app calls.

This is an analytic data-field generator, not a photograph, measured scan, or
claim about Gmund fiber dimensions. It deliberately does not modify silhouettes.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random

from author_cycles_materials import ROOT, png, write_json

DEFAULT = ROOT / 'examples/cycles-materials/paper-followup'


def smooth(value):
    return value * value * (3 - 2 * value)


def field(width=1024, height=256, seed=64129):
    if min(width, height) < 32 or width * height > 1_048_576:
        raise ValueError('Use a bounded numerical texture grid')
    repeat = (8.0, 2.0)
    rng = random.Random(seed)
    values = [0.0] * (width * height)
    # Short, mainly in-plane fibers. Each compact Gaussian is periodically
    # wrapped, so both the field and its derivatives share the edge seam.
    fibers = []
    for _ in range(1100):
        x, y = rng.random()*repeat[0], rng.random()*repeat[1]
        length = rng.uniform(.10, .42)
        radius = rng.uniform(.009, .022)
        slope = rng.uniform(-.24, .24)
        amplitude = rng.uniform(.00035, .00135) * (1 if rng.random() > .18 else -.55)
        fibers.append((x, y, length, radius, slope, amplitude))
        xa, xb = math.floor((x-length*1.7)/repeat[0]*width), math.ceil((x+length*1.7)/repeat[0]*width)
        span = radius*2.5+abs(slope)*length*1.7
        ya, yb = math.floor((y-span)/repeat[1]*height), math.ceil((y+span)/repeat[1]*height)
        for py in range(ya, yb+1):
            dy = (py+.5)/height*repeat[1]-y
            for px in range(xa, xb+1):
                dx = (px+.5)/width*repeat[0]-x
                exponent = (dx/length)**2 + ((dy-slope*dx)/radius)**2
                if exponent < 6.25:
                    values[(py % height)*width+px % width] += amplitude*math.exp(-exponent)
    mean = sum(values)/len(values)
    values = [v-mean for v in values]
    normal, color, rough = bytearray(), bytearray(), bytearray()
    slopes = []
    for y in range(height):
        for x in range(width):
            index = y*width+x
            du = (values[y*width+(x+1)%width]-values[y*width+(x-1)%width])/(2*repeat[0]/width)
            dv = (values[((y+1)%height)*width+x]-values[((y-1)%height)*width+x])/(2*repeat[1]/height)
            norm = math.sqrt(1+du*du+dv*dv)
            normal.extend(round(255*(v*.5+.5)) for v in (-du/norm, -dv/norm, 1/norm))
            # Near-white multiplier only: avoid dirty pores or conspicuous
            # dark strata. Color is encoded sRGB; normal/roughness are Raw.
            signal = math.tanh(values[index]/.0018)
            linear = .988 + .012*signal
            encoded = 1.055*linear**(1/2.4)-.055
            c = round(255*encoded)
            color.extend((c,c,c))
            r = round(255*(.99+.01*signal))
            rough.extend((r,r,r))
            slopes.append(math.hypot(du,dv))
    return dict(normal=bytes(normal), baseColor=bytes(color), roughness=bytes(rough)), dict(
        width=width, height=height, physical_repeat_mm=list(repeat), seed=seed,
        estimated_fiber_half_length_mm=[.10,.42], estimated_fiber_gaussian_radius_mm=[.009,.022],
        estimated_signed_height_mm=[min(values),max(values)], rms_height_mm=math.sqrt(sum(v*v for v in values)/len(values)),
        maximum_slope=max(slopes), notes='Analytic artist estimate, not measured fiber data or a manufacturer texture. Normal shading only; no silhouette displacement. Color modulation is bounded to 0.976–1.0 linear multiplier and roughness to 0.98–1.0 multiplier.')


def prepare(output):
    output.mkdir(parents=True,exist_ok=True)
    maps, details = field()
    assets = []
    for channel, data in maps.items():
        path = output / ('estimated-cotton-cut-edge-'+channel+'.png')
        png(path,details['width'],details['height'],data)
        assets.append(dict(file=path.name,channel=channel,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                           color_space='srgb' if channel=='baseColor' else 'data',license='CC0-1.0',
                           origin='Original analytic project-authoring data, dedicated to CC0; no manufacturer photograph pixels used.'))
    provenance = dict(version=1,generator='scripts/prepare_cycles_paper_edges.py',
        generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),assets=assets,**details,
        mapping='UV0 physical millimeters: U contour arc length, V from back to front through the stock/ply caliper. Repeat remains 8×2 mm for both 0.5 and1.0 mm sheets.',
        reference_links=[dict(url='https://www.gmund.com/shop/media/pdf/instructions/Gmund_Cotton_Printing_Tips_engl.pdf',
                              evidence='manufacturerSpecification',notes='600/610gsm approximate1mm caliper. Does not establish microscopic fiber dimensions.'),
                         dict(url='https://www.gmund.com/shop/en_int/collections/gmund-cotton.html',evidence='photograph',
                              notes='Manufacturer real-product reference; linked only. No measured cut-edge micrograph is claimed.')],
        proposed_normal_strengths=[.25,.5],visual_acceptance='pending actual LAB before/after render review')
    write_json(output/'provenance.json',provenance)
    return provenance


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=DEFAULT)
    args=parser.parse_args();value=prepare(args.output.resolve())
    print(json.dumps(dict(output=str(args.output.resolve()),assets=value['assets'],applied=False),indent=2))


if __name__=='__main__':main()
