#!/usr/bin/env python3
"""Derive editable K-only technical illustrations from retained VARIOUS sources.

Offline project data only. Native PNGs, actual CAD/recipe/construction sources,
editorial body text and page counts are immutable. Nominal wireframes explicitly
omit hidden-line removal and small bevels; CAD profiles retain authored Beziers.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path

from author_various_visual_assets import uid,art,label,shape

TARGETS={'index_works_04','common_current_07','index_works_02','index_works_01','index_works_06',
 'matter_study_03','matter_study_04','matter_study_05','matter_study_06','matter_study_07','matter_study_08','fold_bureau_06'}


def digest(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
def number(value):
    if isinstance(value,(float,int)):return float(value)
    value=str(value)
    return float(value[:-6]) if value.endswith('*scale') else float(value)

def sampled_curves(operation):
    points=[]
    for curve in operation['curves']:
        p=lambda k:[number(curve[k][axis]) for axis in ('x','y')]
        start,end=p('start'),p('end')
        for i in range(25):
            t=i/24
            if curve['kind']=='line':point=[start[j]*(1-t)+end[j]*t for j in range(2)]
            else:
                a,b=p('control1'),p('control2')
                point=[start[j]*(1-t)**3+3*a[j]*(1-t)**2*t+3*b[j]*(1-t)*t*t+end[j]*t**3 for j in range(2)]
            if not points or point!=points[-1]:points.append(point)
    return points

def profile(definition,name):
    return next(f['operation'] for f in definition['features'] if f['name']==name)

def curve(definition,name):return sampled_curves(profile(definition,name))
def front(points):return [(x,-y) for x,y in points]
def circle(cx,cy,r,ry=None):return [(cx+r*math.cos(i*math.tau/96),cy+(r if ry is None else ry)*math.sin(i*math.tau/96)) for i in range(97)]


def project(point,azimuth=33,elevation=25):
    x,y,z=point;a,e=map(math.radians,(azimuth,elevation))
    return (math.cos(a)*x-math.sin(a)*z,math.sin(a)*math.sin(e)*x-math.cos(e)*y+math.cos(a)*math.sin(e)*z)

def rotate(point,angles):
    x,y,z=point
    for axis,angle in enumerate(angles):
        a=math.radians(angle);c,s=math.cos(a),math.sin(a)
        if axis==0:y,z=c*y-s*z,s*y+c*z
        elif axis==1:x,z=c*x+s*z,-s*x+c*z
        else:x,y=c*x-s*y,s*x+c*y
    return x,y,z

def recipe_wire(definition):
    lines=[]
    for part in definition['parts']:
        v={k:number(value) for k,value in part['values'].items()}
        center=[v.get(axis,0) for axis in 'xyz'];angles=[v.get('rotation'+axis,0) for axis in 'XYZ']
        def point(p):
            q=rotate(p,angles);return project([q[j]+center[j] for j in range(3)])
        kind=part['kind']
        if kind=='box':
            w,h,d=v['width']/2,v['height']/2,v['depth']/2
            corners=[(x,y,z) for x in (-w,w) for y in (-h,h) for z in (-d,d)]
            for i,p in enumerate(corners):
                for j,q in enumerate(corners):
                    if j>i and sum(a!=b for a,b in zip(p,q))==1:lines.append([point(p),point(q)])
        elif kind in ('cone','cylinder'):
            r0=v.get('radius',v.get('bottomRadius',0));r1=v.get('radius',v.get('topRadius',0));h=v['height']/2
            for r,y in ((r0,-h),(r1,h)):
                lines.append([point((r*math.cos(i*math.tau/96),y,r*math.sin(i*math.tau/96))) for i in range(97)])
            for a in (0,math.pi/2,math.pi,math.pi*1.5):lines.append([point((r0*math.cos(a),-h,r0*math.sin(a))),point((r1*math.cos(a),h,r1*math.sin(a)))])
        else:raise ValueError('Only the actual box/cone/cylinder recipe sources are needed by this bounded repair.')
    return lines


def fold_wire(source):
    points=source['points'];definition=source['source_definition'];lines=[];offset=0
    for panel in definition['panels']:
        count=len(panel['polygon']);ring=points[offset:offset+count*2];offset+=count*2
        for side in (0,1):
            face=ring[side::2];lines.append([project(p) for p in face+[face[0]]])
        for i in range(count):lines.append([project(ring[i*2]),project(ring[i*2+1])])
    if offset!=len(points):raise ValueError('Native folded corner buffers must match the actual declared panel ring count.')
    return lines


def cup_views(definition):
    outer=curve(definition,'Offset cup');inner=curve(definition,'Offset cavity')
    handle=curve(definition,'Handle outer');void=curve(definition,'Handle opening')
    xmin,xmax=min(p[0] for p in outer),max(p[0] for p in outer)
    zmin,zmax=min(p[1] for p in outer),max(p[1] for p in outer)
    h=number(profile(definition,'Cup body')['values']['distance'])
    handle_depth=number(profile(definition,'Handle body')['values']['distance'])
    # These are explicit construction/elevation lines, including the handle's
    # joined envelope. Interior coincident edges are retained as a wire drawing.
    elevation=[[(xmin,0),(xmax,0),(xmax,-h),(xmin,-h),(xmin,0)],front(handle),front(void)]
    top=[outer,inner,[(min(p[0] for p in handle),0),(max(p[0] for p in handle),0),(max(p[0] for p in handle),handle_depth),(min(p[0] for p in handle),handle_depth),(min(p[0] for p in handle),0)]]
    side=[[(zmin,0),(zmax,0),(zmax,-h),(zmin,-h),(zmin,0)]]
    return elevation,side,top


def clay_lines(key,definition):
    if key in ('matter_study_03','matter_study_07'):
        operation=profile(definition,'Bowl wall section')
        # Joining the two half-sections removes the artificial seam on the
        # rotation axis; the six-mm floor remains one continuous material band.
        side=sampled_curves(dict(curves=operation['curves'][:3]))
        section=side+[[-x,y] for x,y in reversed(side)]+[side[0]]
        return [front(section)],'DIAMETRAL SECTION'
    if key=='matter_study_04':
        return [front(curve(definition,name)) for name in ('Handle field outer','Handle field opening','Finger aperture 0','Finger aperture 1')],'FRONT ELEVATION'
    if key in ('matter_study_05','matter_study_08'):
        elevation,side,top=cup_views(definition)
        if key=='matter_study_05':
            # A plan inset shows the actual off-center cavity rather than a
            # generic concentric oval; front view retains the literal handle.
            inset=[[(x*.55+85,y*.55-13) for x,y in line] for line in top]
            return elevation+inset,'FRONT / OFFSET PLAN'
        lines=[]
        for i,view in enumerate((elevation,side,top)):
            lo=min(p[0] for line in view for p in line);hi=max(p[0] for line in view for p in line)
            center=(lo+hi)/2
            lines += [[((x-center)+i*130,y) for x,y in line] for line in view]
        return lines,'FRONT / SIDE / PLAN — SAME SCALE'
    if key=='matter_study_06':
        outer=curve(definition,'Window outer');inner=curve(definition,'Window opening')
        # Exact top-limb section atx=0: outer top128, opening top107,30mm extrusion.
        ymax=max(p[1] for p in outer);low=max(p[1] for p in inner)
        depth=number(profile(definition,'Window body')['values']['distance'])
        context=[[(x*.32-32,(ymax-y)*.32) for x,y in ring] for ring in (outer,inner)]
        thickness=ymax-low
        section=[(0,0),(depth,0),(depth,thickness),(0,thickness),(0,0)]
        leader=[(-32,thickness*.16),(-12,thickness*.16),(-2,thickness/2),(0,thickness/2)]
        return context+[section,leader],'WINDOW REFERENCE / TOP LIMB SECTION'
    raise ValueError('Unexpected bounded CAD alternative '+key)


def artwork_from_lines(key,lines,note):
    height=28 if key=='matter_study_08' else 100
    points=[p for line in lines for p in line]
    low=[min(p[i] for p in points) for i in range(2)];high=[max(p[i] for p in points) for i in range(2)]
    scale=min(84/max(1e-9,high[0]-low[0]),(20 if height==28 else 78)/max(1e-9,high[1]-low[1]))
    tx=(100-(high[0]-low[0])*scale)/2-low[0]*scale
    ty=((24 if height==28 else 92)-(high[1]-low[1])*scale)/2-low[1]*scale
    elements=[]
    for i,line in enumerate(lines):
        nodes=[dict(id=uid(key+'/node/'+str(i)+'/'+str(j)),anchor=dict(x=x*scale+tx,y=y*scale+ty)) for j,(x,y) in enumerate(line)]
        elements.append(shape('path',key+'/projection/'+str(i),0,0,100,height,'#000000',fillEnabled=False,
            stroke=dict(color='#000000',width=.45,cap='round',join='round'),
            path=dict(width=100,height=height,evenOdd=False,contours=[dict(closed=False,nodes=nodes)])))
    # Actual native compositor proof found these two long uppercase labels
    # wrap at12pt in90mm; retain their words/frame and use the proved10pt fit.
    note_size=10 if note in ('PARAMETER WIREFRAME / BEVELS OMITTED','WINDOW REFERENCE / TOP LIMB SECTION') else (8 if height==28 else 12)
    elements.append(label(key+'/projection-note',note,8,height-6,90,6,note_size,'#000000'))
    result=art(elements)
    result['source_size_mm']=dict(x=100,y=height)
    return result


def refine(original_path,semantic_path,authoring_path,output):
    original_path=Path(original_path).resolve();semantic_path=Path(semantic_path).resolve();output=Path(output).resolve()
    original=json.loads(original_path.read_text());semantic=json.loads(semantic_path.read_text());report=json.loads(Path(authoring_path).read_text())
    revised=copy.deepcopy(semantic);drawings={}
    for key in sorted(TARGETS):
        entry=revised['originals'][key];source_key=entry.get('source_work') or key
        source=report['sources'][source_key];definition=source['source_definition']
        if entry['family']=='clay':lines,note=clay_lines(key,definition)
        elif entry['family']=='fold':lines,note=fold_wire(source),'NATIVE FOLDED STOCK / NOMINAL EDGES'
        else:lines,note=recipe_wire(definition),'PARAMETER WIREFRAME / BEVELS OMITTED'
        drawing=artwork_from_lines(key,lines,note)
        proof=dict(kind='source_derived_technical_drawing',source_model_key=source_key,source_object_id=source['object_id'],
            source_definition_sha256=digest(definition),projection=note,
            qualification='Editable line construction from retained source parameters or actual native resolved corners; no hidden-line removal. Small bevels are omitted in nominal wireframes.')
        entry['black_only_artwork']=drawing;entry['black_only_artwork_provenance']=proof;drawings[key]=dict(artwork=drawing,provenance=proof)
    for key,entry in revised['assets'].items():
        selected=entry.get('reuse_of',key)
        if selected in drawings:
            entry['black_only_artwork']=copy.deepcopy(drawings[selected]['artwork'])
            entry['black_only_artwork_provenance']=copy.deepcopy(drawings[selected]['provenance'])
    # Only derived alternative artwork/provenance changes. The actual native
    # images, original project objects and modeling source definitions are exact.
    for key,entry in revised['originals'].items():
        before=semantic['originals'][key]
        assert {k:v for k,v in entry.items() if k not in ('black_only_artwork','black_only_artwork_provenance')}=={k:v for k,v in before.items() if k not in ('black_only_artwork','black_only_artwork_provenance')}
        if entry['kind']=='raster':assert hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest()==entry['sha256']
    patches={}
    for key,entry in revised['assets'].items():
        before=original['assets'][key]
        if digest(entry)!=digest(before):
            patches[key]=dict(prior_entry_sha256=digest(before),original_asset_key=entry.get('reuse_of',key),entry=entry,
                reason='Curated caption subject and/or source-derived K-only technical illustration.')
    output.mkdir(parents=True,exist_ok=True)
    final=output/'visual-assets-semantic-v3.json';patchfile=output/'semantic-alias-patch-v3.json'
    assert not final.exists() and not patchfile.exists(),'Retain previous evidence; choose a fresh revision folder.'
    revised.update(semantic_revision=3,revises_manifest_sha256=hashlib.sha256(original_path.read_bytes()).hexdigest(),source_derived_k_alternatives=len(drawings))
    final.write_text(json.dumps(revised,indent=2)+'\n')
    patch=dict(version=1,source_manifest_path=str(original_path),source_manifest_sha256=hashlib.sha256(original_path.read_bytes()).hexdigest(),
        revised_manifest_path=str(final),revised_manifest_sha256=hashlib.sha256(final.read_bytes()).hexdigest(),patches=patches,
        changed_placements=len(patches),source_derived_k_originals=sorted(drawings),original_native_pngs_unchanged=True,
        caption_revision=dict(key='room_accident_04',old='One continuous image crosses two page crops.',new='A folded view returns within a single page.',reason='This slot is a single-page view, not an additional cross-gutter hero.'))
    patchfile.write_text(json.dumps(patch,indent=2)+'\n')
    (output/'technical-drawings.json').write_text(json.dumps(drawings,indent=2)+'\n')
    return dict(manifest=str(final),patch=str(patchfile),changed_placements=len(patches),technical_originals=len(drawings))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--original-manifest',type=Path,required=True);p.add_argument('--semantic-manifest',type=Path,required=True)
    p.add_argument('--authoring-report',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();print(json.dumps(refine(a.original_manifest,a.semantic_manifest,a.authoring_report,a.output),indent=2))


if __name__=='__main__':main()
