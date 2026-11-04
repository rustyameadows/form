#!/usr/bin/env python3
"""Prepare optional editable ClothMesh data and labeled offline geometry diagrams.

No app calls, project JSON writes, render emulation or application fixtures.
The controls are ordinary project-authoring data. A later explicitly chosen
form_cloth configure edit is required to apply a prepared mesh.
"""
import argparse
import html
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def tangent(u, v, width, controls):
    slope = 0.0
    for fold in controls['folds']:
        center = fold['center_u'] + fold['drift_u'] * (v - .5)
        delta = u - center
        amplitude = fold['height_mm'] * (1 + fold['along_depth_variation'] * math.sin(math.pi * (v + .15)))
        slope += -2 * delta / (fold['width_u']**2 * width) * amplitude * math.exp(-(delta / fold['width_u'])**2)
    return math.atan(slope)


def mesh(inputs, sampling, controls):
    width, depth, caliper = (inputs[k] for k in ('width_mm', 'depth_mm', 'caliper_mm'))
    body, turn, rows = (sampling[k] for k in ('body_columns', 'turn_columns', 'rows'))
    columns = body + turn
    if (columns + 1) * (rows + 1) > 4096 or 2 * columns * rows > 8192:
        raise ValueError('Prepared mesh exceeds the existing generic cloth budget')
    points, uv, links, triangles = [], [], [], []
    for row in range(rows + 1):
        v = row / rows
        start = controls['turn_start_u'] + controls['turn_drift_u'] * math.sin(math.pi * v * 2)
        samples = [start * i / body for i in range(body + 1)] + [start + (1 - start) * i / turn for i in range(1, turn + 1)]
        x = -width / 2
        y = controls['edge_wave_mm'] * math.sin(math.pi * v * 2 + controls['edge_wave_phase'])
        z = (v - .5) * depth
        angle0 = tangent(start, v, width, controls)
        previous = 0
        for column, u in enumerate(samples):
            if column:
                midpoint = (u + previous) / 2
                angle = tangent(midpoint, v, width, controls) if column <= body else angle0 + math.radians(controls['turn_angle_degrees']) * (midpoint - start) / (1 - start)
                length = (u - previous) * width
                x += length * math.cos(angle)
                y += length * math.sin(angle)
            points.append(dict(x=x, y=y, z=z)); uv.append(dict(x=u, y=v))
            index = row * (columns + 1) + column
            if column: links.append(dict(a=index - 1, b=index, kind='warp'))
            if row: links.append(dict(a=index - columns - 1, b=index, kind='weft'))
            if column and row: links.append(dict(a=index - columns - 2, b=index, kind='shear'))
            if column > 1: links.append(dict(a=index - 2, b=index, kind='bendDistance'))
            if row > 1: links.append(dict(a=index - 2 * (columns + 1), b=index, kind='bendDistance'))
            previous = u
    xmid = (min(p['x'] for p in points) + max(p['x'] for p in points)) / 2
    minimum = min(p['y'] for p in points)
    for p in points: p['x'] -= xmid; p['y'] += caliper / 2 - minimum
    for row in range(rows):
        for column in range(columns):
            a = row * (columns + 1) + column; b = a + 1; c = a + columns + 1; d = c + 1
            triangles.extend([dict(a=a, b=c, c=b), dict(a=b, b=c, c=d)])
    masses = [0.0] * len(points)
    smallest_area = math.inf
    for triangle in triangles:
        a, b, c = (points[triangle[k]] for k in ('a', 'b', 'c'))
        first = [b[k] - a[k] for k in ('x', 'y', 'z')]; second = [c[k] - a[k] for k in ('x', 'y', 'z')]
        cross = [first[1]*second[2]-first[2]*second[1], first[2]*second[0]-first[0]*second[2], first[0]*second[1]-first[1]*second[0]]
        area = math.sqrt(sum(v*v for v in cross)) / 2
        smallest_area = min(smallest_area, area)
        share = area / 1_000_000 * (inputs['gsm'] / 1000) / 3
        for key in ('a', 'b', 'c'): masses[triangle[key]] += share
    if smallest_area < .000001 or not all(math.isfinite(v) and v >= 1e-12 for v in masses):
        raise ValueError('Degenerate or zero-mass cloth element')
    if len(links) > 32768: raise ValueError('Prepared links exceed the existing generic cloth budget')
    def orient(a,b,c): return (b['x']-a['x'])*(c['y']-a['y'])-(b['y']-a['y'])*(c['x']-a['x'])
    crossings=0
    for row in range(rows+1):
        line=points[row*(columns+1):(row+1)*(columns+1)]
        for first in range(columns):
            for second in range(first+2,columns):
                a,b,c,d=line[first],line[first+1],line[second],line[second+1]
                if orient(a,b,c)*orient(a,b,d)<-1e-10 and orient(c,d,a)*orient(c,d,b)<-1e-10:crossings+=1
    if crossings:raise ValueError('A prepared warp section crosses itself')
    result = dict(restPositionsMm=points, massesKg=masses, triangles=triangles, uv=uv, links=links, pins=[], panelIDs=[0]*len(points))
    report = dict(vertices=len(points), triangles=len(triangles), links=len(links), mass_kg=sum(masses), minimum_triangle_area_mm2=smallest_area,
                  bounds_mm={k:[min(p[k] for p in points), max(p[k] for p in points)] for k in ('x','y','z')},
                  warp_arc_length_mm=width, material_uv_extent=[1,1], caliper_mm=caliper, sampled_warp_section_crossings=crossings,
                  status='offline geometry checks only; no actual LAB render or visual acceptance')
    return result, report


def diagram(value, name):
    points=value['restPositionsMm']
    # Orthographic engineering projection. Deliberately no material shading.
    def project(p):return (310 + 2.5*(p['x']-.55*p['z']), 295 - 2.5*(p['y']+.35*p['x']+.5*p['z']))
    segments=[]
    stride=next(i for i,uv in enumerate(value['uv']) if uv['y']>0)
    last_row=len(points)//stride-1
    for edge in value['links']:
        row,column=divmod(edge['a'],stride)
        if edge['kind']=='warp' and (row%4==0 or row==last_row) or edge['kind']=='weft' and (column%4==0 or column==stride-1):
            xy=[project(points[edge[k]]) for k in ('a','b')]
            segments.append('<path d="M'+' L'.join(f'{x:.2f},{y:.2f}' for x,y in xy)+'"/>')
    return '<svg xmlns="http://www.w3.org/2000/svg" width="700" height="430" viewBox="0 0 700 430"><rect width="700" height="430" fill="#f5f5f1"/><text x="20" y="27" font-size="16" font-family="sans-serif">'+html.escape(name)+'</text><text x="20" y="49" font-size="12" font-family="sans-serif">Offline wire projection only — not a LAB render or acceptance evidence</text><g fill="none" stroke="#456473" stroke-width=".35">'+''.join(segments)+'</g></svg>'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controls',type=Path,default=ROOT/'examples/cycles-materials/geometry/compound-fold-controls.json')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/cycles-materials/proposals/compound-folds')
    args=parser.parse_args();control=json.loads(args.controls.read_text())
    args.output.mkdir(parents=True,exist_ok=True);reports=[]
    for index,definition in enumerate(control['variants']):
        value,report=mesh(control['physical_inputs'],control['sampling'],definition)
        filename=f'variant-{index+1}.mesh.json'
        encoded=json.dumps(value,separators=(',',':'))+'\n'
        if len(encoded.encode())>7*1024*1024:raise ValueError('Mesh leaves insufficient room in an8MiB MCP request')
        (args.output/filename).write_text(encoded)
        (args.output/f'variant-{index+1}.svg').write_text(diagram(value,definition['name']))
        reports.append(dict(name=definition['name'],mesh=filename,bytes=len(encoded.encode()),**report))
    (args.output/'proposal.json').write_text(json.dumps(dict(controls=control,variants=reports,applied=False),indent=2)+'\n')
    print(json.dumps(dict(output=str(args.output),applied=False,variants=reports)))


if __name__=='__main__':main()
