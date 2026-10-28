#!/usr/bin/env python3
"""Read-only verification of the local optical proof using pypdf/Pillow/Poppler.

Uses the workspace-bundled Python dependencies. Never connects to FORM.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import xml.etree.ElementTree as ET
from PIL import Image
from pypdf import PdfReader


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('folder',type=pathlib.Path);args=parser.parse_args();root=args.folder
    source=json.loads((root/'Source.json').read_text());art=source['objects'][0]['artwork']
    affected=[e for e in art['elements'] if e.get('typography',{}).get('opticalSizing')]
    assert len(affected)==3 and source['schemaVersion']>=42
    assert [e['typography']['opticalSizing']['mode'] for e in affected]==['automatic','explicit','none']
    assert all(e['fontSize']==32 and e['typography']['variations']['1869640570']==19 for e in affected)
    assert affected[1]['typography']['opticalSizing']['points']==72
    document=PdfReader(root/'optical.pdf');assert len(document.pages)==1
    page=document.pages[0];assert page.get('/Rotate',0)==0
    for box in [page.mediabox,page.trimbox]:
        assert abs(float(box.width)*25.4/72-230)<.0001 and abs(float(box.height)*25.4/72-165)<.0001
    svg=ET.fromstring((root/'optical.svg').read_bytes());ns={'s':'http://www.w3.org/2000/svg'}
    assert svg.attrib['width']=='230.0mm' and svg.attrib['height']=='165.0mm'
    for e in affected:
        group=svg.find(f".//s:g[@id='layer-{e['id']}']",ns);assert group is not None
        assert group.find('.//s:path',ns) is not None and group.find('.//s:text',ns) is None
    assert svg.find('.//s:text',ns) is not None, 'Ordinary legacy labels should retain the live-text path.'
    image=Image.open(root/'optical.png');dx,dy=image.info['dpi'];w,h=image.size
    assert (w,h)==(1358,974), 'The 150 DPI request must not silently use the 300 DPI default.'
    assert abs(dx-150)<.1 and abs(dy-150)<.1
    assert abs(w/dx*25.4-230)<.03 and abs(h/dy*25.4-165)<.03
    metrics=json.loads((root/'Metrics.json').read_text());assert len(metrics)==3
    assert [m['effective_opsz'] for m in metrics]==[32,72,28]
    assert len({m['A_advance_points'] for m in metrics})==3
    for m in metrics:
        assert m['source_legacy_opsz']==19 and abs(m['A_advance_points']-m['mm_normalized_A_advance_points'])<1e-10
    subprocess.run(['pdftoppm','-singlefile','-scale-to','1400','-png',str(root/'optical.pdf'),str(root/'verified-pdf')],check=True,capture_output=True)
    report=dict(physical_page_mm=[230,165],raster_pixels=[w,h],actual_png_dpi=[dx,dy],optical_source_legacy_axes_retained=True,
                effective_axes=[m['effective_opsz'] for m in metrics],point_mm_metrics_match=True,
                optical_svg_layers_outlined=3,ordinary_live_text_retained=True,
                files={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in ['Source.json','Metrics.json','optical.svg','optical.pdf','optical.png']},
                scope='Physical boxes, source assignments and vector fallback checked independently; actual metric records come from the tested Core Text fixture.')
    (root/'independent-report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))


if __name__=='__main__':main()
