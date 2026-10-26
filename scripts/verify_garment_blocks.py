#!/usr/bin/env python3
"""Read-only independent check of the original Field block PDF/SVG proof.

Usage: python verify_garment_blocks.py proof-folder [--report result.json]
Requires pypdf (and Pillow for the shared calibration-path reader).
"""
import argparse
import json
import math
import pathlib
import re
import xml.etree.ElementTree as ET
from pypdf import PdfReader
from pypdf.generic import ContentStream
from verify_sewing_tiles import physical_segments

K=72/25.4


def close(a,b,tolerance=0.002):
    assert abs(a-b)<=tolerance,(a,b)


def multiply(a,b):
    x,y,z,w,u,v=a;A,B,C,D,E,F=b
    return (x*A+z*B,y*A+w*B,x*C+z*D,y*C+w*D,x*E+z*F+u,y*E+w*F+v)


def stroked_rectangles(page,reader):
    matrix=(1,0,0,1,0,0);stack=[];path=[];result=[]
    for args,op in ContentStream(page.get_contents(),reader).operations:
        if op==b'q':stack.append(matrix)
        elif op==b'Q':matrix=stack.pop()
        elif op==b'cm':matrix=multiply(matrix,tuple(map(float,args)))
        elif op==b're':
            x,y,w,h=map(float,args);a,b,c,d,u,v=matrix
            points=[(x,y),(x+w,y),(x+w,y+h),(x,y+h),(x,y)]
            path.append([((a*X+c*Y+u)/K,(b*X+d*Y+v)/K) for X,Y in points])
        elif op in [b'S',b's',b'B',b'B*']:
            for rectangle in path:result.extend(zip(rectangle,rectangle[1:]))
            path=[]
        elif op in [b'n',b'f',b'f*']:path=[]
    return result


def verify(folder):
    metadata=json.loads((folder/'field-skirt-metadata.json').read_text())
    svg=ET.parse(folder/'field-skirt-base.svg').getroot()
    width=float(svg.attrib['width'].removesuffix('mm'));height=float(svg.attrib['height'].removesuffix('mm'))
    assert list(map(float,svg.attrib['viewBox'].split()))==[0,0,width,height]
    close(width,metadata['width_mm']);close(height,metadata['height_mm'])
    pdf=PdfReader(folder/'field-skirt-base.pdf');assert len(pdf.pages)==1
    close(float(pdf.pages[0].mediabox.width)/K,width);close(float(pdf.pages[0].mediabox.height)/K,height)
    parents={c:p for p in svg.iter() for c in p}
    def matrix(element):
        transforms=[]
        while element is not None:
            if 'transform' in element.attrib:
                text=element.attrib['transform'];match=re.fullmatch(r'matrix\(([^)]+)\)',text)
                assert match,'Unsupported independent transform parser input: '+text
                transforms.append(tuple(map(float,match[1].replace(',',' ').split())))
            element=parents.get(element)
        result=(1,0,0,1,0,0)
        for t in reversed(transforms):result=multiply(result,t)
        return result
    def endpoints(element):
        text=element.attrib['d'];assert re.fullmatch(r'M[-+\d.eE ]+L[-+\d.eE ]+',text),text
        x,y,X,Y=map(float,re.findall(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?',text))
        a,b,c,d,u,v=matrix(element)
        return ((a*x+c*y+u,b*x+d*y+v),(a*X+c*Y+u,b*X+d*Y+v))
    blue=[e for e in svg.iter() if e.tag.endswith('path') and e.attrib.get('stroke')=='#43718A']
    sides=[e for e in blue if e.attrib.get('stroke-dasharray')=='3.0 2.0']
    assert len(sides)==4,'Only the two full physical sides of each panel are blue sewing edges.'
    for element in sides:
        a,b=endpoints(element);close(math.dist(a,b),718)
    references=[e for e in blue if e.attrib.get('stroke-dasharray')=='2.0 1.0']
    assert len(references)==5
    split=[]
    for element in references:
        a,b=endpoints(element);length=math.dist(a,b)
        assert abs(length-570)<0.002 or abs(length-272.5)<0.002
        if abs(length-272.5)<0.002:split.append((a,b))
    assert len(split)==2
    split.sort(key=lambda line:line[0][0]);close(math.dist(split[0][1],split[1][0]),25)
    folds=[e for e in svg.iter() if e.tag.endswith('path') and e.attrib.get('stroke')=='#A67B41' and e.attrib.get('stroke-dasharray')=='6.0 2.0']
    assert len(folds)==8
    body=[p for p in metadata['pieces'] if p['name'].endswith(('front','back'))]
    assert len(body)==2
    for piece in body:
        close(piece['cut_width_mm'],570);close(piece['cut_height_mm'],718)
        assert piece['unstitched_edges']==[0,2]
        assert sorted(g['offset_mm'] for g in piece['construction_guides'])==[8,38,68,673,688,703]
    assert len(metadata['seams'])==2 and all(s['matches'] and abs(s['first_length_mm']-718)<0.002 for s in metadata['seams'])
    segments=physical_segments(pdf.pages[0],pdf)+stroked_rectangles(pdf.pages[0],pdf)
    assert sum(abs(math.dist(a,b)-50)<0.002 for a,b in segments)>=3,'Actual 50 mm calibration square is missing.'
    text=' '.join((pdf.pages[0].extract_text() or '').split())
    assert 'stitch its inner folded edge' in text and '718.0' in text
    preview=folder/'native-three-size-review.pdf'
    native=None
    if preview.exists():
        document=PdfReader(preview);assert len(document.pages)==3
        dimensions=[[float(p.mediabox.width)/K,float(p.mediabox.height)/K] for p in document.pages]
        for a,b in zip(dimensions,dimensions[1:]):close(b[0]-a[0],40);close(b[1]-a[1],10)
        native={'pages':3,'physical_page_sizes_mm':dimensions}
    return {'reader':'pypdf','svg_parser':'Python ElementTree','sheet_mm':[width,height],
            'front_back_cut_mm':[570,718],'full_side_sewing_edges':4,'side_seam_mm':718,
            'nominal_finished_length_mm':650,'waist_fold_mm':38,'hem_fold_mm':688,
            'hem_turns_mm':[15,15],'casing_opening_mm':25,'unstitched_source_edges':[0,2],
            'calibration_square_mm':50,'native_size_review':native,'verified_fit':False}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('folder',type=pathlib.Path)
    parser.add_argument('--report',type=pathlib.Path);args=parser.parse_args()
    report=verify(args.folder);data=json.dumps(report,indent=2)+'\n'
    if args.report:args.report.write_text(data)
    print(data,end='')


if __name__=='__main__':main()
