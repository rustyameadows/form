#!/usr/bin/env python3
"""Independently verify captured collection packets. Read-only FORM/device scope.

Uses bundled pypdf/Pillow/Poppler; --embroidery-python selects the already
installed, validation-only Pyembroidery1.5.1 environment. Never installs anything.
"""
import argparse
import csv
import hashlib
import io
import json
import pathlib
import re
import subprocess
import zipfile
import unicodedata
import xml.etree.ElementTree as ET
from decimal import Decimal, localcontext, ROUND_HALF_EVEN
from pypdf import PdfReader


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_name(name):
    p=pathlib.PurePosixPath(name)
    assert name and not name.startswith('/') and '\\' not in name and ':' not in name
    assert all(x not in ('','.','..') for x in name.split('/')) and not any(ord(x)<32 for x in name)
    assert len(p.parts)<=12


def neutral(text):
    stripped=text
    while stripped and (stripped[0].isspace() or unicodedata.category(stripped[0]) in ('Cc','Cf')):
        stripped=stripped[1:]
    return ("'" if (stripped[:1] in '=+-@' and stripped) or text[:1] in ('\t','\r','\n') else '')+text


def packet(folder, embroidery_python=None, render=False):
    manifest=json.loads((folder/'Manifest.json').read_bytes())
    assert manifest['schema']==45 and manifest['machine_contacted'] is False
    assert manifest['inventory_deducted'] is False and manifest['physical_production_verified'] is False
    assert len(manifest['files'])<=255
    total=0
    for name,meta in manifest['files'].items():
        safe_name(name);data=(folder/name).read_bytes();total+=len(data)
        assert 0<len(data)<=64_000_000 and len(data)==meta['bytes'] and digest(data)==meta['sha256']
    assert total+len((folder/'Manifest.json').read_bytes())<=128_000_000
    source=json.loads((folder/'Source.json').read_bytes());plan=json.loads((folder/'Collection.json').read_bytes())
    revision=json.loads((folder/'Revision.json').read_bytes());bom=json.loads((folder/'BOM.json').read_bytes())
    assert digest((folder/'Source.json').read_bytes())==manifest['source_digest']==revision['sourceDigest']
    assert digest((folder/'Revision.json').read_bytes())==manifest['revision_digest']
    assert source['plan']==plan==revision['plan'] and bom==revision['report']
    assert len(bom['rows'])<=2000 and len({x['id'] for x in bom['rows']})==len(bom['rows'])
    assert not source['project'].get('collectionProduction') and not source['project'].get('printSetups') and not source['project'].get('studioPresentation')
    table=list(csv.DictReader(io.StringIO((folder/'BOM.csv').read_text())))
    assert len(table)==len(bom['rows'])
    subtotals={};rounded=0
    with localcontext() as ctx:
        ctx.prec=160
        for row,entry in zip(bom['rows'],table):
            assert row['id']==entry['row_id'] and entry['name']==neutral(row['name'])
            for key in ('supplier','sku','notes'):
                assert entry[key]==neutral(row.get(key,''))
            assert entry['quantity']==row.get('quantity','Unknown') and entry['cost']==row.get('cost','Unknown')
            if 'calculation' in row:
                c=row['calculation'];assert c['policyVersion']==1 and c['scale']==12 and c['roundingMode']=='half_even'
                a,b=Decimal(c['numerator']),Decimal(c['denominator']);expected=(a/b).quantize(Decimal('0.000000000001'),rounding=ROUND_HALF_EVEN)
                assert expected==Decimal(c['result'])==Decimal(row['cost'])
                assert c['rounded']==(Decimal(c['result'])*b != a)
                assert json.loads(entry['calculation_inputs_json'])==c['originalInputs'] and entry['rounding_policy_version']=='1'
                rounded+=c['rounded']
            elif row.get('quantity') is not None and row.get('unitPrice') is not None and row.get('cost') is not None:
                assert Decimal(row['quantity'])*Decimal(row['unitPrice'])==Decimal(row['cost'])
            if row.get('cost') is not None and not row.get('excludedReason'):
                currency=row['currency'];assert re.fullmatch('[A-Z]{3}',currency)
                subtotals[currency]=subtotals.get(currency,Decimal(0))+Decimal(row['cost'])
        assert {k:Decimal(v) for k,v in bom['knownSubtotals'].items()}==subtotals
        if bom.get('completeTotal') is not None:
            assert not bom['unknowns'] and len(subtotals)==1 and Decimal(bom['completeTotal'])==subtotals[bom['currency']]
        else:
            assert bom.get('completeTotal') is None
    pdf=PdfReader(folder/'Review.pdf');assert 1<=len(pdf.pages)<=100
    for page in pdf.pages:
        assert page.get('/Rotate',0)==0
        assert abs(float(page.mediabox.width)*25.4/72-210)<.01 and abs(float(page.mediabox.height)*25.4/72-297)<.01
        assert (page.extract_text() or '').strip(), 'Blank review page.'
    if render:
        output=folder/'render';output.mkdir(exist_ok=True)
        subprocess.run(['pdftoppm','-r','90','-png',str(folder/'Review.pdf'),str(output/'page')],check=True,capture_output=True)
    independent=[];derived_reference_pages=0
    for job in source.get('embroideryJobs',[]):
        prefix=pathlib.Path('Processes')/job['id'];program=folder/prefix/'Program.original.json';old_revision=folder/prefix/'Revision.original.json'
        assert digest(program.read_bytes())==job['programDigest'] and digest(old_revision.read_bytes())==job['revisionDigest']
        needle=folder/prefix/'Needle.derived.dst';sidecar=folder/prefix/'Needle.derived.threads.json'
        if needle.exists():
            assert embroidery_python, 'Use --embroidery-python with the existing pinned validation reader.'
            meta=json.loads(sidecar.read_bytes());assert digest(needle.read_bytes())==meta['dst_sha256']
            command=[str(embroidery_python),str(pathlib.Path(__file__).with_name('verify_embroidery_dst.py')),str(needle),str(program),str(sidecar)]
            result=subprocess.run(command,check=True,capture_output=True,text=True);independent.append(json.loads(result.stdout))
            assert 'Derived once' in manifest['files'][str(prefix/'Needle.derived.dst')]['provenance']
        reference=folder/prefix/'Review.derived.pdf'
        if reference.exists():
            pages=PdfReader(reference).pages;design=json.loads(program.read_bytes())['design'];last=pages[-1]
            assert abs(float(last.mediabox.width)*25.4/72-(design['hoopWidth']+32))<.01
            assert abs(float(last.mediabox.height)*25.4/72-(design['hoopHeight']+32))<.01
            derived_reference_pages+=len(pages)
            if render:
                subprocess.run(['pdftoppm','-r','90','-png',str(reference),str(folder/'render'/('process-'+job['id']))],check=True,capture_output=True)
    physical_patterns=[]
    for allocation in plan.get('layouts',[]):
        owner=next(o for o in source['project']['objects'] if o['id']==allocation['objectID'])
        layout=owner['artwork']['sewingLayout'];base=folder/'Patterns'/allocation['runID']/layout['id']
        svg=ET.fromstring(base.with_suffix('.svg').read_bytes())
        metadata=next(x for x in svg if x.tag.endswith('metadata') and x.attrib.get('id')=='form-cutting-layout')
        measured=json.loads(metadata.text);pdf=PdfReader(base.with_suffix('.pdf'))
        assert len(pdf.pages)==1 and measured['valid'] and measured['include_fabric_preview'] is False
        assert abs(float(pdf.pages[0].mediabox.width)*25.4/72-measured['width_mm'])<.001
        assert abs(float(pdf.pages[0].mediabox.height)*25.4/72-measured['height_mm'])<.001
        assert float(svg.attrib['width'].removesuffix('mm'))==measured['width_mm']
        assert float(svg.attrib['height'].removesuffix('mm'))==measured['height_mm']
        if plan['name']=='Actual folded cutting packet':
            assert measured['width_mm']==100 and measured['height_mm']==30 and measured['stock_layers']==2
            assert len(measured['placements'])==1 and measured['placements'][0]['copies']==[1,2]
            assert Decimal(bom['completeTotal'])==Decimal('0.18')
            assert b'SOURCE ART MUST STAY ORIGINAL' not in base.with_suffix('.svg').read_bytes()
        if render:
            subprocess.run(['pdftoppm','-r','180','-png',str(base.with_suffix('.pdf')),str(folder/'render'/('cut-'+layout['id']))],check=True,capture_output=True)
        physical_patterns.append(dict(width_mm=measured['width_mm'],height_mm=measured['height_mm'],stock_layers=measured['stock_layers']))
    objects={o['id']:o for o in source['project']['objects']}
    if plan['name'].startswith('ORBITAL / Collection production'):
        assert len(objects)==15
        counts={}
        for run in plan['runs']:
            root=objects[run['objectID']];assert root['recipeID']!='artboard';counts[root['id']]=counts.get(root['id'],0)+run['quantity']
            if run['includeAttachments']:
                for child in objects.values():
                    if child.get('textile',{}).get('attachment',{}).get('garmentID')==root['id']:
                        assert child['id'] not in counts;counts[child['id']]=run['quantity']
        assert sum(counts.values())==110 and sum(o['quantity'] for o in bom['occurrences'])==110
        assert {o['objectID']:o['quantity'] for o in bom['occurrences']}==counts
        assert sum(o['quantity'] for o in bom['occurrences'] if o.get('parentID'))==80
        assert all(o.get('objectID') not in {x['id'] for x in objects.values() if x['recipeID']=='artboard'} for o in bom['occurrences'])
    return dict(folder=str(folder),files_verified=len(manifest['files']),bytes_verified=total,review_pages=len(pdf.pages),rounding_lines=rounded,
                currency_subtotals={k:str(v) for k,v in subtotals.items()},physical_occurrences=sum(o['quantity'] for o in bom['occurrences']),independent_dst=independent,physical_patterns=physical_patterns,derived_reference_pages=derived_reference_pages)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('proof',type=pathlib.Path);p.add_argument('--embroidery-python',type=pathlib.Path);p.add_argument('--render',action='store_true');a=p.parse_args()
    folders=[x.parent for x in a.proof.rglob('Manifest.json') if x.parent.name!='render']
    assert folders,'No captured packet manifests.'
    reports=[packet(x,a.embroidery_python,a.render) for x in sorted(folders)]
    archive=a.proof/'Collection.zip'
    if archive.exists():
        with zipfile.ZipFile(archive) as z:
            manifest=z.read('Collection/Manifest.json')
            matches=[folder for folder in folders if (folder/'Manifest.json').read_bytes()==manifest]
            assert matches, 'ZIP does not match any verified captured packet.'
            expected=matches[0];expected_manifest=json.loads(manifest)
            files=[x for x in z.namelist() if not x.endswith('/')]
            assert all(x.startswith('Collection/') and '__MACOSX' not in x and '/._' not in x for x in files)
            for name in files:
                safe_name(name);relative=name.removeprefix('Collection/');assert z.read(name)==(expected/relative).read_bytes()
            assert {x.removeprefix('Collection/') for x in files}==set(expected_manifest['files'])|{'Manifest.json'}
    managed=a.proof/'Managed';managed_report=None
    if managed.exists():
        source=json.loads((managed/'Source.json').read_bytes());bom=json.loads((managed/'BOM.json').read_bytes());plan=json.loads((managed/'Plan.json').read_bytes())
        block=source['garmentBlocks'][0];style=block['style'];body=block['body'];grade=block['grade']
        quantities=[];envelope=Decimal(0);bounds=[]
        for size in block['sizes']:
            step=Decimal(size['step']);waist=Decimal(str(body['waist']))+step*Decimal(str(grade['waist']))
            hip=Decimal(str(body['hip']))+step*Decimal(str(grade['hip']))
            stitch_width=(max(waist,hip)+Decimal(str(style['bodyEase'])))/2
            width=stitch_width+2*Decimal(str(style['sideAllowance']))
            height=Decimal(str(style['bodyLength']))+step*Decimal(str(grade['bodyLength']))+sum(Decimal(str(style[k])) for k in ('casingDepth','casingTurnUnder','hemAllowance'))
            elastic=waist+Decimal(str(style['elasticLoopAdjustment']))+Decimal(str(style['elasticOverlap']))
            refs=[r for r in block['bindings'] if r['sizeID']==size['id']];assert sorted(r['role'] for r in refs)==['back','elastic','front']
            for ref in refs:
                owner=next(o for o in source['objects'] if o['id']==ref['objectID']);element=next(e for e in owner['artwork']['elements'] if e['id']==ref['elementID'])
                if ref['role']=='elastic':
                    assert Decimal(str(element['width']))==elastic
                else:
                    assert Decimal(str(element['width']))==stitch_width and Decimal(str(element['height']))==height
                    assert Decimal(str(element['sewingPiece']['seamAllowance']))==Decimal(str(style['sideAllowance']))
                    envelope+=width*height/Decimal(1_000_000)
            quantities.append(elastic/1000);bounds.append([str(width),str(height)])
        assert quantities==[Decimal('0.725'),Decimal('0.765'),Decimal('0.805')] and sum(quantities)==Decimal('2.295')
        assert envelope==Decimal('2.45636') and [[Decimal(v) for v in pair] for pair in bounds]==[[Decimal(550),Decimal(708)],[Decimal(570),Decimal(718)],[Decimal(590),Decimal(728)]]
        assert sorted(Decimal(r['quantity']) for r in bom['rows'] if r['role']=='trim')==quantities
        assert len(bom['occurrences'])==len(plan['runs'])==3 and bom.get('completeTotal') is None
        managed_report=dict(sizes=3,panel_cut_envelope_area_m2=str(envelope),elastic_meters=str(sum(quantities)),envelope_bounds_mm=bounds,scope='Independent source declaration arithmetic; envelope area is separate from actual notched cut area and stock allocation.')
    output=dict(scope='Independent Decimal/CSV/SHA/ZIP/PDF boxes and pinned DST decoding; no FORM or device connection.',packets=reports,managed_addendum=managed_report,zip_verified=archive.exists())
    (a.proof/'independent-report.json').write_text(json.dumps(output,indent=2)+'\n');print(json.dumps(output,indent=2))


if __name__=='__main__':
    main()
