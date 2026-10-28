#!/usr/bin/env python3
"""Independently verify a tiled pattern PDF, metadata and authoritative source PDF.

Requires pypdf, Pillow and Poppler's pdftoppm. Reads files only; never prints.
Run: python verify_sewing_tiles.py tiled.pdf metadata.json source.pdf [--report result.json]
"""
import argparse
import json
import math
import pathlib
import shutil
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageStat
from pypdf import PdfReader
from pypdf.generic import ContentStream

K = 72 / 25.4


def close(a, b, tolerance=0.002):
    assert abs(float(a) - float(b)) <= tolerance, (a, b)


def physical_segments(page, reader, gray=None):
    """Read stroked cover segments with the PDF graphics-state matrix applied."""
    matrix = (1., 0., 0., 1., 0., 0.)
    stack, path, segments = [], [], []
    stroke, line_width = (0.,), 1.

    def point(x, y):
        a, b, c, d, tx, ty = matrix
        return ((a*x+c*y+tx)/K, (b*x+d*y+ty)/K)

    for args, op in ContentStream(page.get_contents(), reader).operations:
        if op == b'q':
            stack.append((matrix, stroke, line_width))
        elif op == b'Q':
            matrix, stroke, line_width = stack.pop()
        elif op == b'cm':
            a,b,c,d,x,y = matrix
            e,f,g,h,u,v = map(float, args)
            matrix = (a*e+c*f, b*e+d*f, a*g+c*h, b*g+d*h, a*u+c*v+x, b*u+d*v+y)
        elif op in (b'SC', b'SCN', b'G', b'RG', b'K'):
            stroke = tuple(float(a) for a in args)
        elif op == b'w':
            line_width = float(args[0])
        elif op == b'm':
            path.append([point(*map(float, args))])
        elif op == b'l' and path:
            path[-1].append(point(*map(float, args)))
        elif op == b'h' and path:
            path[-1].append(path[-1][0])
        elif op in (b'S', b's', b'B', b'B*'):
            if op == b's' and path and path[-1]:
                path[-1].append(path[-1][0])
            if gray is None or (len(stroke)==1 and abs(stroke[0]-gray)<0.00001 and abs(line_width-0.12)<0.00001):
                for contour in path:
                    segments.extend(zip(contour, contour[1:]))
            path = []
        elif op in (b'n', b'f', b'f*'):
            path = []
    return segments


def verify(tiled_path, metadata_path, source_path):
    metadata = json.loads(metadata_path.read_text())
    plan = metadata.get('tiled', metadata)
    reader, source = PdfReader(tiled_path), PdfReader(source_path)
    assert len(source.pages) == 1
    assert len(reader.pages) == plan['page_count'] == len(plan['tiles'])+1 <= 200
    assert plan['scale'] == 1 and plan['units'] == 'mm'
    sw, sh = plan['sheet_width_mm'], plan['sheet_height_mm']
    width, height = plan['source_width_mm'], plan['source_height_mm']
    close(source.pages[0].mediabox.width/K, width)
    close(source.pages[0].mediabox.height/K, height)
    assert plan['rows']*plan['columns'] == len(plan['tiles'])
    mark_segments = 0
    footer_labels = []
    for index, page in enumerate(reader.pages):
        close(page.mediabox.width/K, sw)
        close(page.mediabox.height/K, sh)
        assert page.cropbox == page.mediabox
        if index:
            tile = plan['tiles'][index-1]
            assert tile['pdf_page'] == index+1
            r = tile['trim_on_sheet_mm']
            expected = (r['x'], sh-r['y']-r['height'], r['x']+r['width'], sh-r['y'])
            for value, actual in zip(expected, page.trimbox):
                close(value, float(actual)/K)
            ink = tile['content_on_sheet_mm']
            for first, second in physical_segments(page, reader, gray=0.55):
                xs = [first[0], second[0]]
                ys = [sh-first[1], sh-second[1]]
                # Quartz inlines source paths; isolate the dedicated 0.55-gray / 0.12-mm mark strokes.
                # Include half the actual 0.12 mm stroke width, not just its centerline.
                assert (max(xs)+0.06 < ink['x'] or min(xs)-0.06 > ink['x']+ink['width'] or
                        max(ys)+0.06 < ink['y'] or min(ys)-0.06 > ink['y']+ink['height']), 'A mark crosses source ink'
                mark_segments += 1
            def footer(text, cm, tm, font, font_size):
                if 'PDF page' not in text:
                    return
                baseline = sh-(cm[1]*tm[4]+cm[3]*tm[5]+cm[5])/K
                font_height = abs(tm[3]*cm[3]*font_size)/K
                assert baseline-font_height > ink['y']+ink['height'], 'A footer label crosses source ink'
                footer_labels.append(tile['id'])
            page.extract_text(visitor_text=footer)
    segments = physical_segments(reader.pages[0], reader)
    lengths = [math.dist(a,b) for a,b in segments]
    squares = []
    for i in range(len(segments)-2):
        triple = segments[i:i+3]
        points = [p for pair in triple for p in pair]
        if all(abs(math.dist(a,b)-50)<0.002 for a,b in triple) and all(math.dist(triple[j][1],triple[j+1][0])<0.002 for j in [0,1]):
            if abs(max(p[0] for p in points)-min(p[0] for p in points)-50)<0.002 and abs(max(p[1] for p in points)-min(p[1] for p in points)-50)<0.002:
                squares.append(triple)
    assert squares, 'Missing actual 50 × 50 mm calibration-square geometry'
    assert any(abs(x-100)<0.002 for x in lengths), 'Missing real 100 mm calibration rule'
    tiles = {(t['row'],t['column']):t for t in plan['tiles']}
    close(sum(t['trim_source_mm']['width']*t['trim_source_mm']['height'] for t in tiles.values()), width*height, 0.00001)
    for (row,col), tile in tiles.items():
        r, owned = tile['source_mm'], tile['trim_source_mm']
        assert 0<=r['x']<=owned['x'] and 0<=r['y']<=owned['y']
        assert owned['x']+owned['width']<=r['x']+r['width']+0.000001<=width+0.000002
        assert owned['y']+owned['height']<=r['y']+r['height']+0.000001<=height+0.000002
        close(tile['content_on_sheet_mm']['width'],r['width'])
        close(tile['content_on_sheet_mm']['height'],r['height'])
        close(owned['x'], 0 if col==1 else tiles[row,col-1]['trim_source_mm']['x']+tiles[row,col-1]['trim_source_mm']['width'])
        close(owned['y'], 0 if row==1 else tiles[row-1,col]['trim_source_mm']['y']+tiles[row-1,col]['trim_source_mm']['height'])
        if col == plan['columns']: close(owned['x']+owned['width'], width)
        if row == plan['rows']: close(owned['y']+owned['height'], height)
        if col < plan['columns']: close(r['x']+r['width']-tiles[row,col+1]['source_mm']['x'], plan['overlap_mm'])
        if row < plan['rows']: close(r['y']+r['height']-tiles[row+1,col]['source_mm']['y'], plan['overlap_mm'])
    # Poppler is independent of the app's Quartz/PDFKit parser and renderer.
    binary = shutil.which('pdftoppm')
    assert binary, 'Install Poppler so pdftoppm is on PATH.'
    density = 4
    assert width*height*density*density <= 40_000_000, 'Independent raster proof is capped at 40 megapixels.'
    errors = []
    ink = overlap_ink = 0
    full_pixels = 0
    full_error = 0.0
    with tempfile.TemporaryDirectory(prefix='form-tiles-proof-') as temporary:
        folder = pathlib.Path(temporary)
        def render(path, page, name):
            prefix = folder/name
            subprocess.run([binary,'-f',str(page),'-l',str(page),'-singlefile','-r',str(25.4*density),'-png',str(path),str(prefix)],check=True,capture_output=True)
            return Image.open(prefix.with_suffix('.png')).convert('RGB')
        reference = render(source_path,1,'source')
        def rgb(image,x,y):
            return image.getpixel((min(image.width-1,max(0,math.floor(x*density))), min(image.height-1,max(0,math.floor(y*density)))))
        for tile in plan['tiles']:
            image = render(tiled_path,tile['pdf_page'],tile['id'])
            r,o,p = tile['source_mm'],tile['trim_source_mm'],tile['content_on_sheet_mm']
            bounds = (math.floor(p['x']*density), math.floor(p['y']*density),
                      math.ceil((p['x']+p['width'])*density), math.ceil((p['y']+p['height'])*density))
            actual = image.crop(bounds)
            expected = reference.transform(actual.size, Image.Transform.AFFINE,
                (1,0,r['x']*density+bounds[0]-p['x']*density,0,1,r['y']*density+bounds[1]-p['y']*density),
                resample=Image.Resampling.BICUBIC, fillcolor='white')
            difference = ImageChops.difference(actual,expected)
            pixels = actual.width*actual.height
            full_error += sum(ImageStat.Stat(difference).sum)/(3*255)
            full_pixels += pixels
            actual.close(); expected.close(); difference.close()
            y=r['y']+0.5
            while y<r['y']+r['height']-0.5:
                x=r['x']+0.5
                while x<r['x']+r['width']-0.5:
                    a=rgb(reference,x,y); b=rgb(image,p['x']+x-r['x'],p['y']+y-r['y'])
                    errors.append(sum(abs(a[i]-b[i]) for i in range(3))/(3*255))
                    if min(a)<204:
                        ink += 1
                        overlap_ink += int(x<o['x'] or x>o['x']+o['width'] or y<o['y'] or y>o['y']+o['height'])
                    x+=2
                y+=2
            image.close()
        reference.close()
    mean=sum(errors)/len(errors)
    assert ink>100 and overlap_ink>0, 'Continuity check must sample real ink, including repeated overlap.'
    assert mean<0.01, f'Unscaled translated vector ink differs: mean RGB error {mean}'
    full_mean = full_error/full_pixels
    assert full_mean<0.01, f'Exhaustive translated source-pixel comparison differs: {full_mean}'
    assert mark_segments>=8*len(tiles), 'Missing gutter trim ticks'
    assert set(footer_labels)=={t['id'] for t in tiles.values()}, 'Missing external tile footer labels'
    return {'reader':'pypdf','renderer':'Poppler','pages':len(reader.pages),'tiles':len(tiles),
            'rows':plan['rows'],'columns':plan['columns'],'sheet_mm':[sw,sh],'source_mm':[width,height],
            'calibration_square_mm':50,'calibration_rule_mm':100,'scale':1,
            'coverage_and_trim_partition':'no gaps or duplication after trimming','ink_samples':ink,
            'overlap_ink_samples':overlap_ink,'raster_samples':len(errors),'mean_rgb_error':mean,
            'source_pixels_checked':full_pixels,'all_source_pixels_mean_rgb_error':full_mean,
            'gutter_mark_segments_checked':mark_segments,'footer_labels_checked':len(set(footer_labels)),
            'all_marks_outside_source':True}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tiled_pdf',type=pathlib.Path)
    parser.add_argument('metadata_json',type=pathlib.Path)
    parser.add_argument('source_pdf',type=pathlib.Path)
    parser.add_argument('--report',type=pathlib.Path)
    args=parser.parse_args()
    report=verify(args.tiled_pdf,args.metadata_json,args.source_pdf)
    data=json.dumps(report,indent=2)+'\n'
    if args.report:
        args.report.write_text(data)
    print(data,end='')


if __name__=='__main__': main()
