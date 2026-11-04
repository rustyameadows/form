#!/usr/bin/env python3
"""Project-authored advanced book studies. Importing this file performs no I/O.

The caller owns the ordinary LAB app and passes call(tool_name, arguments).
Every authoring action uses public MCP. This module contains example data, not
application recipes. It never launches LAB, reads its private repository, exports,
prints, generates images, or changes the current project. Return values identify
canonical sources and physical objects for the caller's subsequent native QA.
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Callable, TextIO
import uuid

Call = Callable[[str, dict[str, Any]], Any]
NS = uuid.UUID('268543db-495e-4df3-a824-fc57ce5cd15b')
TRIM = (140.0, 210.0)
NAMES = {'hardcover': 'The useful interval', 'softcover': 'Notes on ordinary light'}
PALE_YELLOW = '#F3E6A4'
WHITE = '#F7F5EF'
INK = '#1B302D'
GOLD = '#C4A66B'
ARTWORK_KINDS = frozenset(('text','rectangle','ellipse','image','line','polygon','star','path','group'))


def uid(key: str) -> str:
    return str(uuid.uuid5(NS, key)).upper()


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False).encode()).hexdigest()


def artwork_translation_invariants(art: dict) -> dict:
    """Content, style, geometry and topology with only element placement omitted.

    Path points, image crops, sizes, parent/clip IDs and printed text remain in
    the comparison. Region anchors may legitimately translate element x/y.
    """
    value=copy.deepcopy(art)
    for item in value.get('elements',[]):
        item.pop('x',None);item.pop('y',None)
    return value


def verify_artwork_translation(before: dict, after: dict) -> dict:
    old,new=artwork_translation_invariants(before),artwork_translation_invariants(after)
    if old!=new:
        raise ValueError('Source content, style, geometry or topology changed beyond allowed anchor translation.')
    by_id={item['id']:item for item in before.get('elements',[])}
    moved=[]
    for item in after.get('elements',[]):
        previous=by_id[item['id']]
        dx=item.get('x',0)-previous.get('x',0);dy=item.get('y',0)-previous.get('y',0)
        if not math.isfinite(dx) or not math.isfinite(dy):raise ValueError('Source translation must remain finite.')
        if dx or dy:moved.append(dict(id=item['id'],dx=dx,dy=dy))
    return dict(before_artwork_sha256=digest(before),after_artwork_sha256=digest(after),
                content_style_topology_sha256=digest(old),translated_elements=moved)


def validate_expression_limits(value: Any, path: str = 'request') -> None:
    """Bound actual emitted scalar fields to the public CAD-expression limit."""
    scalar_fields={'x','y','z','width','height','depth','expression','stockThickness',
                   'turnInMM','cornerRadiusMM','widthMM','angleDegrees','depthMM','lhs','rhs'}
    if isinstance(value,dict):
        for key,child in value.items():
            if key in scalar_fields and isinstance(child,str) and len(child.encode('utf-8'))>256:
                raise ValueError(f'{path}.{key} exceeds the native256-byte CAD expression budget.')
            validate_expression_limits(child,path+'.'+key)
    elif isinstance(value,list):
        for index,child in enumerate(value):validate_expression_limits(child,path+f'[{index}]')


def point(x: Any, y: Any) -> dict:
    return {'x': x, 'y': y}


def vector(x: Any = 0, y: Any = 0, z: Any = 0) -> dict:
    return {'x': x, 'y': y, 'z': z}


def stock(name: str, thickness: float, color: str = WHITE, texture: str = 'cotton',
          gsm: float = 120) -> dict:
    return dict(name=name, thicknessMM=thickness, grain='parallelHeight', gsm=gsm,
                verified=False, notes='Project-authored visual specification; physical stock/bindery proof remains unverified.',
                profile=dict(texture=texture, color=color, roughness=.82 if texture=='linen' else .92,
                             textureScaleMM=.75 if texture=='linen' else .65, textureDepthMM=.04 if texture=='linen' else .009, opacity=1))


def element(key: str, kind: str, x: float, y: float, width: float, height: float,
            text: str = '', color: str = INK, size: float = 10, **extra: Any) -> dict:
    if kind not in ARTWORK_KINDS:
        raise ValueError(f'Unsupported public Artwork kind: {kind!r}. Use canonical MCP kind names.')
    value = dict(id=uid(key), name=key.rsplit('/', 1)[-1], kind=kind, x=x, y=y,
                 width=width, height=height, text=text, color=color, fontSize=size)
    if kind == 'text':
        value['typography'] = dict(fontName='HelveticaNeue', leading=round(size*1.35, 5))
    value.update(extra)
    return value


def artwork(elements: list[dict], *, bleed: float = 0) -> dict:
    # The substrate belongs to physical stock. Transparent white is not white ink.
    return dict(background='#FFFFFF', backgroundOpacity=0, bleed=bleed,
                elements=elements, unit='mm')


def parameter(key: str, title: str, value: float, low: float, high: float,
              step: float = .1) -> dict:
    return dict(id=key, name=title, value=float(value), minimum=float(low),
                maximum=float(high), step=step, unit='mm')


def control_values(kind: str) -> dict[str, float]:
    if kind not in NAMES:
        raise ValueError('Use hardcover or softcover.')
    hard = kind == 'hardcover'
    values = dict(boardMM=2.4 if hard else .32,wrapMM=.12 if hard else 0,
                overhangMM=3 if hard else 0, jointMM=10 if hard else 7, clearanceMM=2 if hard else 0,
                turnInMM=14 if hard else 0, flapMM=0 if hard else 55,
                spineBoardMM=.35 if hard else .32,
                insetWidthMM=84, insetHeightMM=110, insetDepthMM=.65)
    if hard:
        values.pop('flapMM')
    else:
        for key in ('turnInMM','spineBoardMM','insetWidthMM','insetHeightMM','insetDepthMM','jointMM','clearanceMM','wrapMM'):
            values.pop(key)
    return values


def study_spec(kind: str, *, page_count: int | None = None, name: str | None = None,
               identity_seed: str | None = None, trim_mm: tuple[float,float] = TRIM) -> dict:
    default_count=128 if kind=='hardcover' else 96
    control_values(kind)  # Validate the supported authored construction family.
    count=default_count if page_count is None else page_count
    if isinstance(count,bool) or not isinstance(count,int) or count<16 or count>192 or count%16:
        raise ValueError('Authored studies need 16–192 pages in complete 16-page gathers.')
    if len(trim_mm)!=2 or any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) for v in trim_mm):
        raise ValueError('Trim needs two finite millimeter dimensions.')
    trim=tuple(float(v) for v in trim_mm)
    if not (140<=trim[0]<=400 and 210<=trim[1]<=500):
        raise ValueError('These authored layouts support trim widths140–400 and heights210–500 mm without shrinking source typography.')
    if identity_seed is not None and (not isinstance(identity_seed,str) or not identity_seed.strip() or len(identity_seed)>128):
        raise ValueError('Use a nonempty identity seed of at most128 characters.')
    custom=count!=default_count or trim!=TRIM or name is not None or identity_seed is not None
    seed=identity_seed or (digest(dict(kind=kind,count=count,trim=trim,name=name))[:16] if custom else None)
    display=name or (NAMES[kind]+f' / {count} pages / '+digest(seed)[:6] if custom else NAMES[kind])
    if not isinstance(display,str) or not display.strip() or len(display)>60:
        raise ValueError('Use a study name of1–60 characters, retaining comfortable printed source capacity.')
    return dict(kind=kind,page_count=count,name=display,identity_seed=seed,trim_mm=trim)


def identity_suffix(seed: str | None) -> str:
    return '_'+digest(seed)[:8] if seed is not None else ''


def artwork_key(project_id: str,kind: str,seed: str | None) -> str:
    return project_id+'/'+kind+('/study/'+seed if seed is not None else '')


def control_recipe(project_id: str, kind: str, *, identity_seed: str | None = None, name: str | None = None,
                   controls: dict[str,float] | None = None) -> dict:
    p = dict(control_values(kind) if controls is None else controls)
    labels = dict(boardMM='Cover core caliper',wrapMM='Wrapping material caliper',
                  overhangMM='Cover overhang', jointMM='Flexible bridge joint length', clearanceMM='Board hinge clearance',
                  turnInMM='Wrap turn-in', flapMM='Cover flap width',
                  spineBoardMM='Reinforced spine and hinge caliper', insetWidthMM='Inset width',
                  insetHeightMM='Inset height', insetDepthMM='Inset recess depth')
    ranges = dict(boardMM=(.2, 4),wrapMM=(.03, .3), overhangMM=(0, 8),
                  jointMM=(6, 16), clearanceMM=(1.5, 4), turnInMM=(0, 24), flapMM=(0, 70),
                  spineBoardMM=(.2, .5), insetWidthMM=(50, 105),
                  insetHeightMM=(60, 125), insetDepthMM=(.1, 1.2))
    return dict(id='study_'+uuid.UUID(project_id).hex[:10]+'_'+kind+identity_suffix(identity_seed),
                name=(name or NAMES[kind])+' / construction controls', symbol='book.closed',
                summary='Editable project-authored dimensions; artwork is a canonical consumer, never generated app code.',
                parameters=[parameter(k, labels[k], v, *ranges[k]) for k, v in p.items()], parts=[],
                requirements=[dict(id='recess-floor', lhs='boardMM-insetDepthMM', relation='>=', rhs=.2,
                                   message='Keep a positive cover core below the stepped inset.')]
                if kind == 'hardcover' else [])


def signature_plan(document: dict, kind: str, *, page_count: int | None = None, trim_mm: tuple[float,float] = TRIM) -> dict:
    """Independently nested 16-page gathers; parent IDs own stock exactly once."""
    expected = page_count if page_count is not None else (128 if kind == 'hardcover' else 96)
    pages = document['pages']
    if len(pages) != expected:
        raise ValueError(f'{kind} requires exactly {expected} canonical logical pages.')
    white = stock('White uncoated body / 100 gsm', .10 if kind == 'hardcover' else .095, gsm=100)
    colored = stock('Pale mineral body / 110 gsm', .115 if kind == 'hardcover' else .11,
                    '#D9E0C8' if kind == 'hardcover' else '#D8E5E9', gsm=110)
    parents, signatures, evidence = [], [], []
    for gather, start in enumerate(range(0, expected, 16)):
        entries = pages[start:start+16]
        parent_ids = []
        for layer in range(4):
            numbers = [15-2*layer, 2*layer, 2*layer+1, 14-2*layer]
            ids = [entries[n]['id'] for n in numbers]
            identifier = uid(document['id']+f'/gather/{gather}/parent/{layer}')
            value = dict(id=identifier, frontPageIDs=ids[:2], backPageIDs=ids[2:],
                         stock=copy.deepcopy(colored if layer == 1 else white),
                         sizeMM=point(trim_mm[0]*2, trim_mm[1]), printIntent='color')
            parents.append(value); parent_ids.append(identifier)
            evidence.append(dict(id=identifier, gather=gather+1,
                                 logical_pages=[start+n+1 for n in numbers],
                                 stock_name=value['stock']['name']))
        signatures.append(dict(id=uid(document['id']+f'/gather/{gather}'), parentSheetIDs=parent_ids))
    actual = [entry for parent in parents for entry in parent['frontPageIDs']+parent['backPageIDs']]
    if len(actual) != len(set(actual)) or set(actual) != {page['id'] for page in pages}:
        raise AssertionError('Every canonical page must appear exactly once in the physical gather plan.')
    body_thickness = 2*sum(parent['stock']['thicknessMM'] for parent in parents)
    return dict(parent_sheets=parents, signatures=signatures, white_stock=white,
                text_block_thickness_mm=body_thickness, evidence=evidence)


def binding(kind: str) -> dict:
    return dict(style='sewn' if kind == 'hardcover' else 'adhesive', count=3,
                endMarginMM=35, edgeInsetMM=7, crownLengthMM=10, wireDiameterMM=.35,
                clinchLengthMM=2, flexWidthMM=8,
                adhesiveMM=.22 if kind == 'hardcover' else .45,
                sewingSwellMM=.8 if kind == 'hardcover' else 0)


def dimensions(kind: str, body_mm: float, controls: dict | None = None, *, trim_mm: tuple[float,float] = TRIM) -> dict[str, float]:
    p = controls or control_values(kind)
    hard = kind == 'hardcover'
    aux = .64 if hard else .24
    allowance = binding(kind)['adhesiveMM']+binding(kind)['sewingSwellMM']
    stack = body_mm+aux
    panel_w = trim_mm[0]-binding(kind)['flexWidthMM']+p['overhangMM']-p['clearanceMM'] if hard else trim_mm[0]+p['overhangMM']
    panel_h = trim_mm[1]+2*p['overhangMM']
    spine_w = stack+allowance+2*(p['boardMM']+(p['wrapMM'] if hard else 0))
    margin = max(p['boardMM'],p['spineBoardMM'])+p['turnInMM'] if hard else 0
    joint = p['jointMM'] if hard else 0
    flap = 0 if hard else p['flapMM']
    return dict(width=2*margin+2*panel_w+spine_w+2*joint+2*flap,
                depth=2*margin+panel_h, panelWidth=panel_w, panelHeight=panel_h,
                spineWidth=spine_w, margin=margin, jointWidth=joint, flapWidth=flap,
                stack=stack, allowance=allowance, body=body_mm)


def face(source: str, x: Any = 0, y: Any = 0) -> dict:
    return dict(sourceObjectID=source, sourceSide='outside', sourceOriginMM=point(x, y))


def source_recipe(project_id: str, kind: str, role: str, values: dict[str, float], *, identity_seed: str | None = None, name: str | None = None) -> dict:
    return dict(id='source_'+uuid.UUID(project_id).hex[:10]+'_'+kind+'_'+role+identity_suffix(identity_seed),
                name=(name or NAMES[kind])+' / '+role+' source', symbol='rectangle',
                summary='Single canonical editable artwork with millimeter registration and saved construction dependencies.',
                parameters=[parameter(k, k, value, 0 if k in ('margin','jointWidth','flapWidth') else .01,
                                      2000 if k in ('width','depth') else 1000)
                            for k, value in values.items()], parts=[])


def source_bindings(book_id: str, kind: str) -> list[dict]:
    def ref(measurement: str, parameter_name: str | None = None) -> dict:
        value = dict(sourceObjectID=book_id, measurement=measurement)
        if parameter_name is not None:
            value['parameter'] = parameter_name
        return value
    refs = dict(tw=ref('trimWidth'), th=ref('trimHeight'), s=ref('spineThickness'),
                bc=ref('parameter','boardMM'),ov=ref('parameter','overhangMM'))
    if kind == 'hardcover':
        refs.update(wc=ref('parameter','wrapMM'),j=ref('parameter','jointMM'),ti=ref('parameter','turnInMM'),sb=ref('parameter','spineBoardMM'),cl=ref('parameter','clearanceMM'),hinge=ref('bindingFlexWidth'))
    else:
        refs['f']=ref('parameter','flapMM')
    hard = kind == 'hardcover'
    expressions = dict(panelWidth='tw-hinge+ov-cl' if hard else 'tw+ov', panelHeight='th+2*ov',
                       spineWidth='s+2*(bc+wc)' if hard else 's+2*bc', margin='max(bc,sb)+ti' if hard else '0',
                       jointWidth='j' if hard else '0', flapWidth='0' if hard else 'f')
    expressions['width'] = ('2*(max(bc,sb)+ti)+2*(tw-hinge+ov-cl)+s+2*(bc+wc)+2*j' if hard
                            else '2*(tw+ov)+s+2*bc+2*f')
    expressions['depth'] = '2*(max(bc,sb)+ti)+th+2*ov' if hard else 'th+2*ov'
    return [dict(parameter=key, expression=value, inputs=copy.deepcopy(refs))
            for key, value in expressions.items()]


def cover_art(project_id: str, kind: str, size: dict, *, identity_seed: str | None = None, name: str | None = None) -> tuple[dict, list[dict], dict]:
    m, pw, ph, sw, joint, flap = (size[k] for k in ('margin','panelWidth','panelHeight','spineWidth','jointWidth','flapWidth'))
    back_x = m+flap
    spine_x = back_x+pw+joint
    front_x = spine_x+sw+joint
    key = artwork_key(project_id,kind,identity_seed)+'/cover'
    values = [element(key+'/back-heading','text',back_x+17,m+28,pw-34,30,
                      'A field for\ncareful looking.',size=22),
              element(key+'/back-copy','text',back_x+17,m+78,pw-34,60,
                      'A small collection of observations about paper, light and the useful space between things. '
                      'Original studies authored in LAB. Every page and every cover region remains editable.',size=10),
              element(key+'/back-colophon','text',back_x+17,m+ph-28,pw-34,12,
                      'ORIGINAL LAB STUDIES / FIRST EDITION\nVISUAL MATERIAL SPECIFICATIONS',size=7.5),
              element(key+'/front-series','text',front_x+17,m+18,pw-34,10,
                      'FIELD STUDIES / VOLUME 01' if kind=='hardcover' else 'FIELD STUDIES / VOLUME 02',size=8),
              element(key+'/front-title','text',front_x+17,m+37,pw-34,35,
                      'The useful\ninterval' if kind=='hardcover' else 'Notes on\nordinary light',
                      color=GOLD if kind=='hardcover' else '#233C49',size=27 if kind=='hardcover' else 25),
              element(key+'/front-footer','text',front_x+17,m+ph-23,pw-34,9,
                      'MATERIAL / OBSERVATION / EDITABLE SOURCE',size=7),
              element(key+'/blind-mark','ellipse',front_x+((pw+84)/2+1 if kind=='hardcover' else pw-31),m+ph-46,12,12,color='#58705F'),
              element(key+'/spine-title','text',spine_x+sw/2-77,m+ph/2-3,154,6,
                      (name or NAMES[kind]).upper()+' / FIELD STUDIES',size=7.5,rotation=90)]
    if kind == 'softcover':
        values += [element(key+'/front-diagram','ellipse',front_x+28,m+101,84,69,color='#D4B468'),
                   element(key+'/front-band','rectangle',front_x+28,m+132,84,8,color='#D8E5E9'),
                   element(key+'/back-flap','text',m+9,m+30,max(15,flap-18),100,
                           'Keep a record.\nMake another.\n\nAn editable edition built from ordinary paper and a continuous cover.',size=9),
                   element(key+'/front-flap','text',front_x+pw+9,m+30,max(15,flap-18),100,
                           'THE SOURCE\n\nOriginal LAB-authored studies. Material colors are stocks; this text is ink.',size=9)]
    if kind == 'hardcover':
        for item in values:
            if item['kind']=='text' and item['name'].startswith('back-'):
                item['color']='#E8E3CA'
    by_name = {item['name']:item['id'] for item in values}
    def anchor(names:list[str],horizontal:float,vertical:float)->dict:
        return dict(elementIDs=[by_name[n] for n in names],horizontal=horizontal,vertical=vertical)
    regions = [dict(id='back',name='Back cover',origin=point('margin+flapWidth','margin'),size=point('panelWidth','panelHeight'),
                    anchors=[anchor(['back-heading','back-copy'],0,0),anchor(['back-colophon'],0,1)]),
               dict(id='spine',name='Spine',origin=point('margin+flapWidth+panelWidth+jointWidth','margin'),size=point('spineWidth','panelHeight'),
                    anchors=[anchor(['spine-title'],.5,.5)]),
               dict(id='front',name='Front cover',origin=point('margin+flapWidth+panelWidth+2*jointWidth+spineWidth','margin'),size=point('panelWidth','panelHeight'),
                    anchors=[anchor(['front-series','front-title'],0,0),anchor(['front-footer'],0,1),anchor(['blind-mark'],.5,1)]+
                            ([anchor(['front-diagram','front-band'],.5,.5)] if kind=='softcover' else []))]
    if kind == 'hardcover':
        regions += [dict(id='back-joint',name='Back joint',origin=point('margin+panelWidth','margin'),size=point('jointWidth','panelHeight')),
                    dict(id='front-joint',name='Front joint',origin=point('margin+panelWidth+jointWidth+spineWidth','margin'),size=point('jointWidth','panelHeight'))]
    else:
        for side, origin in [('back','margin'),('front','margin+flapWidth+2*panelWidth+spineWidth')]:
            regions.append(dict(id=side+'-flap',name=side.title()+' flap',origin=point(origin,'margin'),size=point('max(flapWidth,0.01)','panelHeight'),
                                anchors=[dict(elementIDs=[by_name[side+'-flap']],horizontal=0,vertical=0)]))
    return artwork(values), regions, by_name


def finish(key: str, kind: str, element_ids: list[str], *, height: float = 0, depth: float = 0) -> dict:
    value = dict(id=uid(key), name=key.rsplit('/',1)[-1], kind=kind, side='outside', elementIDs=element_ids,
                 depthMM=depth, heightMM=height, opacity=1, enabled=True)
    if kind == 'foil':
        value.update(color=GOLD, metallic=1, roughness=.12)
    return value


def cover_derived(kind: str) -> dict[str,str]:
    if kind!='hardcover':
        return dict(softTheta='openingDegrees*pi/180',softAngle='max(softTheta,.000001)',
            softHX='bindingFlexWidth*sin(softAngle)/softAngle',softHY='bindingFlexWidth*(1-cos(softAngle))/softAngle',
            softBase='stackThickness*(1+cos(softTheta))/2',softNormal='bindingAllowance+boardMM/2',
            softX='-softNormal*sin(softTheta)',softY='softBase+softNormal*cos(softTheta)',
            softForeX='softX+softHX+(width+overhangMM-bindingFlexWidth)*cos(softTheta)',
            softForeY='softY+softHY+(width+overhangMM-bindingFlexWidth)*sin(softTheta)')
    return dict(caseTheta='openingDegrees*pi/180',caseAngle='max(caseTheta,.000001)',
        caseHX='bindingFlexWidth*sin(caseAngle)/caseAngle',caseHY='bindingFlexWidth*(1-cos(caseAngle))/caseAngle',
        caseBase='stackThickness*(1+cos(caseTheta))/2',caseNormal='boardMM/2+wrapMM',
        caseFrontX='caseHX+clearanceMM*cos(caseTheta)-caseNormal*sin(caseTheta)',
        caseFrontY='caseBase+caseHY+clearanceMM*sin(caseTheta)+caseNormal*cos(caseTheta)',
        caseBackX='bindingFlexWidth+clearanceMM',caseBackY='-boardMM-wrapMM',
        caseWrapX='caseFrontX-caseNormal*sin(caseTheta)',caseWrapY='caseFrontY+caseNormal*cos(caseTheta)',
        caseDX='caseWrapX-caseBackX',caseDY='caseWrapY-caseBackY',
        caseSpineLength='spineThickness+2*(boardMM+wrapMM)',caseBridgeLength='2*jointMM+caseSpineLength',
        casePanelWidth='width-bindingFlexWidth+overhangMM-clearanceMM',casePanelHeight='height+2*overhangMM',
        caseMargin='max(boardMM,spineBoardMM)+turnInMM')


def cover_planes(kind: str, source: str, names: dict, inset_source: str | None = None) -> list[dict]:
    """Source crops stay flat; rigid poses/finite material hinge follow opening."""
    hard = kind == 'hardcover'
    pw, ph = 'width+overhangMM', 'height+2*overhangMM'
    sw = 'spineThickness+2*(boardMM+0.12)' if hard else 'spineThickness+2*boardMM'
    m = 'max(boardMM,spineBoardMM)+turnInMM' if hard else '0'
    back_x = m if hard else 'flapMM'
    spine_x = f'({back_x})+({pw})'+('+jointMM' if hard else '')
    front_x = f'({spine_x})+({sw})'+('+jointMM' if hard else '')
    paper = stock('Flexible coated cover / 280 gsm', .32, '#E6D8B7', 'coated', 280)
    core = stock('Conservation board / 2.4 mm', 2.4, '#ADA68D', 'recycled', 1400)
    wrap_stock = stock('Dyed linen wrapping / 0.12 mm', .12, '#385949', 'linen', 150)
    theta = 'openingDegrees*pi/180'
    a = 'max(openingDegrees*pi/180,0.000001)'
    hx, hy = f'jointMM*sin({a})/({a})', f'jointMM*(1-cos({a}))/({a})'
    if hard:
        pw='casePanelWidth';ph='casePanelHeight';m='caseMargin'
        back_x=m;front_x='caseMargin+casePanelWidth+caseBridgeLength'
        front_features=dict(stockThickness='boardMM',wrap=dict(stock=wrap_stock,turnInMM='turnInMM',cornerRadiusMM=1.2,stockThickness='wrapMM'))
        if inset_source:
            front_features['recesses']=[dict(id='inset-seat',origin=point('(casePanelWidth-insetWidthMM)/2','height*.34'),
                size=point('insetWidthMM','insetHeightMM'),depthMM='insetDepthMM',cornerRadiusMM=1.5,
                insert=dict(stock=stock('Inserted photographic paper /0.24 mm',.24,WHITE,'coated',240),face=face(inset_source)))]
        front=dict(id='front-board',name='Wrapped front board',size=point(pw,ph),
            positionMM=vector('caseFrontX','caseFrontY','-casePanelHeight/2'),rotationDegrees=vector(-90,0,'openingDegrees'),
            stock=core,front=face(source,front_x,m),features=front_features,
            finishes=[finish(source+'/front-foil','foil',[names['front-series'],names['front-title']],height=.01,depth=.025),
                      finish(source+'/front-blind','emboss',[names['blind-mark']],height=.12)])
        back=dict(id='back-board',name='Wrapped back board',size=point(pw,ph),
            positionMM=vector('width+overhangMM','-boardMM/2','-casePanelHeight/2'),rotationDegrees=vector(-90,0,180),
            stock=core,front=face(source,back_x,m),features=dict(stockThickness='boardMM',wrap=dict(stock=wrap_stock,turnInMM='turnInMM',cornerRadiusMM=1.2,stockThickness='wrapMM')),
            finishes=[finish(source+'/back-letterpress','letterpress',[names['back-heading']],depth=.06)])
        reinforced=stock('Reinforced linen and paper hollowback /0.35 mm',.35,'#385949','linen',220)
        reinforced['plies']=[dict(id=uid(source+'/bridge-backing'),name='Flexible paper backing',color='#D8D1BB',thicknessMM=.23,profile=stock('Paper backing',.23,'#D8D1BB','cotton')['profile']),
                             dict(id=uid(source+'/bridge-cloth'),name='Dyed linen face',color='#385949',thicknessMM=.12,profile=copy.deepcopy(wrap_stock['profile']))]
        bridge=dict(id='hollowback-bridge',name='Continuous flexible hollowback and joints',size=point('caseBridgeLength',ph),
            positionMM=vector('caseBackX','caseBackY','-casePanelHeight/2'),rotationDegrees=vector(-90,0,0),stock=reinforced,
            front=face(source,'caseMargin+casePanelWidth',m),
            features=dict(stockThickness='spineBoardMM',flex=dict(edge='left',widthMM='caseBridgeLength',angleDegrees=0,
                curve=dict(points=[point(0,0),point(-1,0),point(-1,'caseDY'),point('caseDX','caseDY')],fitLength=True))),
            finishes=[finish(source+'/spine-foil','foil',[names['spine-title']],height=.01)])
        return [back,bridge,front]
    base = f'stackThickness*(1+cos({theta}))/2+(bindingAllowance+boardMM/2)*cos({theta})'
    front = dict(id='front-cover',name='Flexible front cover',size=point(pw,ph),positionMM=vector('softX','softY',f'-({ph})/2'),
                 rotationDegrees=vector(-90,0,0),stock=paper,front=face(source,front_x,0),
                 features=dict(stockThickness='boardMM',flex=dict(edge='left',widthMM='bindingFlexWidth',angleDegrees='openingDegrees')),
                 finishes=[finish(source+'/front-foil','foil',[names['front-series']],height=.008)])
    back = dict(id='back-cover',name='Flexible back cover',size=point(pw,ph),positionMM=vector('width+overhangMM','-boardMM/2',f'-({ph})/2'),
                rotationDegrees=vector(-90,0,180),stock=paper,front=face(source,back_x,0),features=dict(stockThickness='boardMM'))
    spine = dict(id='spine-cover',name='Adhesive spine cover',size=point(sw,ph),positionMM=vector(0, '-boardMM',f'-({ph})/2'),
                 rotationDegrees=vector(-90,0,90),stock=paper,front=face(source,spine_x,0),features=dict(stockThickness='boardMM'))
    x_end = f'-overhangMM-(bindingAllowance+boardMM/2)*sin({theta})+({hx})+(({pw})-bindingFlexWidth)*cos({theta})'
    y_end = f'({base})+({hy})+(({pw})-bindingFlexWidth)*sin({theta})'
    front_flap = dict(id='front-flap',name='Front folded flap',size=point('max(flapMM,0.01)',ph),
                      positionMM=vector('softForeX+(boardMM+.02)*sin(softTheta)','softForeY-(boardMM+.02)*cos(softTheta)',f'-({ph})/2'),
                      rotationDegrees=vector(-90,0,'openingDegrees+180'),stock=paper,
                      front=face(source,f'({front_x})+({pw})',0),features=dict(stockThickness='boardMM'))
    back_flap = dict(id='back-flap',name='Back folded flap',size=point('max(flapMM,0.01)',ph),
                     positionMM=vector('width+overhangMM-flapMM','boardMM/2+0.02',f'-({ph})/2'),rotationDegrees=vector(-90,0,0),
                     stock=paper,front=face(source,0,0),features=dict(stockThickness='boardMM'))
    return [back,back_flap,spine,front,front_flap]


def hollowback_repair_operations(project_state: dict, object_id: str, *, clearance_mm: float = 2,
                                  reinforced_mm: float = .35, joint_mm: float = 10) -> dict:
    """Prepare one public atomic repair of an already-authored example.

    This changes physical construction and saved source relationships. Existing
    artwork, photos, layer IDs, stock colors/texture, body pages, stories, scenes
    and cameras are retained. Core translates canonical source anchors; no
    replacement artwork or private project write is used.
    """
    for label,value,low,high in [('clearance_mm',clearance_mm,1.5,4),('reinforced_mm',reinforced_mm,.2,.5),('joint_mm',joint_mm,6,16)]:
        if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or not low<=value<=high:
            raise ValueError(f'{label} must be a finite authored dimension within {low}–{high} mm.')
    project_id=str(uuid.UUID(project_state['id'])).upper()
    objects={item['id']:item for item in project_state['objects']}
    owner=objects.get(object_id)
    if not owner or not owner.get('sheetAssembly'):
        raise ValueError('Choose an existing authored physical book source.')
    old=owner['sheetAssembly'];by_id={p['id']:p for p in old.get('enclosure',[])}
    if not {'front-board','back-board'}.issubset(by_id):
        raise ValueError('The guarded repair requires the authored front/back board owners.')
    front,back=by_id['front-board'],by_id['back-board']
    source_id=front.get('front',{}).get('sourceObjectID')
    if not source_id or back.get('front',{}).get('sourceObjectID')!=source_id:
        raise ValueError('Front and back must retain their one original canonical cover source.')
    source=objects.get(source_id)
    if not source or not source.get('artwork') or not source.get('artworkRegions'):
        raise ValueError('Preserved canonical artwork and region anchors are required before repair.')
    names={e.get('name'):e['id'] for e in source['artwork']['elements']}
    required={'front-series','front-title','front-footer','blind-mark','back-heading','back-copy','back-colophon','spine-title'}
    if not required.issubset(names):
        raise ValueError('Canonical named cover layers changed; review their explicit IDs before repair.')
    inset=next((r.get('insert',{}).get('face',{}).get('sourceObjectID') for r in front.get('features',{}).get('recesses',[]) if r['id']=='inset-seat'),None)
    recipes={recipe['id']:recipe for recipe in project_state.get('recipes',[])}
    recipe=copy.deepcopy(recipes.get(owner['recipeID']))
    if not recipe or recipe.get('parts') or recipe.get('solid'):
        raise ValueError('The source must retain its project-owned empty control recipe.')
    updates=dict(spineBoardMM=reinforced_mm,jointMM=joint_mm)
    fresh=control_recipe(project_id,'hardcover')
    prototypes={p['id']:p for p in fresh['parameters']}
    existing={p['id']:p for p in recipe['parameters']}
    for key in ('spineBoardMM','jointMM','clearanceMM','wrapMM'):
        param=copy.deepcopy(prototypes[key]);param['value']=dict(updates,clearanceMM=clearance_mm,wrapMM=owner['parameters'].get('wrapMM',sum(p['thicknessMM'] for p in front.get('features',{}).get('wrap',{}).get('stock',{}).get('plies',[])) or front.get('features',{}).get('wrap',{}).get('stock',{}).get('thicknessMM',.12)))[key];existing[key]=param
    order=[p['id'] for p in recipe['parameters']]
    for key in ('clearanceMM','wrapMM'):
        if key not in order:order.append(key)
    recipe['parameters']=[existing[key] for key in order]
    proposed=copy.deepcopy(old);proposed['derived']=dict(old.get('derived') or {});proposed['derived'].update(cover_derived('hardcover'))
    authored=cover_planes('hardcover',source_id,names,inset)
    physical_adjustments=[]
    for index,plane in enumerate(authored):
        if plane['id'] in ('front-board','back-board'):
            retained=copy.deepcopy(by_id[plane['id']])
            for key in ('size','positionMM','rotationDegrees','front'):
                retained[key]=copy.deepcopy(plane[key])
            if retained.get('features',{}).get('wrap'):retained['features']['wrap']['stockThickness']='wrapMM'
            if plane['id']=='front-board':
                for recess in retained.get('features',{}).get('recesses',[]):
                    prior=recess.get('origin',{}).get('x')
                    if recess['id']=='inset-seat' and isinstance(prior,str) and ''.join(prior.split())=='((width+2*overhangMM)-insetWidthMM)/2':
                        adjusted='(casePanelWidth-insetWidthMM)/2'
                        recess['origin']['x']=adjusted
                        physical_adjustments.append(dict(panel_id=plane['id'],recess_id=recess['id'],field='origin.x',before=prior,after=adjusted,
                            reason='Keep the existing photo seat centered on the corrected constant-size physical board; photo source/crop/stock/depth are retained.'))
            authored[index]=retained
        elif plane['id']=='hollowback-bridge':
            previous=by_id.get('hollowback-bridge') or by_id.get('spine-board')
            if previous and previous['id']=='hollowback-bridge':plane['stock']=copy.deepcopy(previous['stock'])
            if previous and previous.get('finishes') is not None:plane['finishes']=copy.deepcopy(previous['finishes'])
            previous_wrap=(previous or {}).get('features',{}).get('wrap',{}).get('stock',{})
            if previous_wrap.get('profile'):
                plane['stock']['profile']=copy.deepcopy(previous_wrap['profile'])
                plane['stock']['plies'][-1]['profile']=copy.deepcopy(previous_wrap['profile'])
                if previous_wrap['profile'].get('color'):
                    plane['stock']['plies'][-1]['color']=previous_wrap['profile']['color']
    replaced={'front-board','back-board','spine-board','front-joint','back-joint','hollowback-bridge'}
    proposed['enclosure']=[copy.deepcopy(p) for p in old.get('enclosure',[]) if p['id'] not in replaced]+authored
    for leaf in proposed.get('auxiliaryLeaves',[]):
        if leaf.get('attachment',{}).get('planeID') in ('front-board','back-board') and leaf['attachment']['widthMM']==0:
            leaf['size']=point('casePanelWidth-4','casePanelHeight-4')
    owned_targets={binding['parameter'] for binding in source_bindings(object_id,'hardcover')}
    relationships=[copy.deepcopy(binding) for binding in source.get('dimensionBindings',[]) if binding['parameter'] not in owned_targets]+source_bindings(object_id,'hardcover')
    operations=[dict(name='form_update_object',arguments=dict(object_id=object_id,parameters=updates)),
                dict(name='form_create_recipe',arguments=dict(recipe=recipe,replace=True)),
                dict(name='form_update_object',arguments=dict(object_id=object_id,parameters={key:existing[key]['value'] for key in ('clearanceMM','wrapMM')})),
                dict(name='form_publication',arguments=dict(command='sheet_assembly_configure',object_id=object_id,definition=proposed)),
                dict(name='form_update_object',arguments=dict(object_id=source_id,dimension_bindings=relationships))]
    for operation in operations:validate_expression_limits(operation['arguments'])
    return dict(project_id=project_id,object_id=object_id,cover_source_id=source_id,inset_source_id=inset,
                operations=operations,source_artwork_sha256=digest(source['artwork']),
                source_content_style_topology_sha256=digest(artwork_translation_invariants(source['artwork'])),
                source_regions_sha256=digest(source['artworkRegions']),
                physical_feature_adjustments=physical_adjustments,
                note='Apply as one public form_batch after verifying the live project/source guards. Retain declared old anchors. Raw artwork SHA may change after their intended translations; verify_artwork_translation proves unchanged content/style/geometry/topology. Prove exact Undo/Redo and inspect native whole/underside views.')


def softcover_repair_operations(project_state: dict, object_id: str) -> dict:
    """Prepare public source-preserving pose/control cleanup for an existing study."""
    objects={obj['id']:obj for obj in project_state['objects']};owner=objects.get(object_id)
    if not owner or not owner.get('sheetAssembly'):raise ValueError('Choose the authored softcover source.')
    old=owner['sheetAssembly'];panels={p['id']:p for p in old.get('enclosure',[])}
    required={'back-cover','back-flap','spine-cover','front-cover','front-flap'}
    if not required.issubset(panels):raise ValueError('Expected original five softcover panel owners.')
    source_id=panels['front-cover'].get('front',{}).get('sourceObjectID');source=objects.get(source_id)
    if not source or not source.get('artworkRegions'):raise ValueError('Keep the original canonical cover and its anchors before cleanup.')
    names={e.get('name'):e['id'] for e in source['artwork']['elements']}
    if not {'front-series','front-title','back-heading','spine-title'}.issubset(names):raise ValueError('Review missing named source layers before cleanup.')
    recipe=copy.deepcopy(next((r for r in project_state.get('recipes',[]) if r['id']==owner['recipeID']),None))
    if not recipe or recipe.get('parts') or recipe.get('solid'):raise ValueError('Keep the original empty project control recipe.')
    live={'boardMM','overhangMM','flapMM'}
    if not live.issubset({p['id'] for p in recipe['parameters']}):raise ValueError('Required original dimensions are missing.')
    recipe['parameters']=[p for p in recipe['parameters'] if p['id'] in live]
    proposed=copy.deepcopy(old);proposed['derived']=dict(old.get('derived') or {});proposed['derived'].update(cover_derived('softcover'))
    authored=[]
    for plane in cover_planes('softcover',source_id,names):
        original=copy.deepcopy(panels[plane['id']])
        for key in ('size','positionMM','rotationDegrees','front'):original[key]=copy.deepcopy(plane[key])
        if plane['id']=='front-cover':
            original.setdefault('features',{})['flex']=copy.deepcopy(plane['features']['flex'])
        authored.append(original)
    proposed['enclosure']=[copy.deepcopy(p) for p in old.get('enclosure',[]) if p['id'] not in required]+authored
    targets={r['parameter'] for r in source_bindings(object_id,'softcover')}
    relationships=[copy.deepcopy(r) for r in source.get('dimensionBindings',[]) if r['parameter'] not in targets]+source_bindings(object_id,'softcover')
    operations=[dict(name='form_publication',arguments=dict(command='sheet_assembly_configure',object_id=object_id,definition=proposed)),
                dict(name='form_update_object',arguments=dict(object_id=source_id,dimension_bindings=relationships)),
                dict(name='form_create_recipe',arguments=dict(recipe=recipe,replace=True))]
    for op in operations:validate_expression_limits(op['arguments'])
    return dict(project_id=project_state['id'],object_id=object_id,cover_source_id=source_id,operations=operations,
                source_artwork_sha256=digest(source['artwork']),source_regions_sha256=digest(source['artworkRegions']),
                source_content_style_topology_sha256=digest(artwork_translation_invariants(source['artwork'])),
                note='One public batch retains book/source UUIDs, graphic/photo content, stock/finishes, declared anchors and scene poses. Match before hashes, then verify_artwork_translation for any intended anchor translations and prove Undo/Redo before acceptance.')



def jacket_fit_component() -> dict:
    """One ordinary component reorients the folded source into book axes.

    The generic construction resolver subsequently centers/grounds its closed
    bounds. These authored translations specify the intended pre-normalization
    coordinates; a scene must retain the resolver's actual registration offset.
    """
    return dict(id='jacket-fit',name='Removable jacket registration',rootPanelID='spine',
                anchor=point('flapWidth+panelWidth','panelHeight'),
                rotationDegrees=vector(-90,0,90),
                position=vector('bookFore-panelWidth','bookFloor-0.3','panelHeight/2'))



def _jacket_component_matches(components: Any) -> bool:
    # CADScalar encodes literals as expression strings after a public roundtrip.
    def normalized(value):
        if isinstance(value,dict):return {key:normalized(child) for key,child in value.items()}
        if isinstance(value,list):return [normalized(child) for child in value]
        if isinstance(value,str):
            try:number=float(value)
            except ValueError:return value
            if math.isfinite(number):return number
        return value
    return normalized(components)==normalized([jacket_fit_component()])


def jacket_fit_bindings(book_id: str, kind: str) -> list[dict]:
    if kind not in NAMES:raise ValueError('Choose the authored hard or soft cover study.')
    def reference(measurement,parameter=None):
        value=dict(sourceObjectID=book_id,measurement=measurement)
        if parameter is not None:value['parameter']=parameter
        return value
    relationships=[dict(parameter=parameter,expression=expression,inputs=dict(book=reference(measurement)))
                   for parameter,measurement,expression in [('panelWidth','closedWidth','book+1'),
                                                            ('panelHeight','closedHeight','book+1'),
                                                            ('spineWidth','closedThickness','book+0.6')]]
    fore=dict(width=reference('trimWidth'),overhang=reference('parameter','overhangMM'))
    floor=dict(board=reference('parameter','boardMM'))
    if kind=='hardcover':
        fore['wrap']=reference('parameter','wrapMM')
        floor.update(wrap=reference('parameter','wrapMM'),reinforced=reference('parameter','spineBoardMM'))
    relationships += [dict(parameter='bookFore',expression='width+overhang+wrap' if kind=='hardcover' else 'width+overhang',inputs=fore),
                      dict(parameter='bookFloor',expression='-board-wrap-reinforced/2' if kind=='hardcover' else '-board',inputs=floor)]
    relationships += [dict(parameter='boardCore',expression='board',inputs=dict(board=reference('parameter','boardMM'))),
                      dict(parameter='coverSkin',expression='skin' if kind=='hardcover' else '0',
                           inputs=dict(skin=reference('parameter','wrapMM')) if kind=='hardcover' else {})]
    return relationships


def _jacket_registration_parameters(kind: str, width: float, controls: dict) -> dict:
    needed=('boardMM','overhangMM','wrapMM','spineBoardMM') if kind=='hardcover' else ('boardMM','overhangMM')
    if not all(isinstance(controls.get(key),(int,float)) and not isinstance(controls.get(key),bool)
               and math.isfinite(controls[key]) and controls[key]>=0 for key in needed):
        raise ValueError('The original finite book dimensions are required for jacket registration.')
    return dict(bookFore=width+controls['overhangMM']+(controls['wrapMM'] if kind=='hardcover' else 0),
                bookFloor=-controls['boardMM']-(controls['wrapMM']+controls['spineBoardMM']/2 if kind=='hardcover' else 0),
                boardCore=controls['boardMM'],coverSkin=controls['wrapMM'] if kind=='hardcover' else 0)


def _jacket_parameters(values: dict) -> list[dict]:
    return [dict(name=key,value=value,minimum=-1000 if key=='bookFloor' else (0 if key=='coverSkin' else .01),maximum=1000,unit='mm')
            for key,value in values.items()]




def _jacket_continuous_flaps(definition: dict) -> None:
    """Bend the original neutral-width flaps around finite board thickness.

    The stock remains .18mm, and the source flap remains 55mm. The circular
    neutral arc is ordinary panel flex, rather than a disconnected hinge offset.
    """
    panels={panel['id']:panel for panel in definition['panels']}
    hinges={hinge['id']:hinge for hinge in definition['hinges']}
    for side,edge in [('back','right'),('front','left')]:
        hinge=hinges.get(side+'-turn')
        if not hinge or hinge.get('parentPanelID')!=side or hinge.get('childPanelID')!=side+'-flap':
            raise ValueError('The original finite flap hinge ownership is missing.')
        hinge['angleDegrees']=0;hinge['layerOffsetMM']=0
        panels[side+'-flap'].setdefault('features',{})['flex']=dict(edge=edge,
            widthMM='pi*(boardCore+2*coverSkin+paperMM+0.5)/2',angleDegrees=-180)


def jacket_scene_registration(inspection: dict, *, book_position=(0,0,0)) -> dict:
    """Recover generic normalization from the application's actual root matrix.

    Use only after applying the reviewed component. No panel geometry, mesh or
    closed-book bounds are estimated here. The returned placement is relative
    to the book's zero-yaw physical source, so preserve any scene yaw separately.
    """
    definition=inspection.get('definition',{})
    if not _jacket_component_matches(definition.get('components')):
        raise ValueError('Inspect the newly registered jacket component first.')
    component=next((c for c in inspection.get('components',[]) if c.get('id')=='jacket-fit'),None)
    matrix=(component or {}).get('localToWorld',[])
    parameters=inspection.get('parameters',{})
    names=('bookFore','panelWidth','bookFloor','panelHeight','fold')
    values=[parameters.get(name) for name in names]+list(book_position)
    if len(book_position)!=3 or len(matrix)!=16 or not all(isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v) for v in values+matrix):
        raise ValueError('Require a finite actual root matrix, closed fold and three-axis book placement.')
    if abs(parameters['fold']-100)>1e-8:
        raise ValueError('Inspect the fully folded jacket before deriving its closed scene placement.')
    desired=[parameters['bookFore']-parameters['panelWidth'],parameters['bookFloor']-.3,parameters['panelHeight']/2]
    actual=[matrix[3],matrix[7],matrix[11]]
    correction=[target-observed for target,observed in zip(desired,actual)]
    return dict(object_id=inspection['object_id'],position_mm=[base+delta for base,delta in zip(book_position,correction)],
                normalization_compensation_mm=correction,desired_component_anchor_mm=desired,
                inspected_component_anchor_mm=actual,inspection_revision=inspection.get('revision'),
                note='Exact compensation of the native generic closed-bounds normalization; refresh from inspection after changing bound trim/calipers. No canonical artwork or physical dimensions change.')


def jacket_fit_operations(project_state: dict, jacket_id: str, book_id: str) -> dict:
    """Prepare a guarded, source-preserving public repair; perform no I/O.

    Verify the reviewed project hash, then call these public operations in the
    returned order. Each edit is atomic; form_construction is not supported by
    form_batch. If the second edit fails, Undo the first and verify the original
    source hashes before retrying. Inspect the actual normalized construction
    and visually verify scene registration; no application mesh is estimated.
    """
    project_id=str(uuid.UUID(project_state['id'])).upper()
    objects={obj['id']:obj for obj in project_state['objects']}
    owner,book=objects.get(jacket_id),objects.get(book_id)
    if not owner or not book or not book.get('sheetAssembly') or jacket_id==book_id:
        raise ValueError('Choose the existing jacket and its separate physical book source.')
    if owner.get('locked') or book.get('locked'):raise ValueError('Unlock the reviewed physical sources first.')
    old=owner.get('paperConstruction',{}).get('authored')
    expected_panels={'back-flap','back','spine','front','front-flap'}
    if not old or old.get('rootPanelID')!='spine' or {p['id'] for p in old.get('panels',[])}!=expected_panels:
        raise ValueError('The guarded repair requires the original five-panel jacket source.')
    component=jacket_fit_component()
    if old.get('components') and not _jacket_component_matches(old['components']):
        raise ValueError('A different authored component pose exists; review it before repair.')
    if owner.get('designID') and any(obj['id']!=jacket_id and obj.get('designID')==owner['designID'] for obj in objects.values()):
        raise ValueError('The jacket shares a construction design; review every linked consumer before configuring it.')
    source_id=owner.get('artworkSourceID');source=objects.get(source_id)
    if owner.get('artworkFit')!='actual' or not source or not source.get('artwork') or not source.get('artworkRegions') or source.get('locked'):
        raise ValueError('Retain the original actual-size canonical jacket artwork and its region anchors.')
    if any(source.get(key) for key in ('artworkSourceID','sheetAssembly','paperConstruction')):
        raise ValueError('The jacket atlas must remain a distinct canonical flat source.')
    enclosure_ids={panel['id'] for panel in book['sheetAssembly'].get('enclosure',[])}
    if {'front-board','back-board'}.issubset(enclosure_ids):kind='hardcover'
    elif {'front-cover','back-cover'}.issubset(enclosure_ids):kind='softcover'
    else:raise ValueError('Review this book construction before applying the authored study fit.')
    document=next((doc for doc in project_state.get('publications',[]) if doc['id']==book['sheetAssembly'].get('publicationID')),None)
    widths=[objects.get(page['objectID'],{}).get('parameters',{}).get('width') for page in (document or {}).get('pages',[])]
    if not widths or any(not isinstance(w,(int,float)) or isinstance(w,bool) or not math.isfinite(w) or w<=0 or abs(w-widths[0])>1e-6 for w in widths):
        raise ValueError('The authored jacket requires the reviewed uniform page trim width.')
    registration=_jacket_registration_parameters(kind,widths[0],book.get('parameters',{}))
    proposed=copy.deepcopy(old)
    declared={parameter['name']:parameter for parameter in proposed.get('parameters',[])}
    if not {'flapWidth','panelWidth','panelHeight','spineWidth','paperMM'}.issubset(declared):
        raise ValueError('Original jacket dimensions are missing.')
    # Do not transiently resize the canonical net before its dependent atlas can
    # reconcile. Preserve current dimensions when adding the pose/caliper controls.
    for parameter in proposed['parameters']:
        value=owner.get('parameters',{}).get(parameter['name'],parameter['value'])
        if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value):
            raise ValueError('The current jacket parameters must be finite numbers.')
        parameter['value']=value
    for parameter in _jacket_parameters(registration):
        if parameter['name'] in declared:declared[parameter['name']].update(parameter)
        else:proposed['parameters'].append(parameter)
    proposed['components']=[component];proposed['version']=max(3,proposed.get('version',1))
    _jacket_continuous_flaps(proposed)
    relationships=jacket_fit_bindings(book_id,kind);owned={r['parameter'] for r in relationships}
    for relationship in owner.get('dimensionBindings',[]):
        if relationship['parameter'] in owned and any(ref['sourceObjectID']!=book_id for ref in relationship.get('inputs',{}).values()):
            raise ValueError('The current jacket dimensions point at another source; inspect that relationship first.')
    relationships=[copy.deepcopy(r) for r in owner.get('dimensionBindings',[]) if r['parameter'] not in owned]+relationships
    operations=[dict(name='form_construction',arguments=dict(command='configure',object_id=jacket_id,definition=proposed)),
                dict(name='form_update_object',arguments=dict(object_id=jacket_id,dimension_bindings=relationships))]
    for operation in operations:validate_expression_limits(operation['arguments'])
    return dict(project_id=project_id,object_id=jacket_id,book_id=book_id,source_object_id=source_id,
                operations=operations,reviewed_project_sha256=digest(project_state),
                jacket_before_sha256=digest(owner),source_artwork_sha256=digest(source['artwork']),
                source_content_style_topology_sha256=digest(artwork_translation_invariants(source['artwork'])),
                source_regions_sha256=digest(source['artworkRegions']),
                jacket_finishes_sha256=digest(owner.get('paperConstruction',{}).get('finishes',[])),
                registration_parameters=registration,
                note='Apply the two individually atomic public operations in order, not form_batch (construction is excluded). If the second fails, Undo the first and verify original source hashes. Canonical source/layers, material/finish assignments and object IDs are retained. Closed normalization centers X/Z and grounds Y: use actual inspected component registration, then prove native fit, trim/caliper changes and exact Undo/Redo.')


def auxiliary_leaves(project_id: str, kind: str, *, identity_seed: str | None = None) -> list[dict]:
    key=artwork_key(project_id,kind,identity_seed)
    yellow = stock('Pale-yellow endpaper / 140 gsm',.14,PALE_YELLOW,'cotton',140)
    if kind == 'softcover':
        yellow['thicknessMM']=.12
        return [dict(id=uid(key+'/end/'+placement),name=placement.title()+' yellow flyleaf',placement=placement,
                     stock=copy.deepcopy(yellow)) for placement in ('front','back')]
    pasted = stock('Pale-yellow pastedown / 180 gsm',.18,PALE_YELLOW,'cotton',180)
    result=[]
    for placement, panel in [('front','front-board'),('back','back-board')]:
        result.append(dict(id=uid(key+'/pasted/'+placement),name=placement.title()+' pastedown',placement=placement,
                           size=point('casePanelWidth-4','casePanelHeight-4'),stock=copy.deepcopy(pasted),
                           attachment=dict(planeID=panel,edge='left',widthMM=0)))
        result.append(dict(id=uid(key+'/flyleaf/'+placement),name=placement.title()+' yellow flyleaf',placement=placement,
                           stock=copy.deepcopy(yellow),attachment=dict(edge='left',widthMM=8)))
    # Back free leaf precedes the pastedown in canonical physical sequence.
    return result[:2]+list(reversed(result[2:]))


def body_art(project_id: str, kind: str, index: int, *, identity_seed: str | None = None) -> dict:
    key=artwork_key(project_id,kind,identity_seed)+f'/body/{index+1}'
    chapter=index//16+1
    title=['Edges and intervals','Light on a surface','The weight of a sheet','Notes from the worktable'][index%4]
    values=[element(key+'/running','text',16,15,108,8,f'FIELD STUDIES / GATHER {chapter:02d}',size=7),
            element(key+'/folio','text',16,190,108,8,f'{index+1:03d} / ORIGINAL LAB-AUTHORED STUDIES',size=7)]
    if index%16==0:
        values += [element(key+'/title','text',16,41,108,49,title,size=27),
                   element(key+'/disc','ellipse',22,114,92,54,color=['#D5B96D','#52736A','#7999AA'][chapter%3])]
    elif index%3==0:
        values += [element(key+'/heading','text',16,34,108,18,title,size=16)]
        for n in range(7):
            values.append(element(key+f'/rule/{n}','rectangle',16,70+n*13,30+((index+n)*17)%79,2.5,
                                  color=['#40675E','#7F9EAD','#BC9A5C'][n%3]))
        values.append(element(key+'/caption','text',16,171,108,12,'Seven measured intervals. Printed vectors, separate from the material underneath.',size=8))
    else:
        text=('A useful page begins with attention. The blank margin holds room for a second reading; '
              'the printed mark records a decision without filling every available space. Paper carries the light '
              'differently at its edge, in the fold, and where one sheet meets another. These original studies '
              'keep those differences visible. The construction is editable: stock, grain, gathering, adhesive '
              'and cover registration remain separate choices. Change a dimension and the neighboring source '
              'regions move by their physical anchors. The words and marks retain their authored size. '
              'This is a visual material study, awaiting an actual print and bindery proof.')
        values += [element(key+'/heading','text',16,36,108,22,title,size=18),
                   element(key+'/body','text',16,73,108,84,text,size=10),
                   element(key+'/caption','text',16,167,108,16,'Observed interval / editable source / no physical production claim.',size=8)]
    return artwork(values)


class Builder:
    def __init__(self, call: Call, project_state: dict, *, request_log: TextIO | None = None):
        self.call=call;self.project_id=str(uuid.UUID(project_state['id'])).upper()
        self.initial=copy.deepcopy(project_state);self.request_log=request_log;self.requests=[];self.spec=None
    def request(self, tool: str, **arguments: Any) -> Any:
        validate_expression_limits(arguments)
        entry=dict(tool=tool,arguments=copy.deepcopy(arguments));self.requests.append(entry)
        if self.request_log:
            self.request_log.write(json.dumps(entry,ensure_ascii=False)+'\n');self.request_log.flush()
        result=self.call(tool,arguments)
        if isinstance(result,dict) and result.get('isError'):
            raise RuntimeError(f'{tool} rejected authoring: {result}')
        return result
    def check(self, kind: str) -> dict:
        current=self.request('form_get_project')
        if str(uuid.UUID(current['id'])).upper()!=self.project_id:
            raise ValueError('The active project changed; the builder will not write into another project.')
        recipe_id=control_recipe(self.project_id,kind,identity_seed=self.spec['identity_seed'],name=self.spec['name'])['id']
        if (any(recipe['id']==recipe_id for recipe in current.get('recipes',[]))
                or any(document.get('name')==self.spec['name'] for document in current.get('publications',[]))
                or any(obj.get('name','').startswith(self.spec['name']+' / ') for obj in current.get('objects',[]))):
            raise ValueError('This study already has authored controls. Use a fresh project or an explicit reviewed edit; no source is overwritten.')
        return current
    def source(self, kind: str, role: str, values: dict, art: dict) -> str:
        recipe=source_recipe(self.project_id,kind,role,values,identity_seed=self.spec['identity_seed'],name=self.spec['name'])
        self.request('form_create_recipe',recipe=recipe)
        result=self.request('form_add_object',recipe_id=recipe['id'],name=self.spec['name']+' / '+role)
        identifier=result.get('id') or result.get('object_id')
        if not identifier:
            raise ValueError('Public object creation did not return its canonical UUID.')
        self.request('form_set_artwork',object_id=identifier,artwork=art)
        self.request('form_update_object',object_id=identifier,canvas_source_only=True)
        return identifier
    def build(self, kind: str, *, photo_path: str | None = None, include_dust_jacket: bool = False,
              page_count: int | None = None,name: str | None = None,identity_seed: str | None = None,trim_mm: tuple[float,float] = TRIM) -> dict:
        self.spec=study_spec(kind,page_count=page_count,name=name,identity_seed=identity_seed,trim_mm=trim_mm)
        spec=self.spec;seed=spec['identity_seed'];name=spec['name'];trim=spec['trim_mm'];count=spec['page_count']
        if photo_path is not None:
            photo_file=Path(photo_path).expanduser().resolve(strict=True)
            if not photo_file.is_file():
                raise ValueError('The inset photo must be an existing original local file before authoring begins.')
            photo_path=str(photo_file)
        self.check(kind)
        created=self.request('form_publication',command='create',name=name,page_ids=[],
                             layout=dict(facingPages=True,firstPageSide='recto',innerMargin=18,outerMargin=16),
                             margins=dict(top=18,bottom=20,left=16,right=16))
        publication_id=created['publication_id']
        self.request('form_publication',command='create_pages',publication_id=publication_id,count=count,
                     width=trim[0],height=trim[1],columns=1,gutter=8,canvas_source_only=True)
        document=self.request('form_publication',command='get',publication_id=publication_id)
        plan=signature_plan(document,kind,page_count=count,trim_mm=trim)
        study_controls=control_values(kind)
        if kind=='hardcover' and count==192:
            study_controls['clearanceMM']=3.5
        controls=control_recipe(self.project_id,kind,identity_seed=seed,name=name,controls=study_controls)
        self.request('form_create_recipe',recipe=controls)
        initial=dict(version=1,publicationID=publication_id,stock=plan['white_stock'],openingDegrees=0,activeSpread=0,bendMM=0,
                     parentSheets=plan['parent_sheets'],signatures=plan['signatures'],binding=binding(kind))
        made=self.request('form_publication',command='sheet_assembly_create',publication_id=publication_id,
                          recipe_id=controls['id'],definition=initial,name=name+' / bound physical source')
        book_id=made['object_id'];sizes=dimensions(kind,plan['text_block_thickness_mm'],controls=study_controls,trim_mm=trim)
        page_edits=[dict(name='form_set_artwork',arguments=dict(object_id=page['objectID'],artwork=body_art(self.project_id,kind,index,identity_seed=seed)))
                    for index,page in enumerate(document['pages'])]
        for start in range(0,len(page_edits),50):
            self.request('form_batch',operations=page_edits[start:start+50])
        source_values={k:v for k,v in sizes.items() if k not in ('stack','allowance','body')}
        cover,regions,names=cover_art(self.project_id,kind,sizes,identity_seed=seed,name=name)
        source_id=self.source(kind,'continuous_cover',source_values,cover)
        inset_id=None;photo=None
        if kind=='hardcover':
            inset_id=self.source(kind,'inset',dict(width=84,depth=110),artwork([
                element(artwork_key(self.project_id,kind,seed)+'/inset/vector','rectangle',7,8,70,94,color='#8CA59D'),
                element(artwork_key(self.project_id,kind,seed)+'/inset/label','text',12,87,60,14,'ORIGINAL VECTOR STUDY\nPHOTO INPUT PENDING',size=7)]))
            if photo_path is not None:
                path=Path(photo_path).expanduser().resolve(strict=True)
                if not path.is_file():
                    raise ValueError('The photographic inset must be a readable original local image.')
                self.request('form_set_artwork',object_id=inset_id,artwork=artwork([]))
                imported=self.request('form_import_image',object_id=inset_id,path=str(path),x=0,y=0,width=84,height=110,
                                      name='Original LAB portfolio photograph / registered inset')
                photo=dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),import_result=imported)
            inset_bindings=[dict(parameter=target,expression='inputDimension',inputs={'inputDimension':dict(sourceObjectID=book_id,measurement='parameter',parameter=param)})
                            for target,param in [('width','insetWidthMM'),('depth','insetHeightMM')]]
            self.request('form_update_object',object_id=inset_id,dimension_bindings=inset_bindings)
        definition=copy.deepcopy(initial)
        definition['enclosure']=cover_planes(kind,source_id,names,inset_id)
        definition['derived']=cover_derived(kind)
        definition['auxiliaryLeaves']=auxiliary_leaves(self.project_id,kind,identity_seed=seed)
        # Source dimension dependencies and artwork anchors precede physical crop
        # assignment. The final configure validates the complete single authority.
        self.request('form_update_object',object_id=source_id,dimension_bindings=source_bindings(book_id,kind),artwork_regions=regions)
        self.request('form_publication',command='sheet_assembly_configure',object_id=book_id,definition=definition)
        # The auxiliary material increases spine source size in that same atomic
        # Core transaction; registration regions translate their canonical layers.
        accepted=self.request('form_get_project')
        if str(uuid.UUID(accepted['id'])).upper()!=self.project_id:
            raise ValueError('The project changed during authoring.')
        source=next(obj for obj in accepted['objects'] if obj['id']==source_id)
        result=dict(kind=kind,name=name,identity_seed=seed,object_id=book_id,publication_id=publication_id,
                    page_object_ids=[page['objectID'] for page in document['pages']],
                    logical_page_ids=[page['id'] for page in document['pages']],page_count=count,trim_mm=list(trim),
                    cover_source_id=source_id,inset_source_id=inset_id,photo=photo,
                    control_recipe=controls,parameters=study_controls,definition=definition,
                    parent_plan=plan,cover_regions=regions,cover_source=source,
                    source_fidelity='Canonical original artwork; dependent dimensions/anchors translate without scaling text or paths.',
                    acceptance_pending=['Native whole/close renders at closed,90,180 degrees','Native stock/control changes and Undo/reopen',
                                        'Actual print-source/PDF preflight']+(['Replace vector inset with an actual imported photo'] if kind=='hardcover' and photo is None else []))
        if include_dust_jacket:
            result['dust_jacket']=self.jacket(kind,book_id,sizes)
        return result
    def jacket(self, kind: str, book_id: str, sizes: dict) -> dict:
        params=dict(panelWidth=sizes['panelWidth']+1.0,panelHeight=sizes['panelHeight']+1.0,
                    spineWidth=sizes['spineWidth']+.6,flapWidth=55.0,paperMM=.18)
        params.update(_jacket_registration_parameters(kind,self.spec['trim_mm'][0],control_values(kind)))
        fw,pw,sw,h=(params[k] for k in ('flapWidth','panelWidth','spineWidth','panelHeight'))
        bounds=[('back-flap',0,'flapWidth'),('back','flapWidth','panelWidth'),
                ('spine','flapWidth+panelWidth','spineWidth'),('front','flapWidth+panelWidth+spineWidth','panelWidth'),
                ('front-flap','flapWidth+2*panelWidth+spineWidth','flapWidth')]
        panels=[dict(id=key,name=key.replace('-',' ').title(),role='body',polygon=[point(x,0),point(f'({x})+({w})',0),point(f'({x})+({w})','panelHeight'),point(x,'panelHeight')])
                for key,x,w in bounds]
        def hinge(key,parent,child,x,angle):
            return dict(id=key,parentPanelID=parent,childPanelID=child,start=point(x,0),end=point(x,'panelHeight'),angleDegrees=angle,layerOffsetMM='paperMM')
        hinges=[hinge('back-joint','spine','back','flapWidth+panelWidth',90),
                hinge('front-joint','spine','front','flapWidth+panelWidth+spineWidth',-90),
                hinge('back-turn','back','back-flap','flapWidth',180),
                hinge('front-turn','front','front-flap','flapWidth+2*panelWidth+spineWidth',180)]
        definition=dict(version=3,name=self.spec['name']+' / removable jacket',parameters=_jacket_parameters(params),
                        size=point('2*flapWidth+2*panelWidth+spineWidth','panelHeight'),stockThickness='paperMM',panels=panels,hinges=hinges,joins=[],rootPanelID='spine',components=[jacket_fit_component()])
        _jacket_continuous_flaps(definition)
        made=self.request('form_construction',command='create',definition=definition,name=self.spec['name']+' / separate removable jacket')
        identifier=made['object_id']
        values=[element(artwork_key(self.project_id,kind,self.spec['identity_seed'])+'/jacket/back','text',fw+16,35,pw-32,50,'An ordinary\nremovable jacket.',size=26),
                element(artwork_key(self.project_id,kind,self.spec['identity_seed'])+'/jacket/front','text',fw+pw+sw+16,35,pw-32,60,self.spec['name'],size=26)]
        source_id=self.source(kind,'jacket',dict(width=2*fw+2*pw+sw,depth=h,panelWidth=pw,panelHeight=h,spineWidth=sw,flapWidth=fw),artwork(values))
        self.request('form_paper',command='configure',object_id=identifier,stock=stock('Uncoated removable jacket / 150 gsm',.18,'#D8CEC0','cotton',150))
        self.request('form_update_object',object_id=identifier,parameters=dict(fold=100))
        # Closed-book dimensions drive a distinct physical object; no artwork or
        # geometry from the book is copied into the jacket.
        relationships=jacket_fit_bindings(book_id,kind)
        self.request('form_update_object',object_id=identifier,dimension_bindings=relationships)
        def local(name):
            return dict(sourceObjectID=identifier,measurement='parameter',parameter=name)
        source_relations=[dict(parameter=key,expression=expression,inputs=dict(pw=local('panelWidth'),ph=local('panelHeight'),sw=local('spineWidth'),fw=local('flapWidth')))
                          for key,expression in [('width','2*fw+2*pw+sw'),('depth','ph'),('panelWidth','pw'),('panelHeight','ph'),('spineWidth','sw'),('flapWidth','fw')]]
        regions=[dict(id=side,name=side.title()+' jacket',origin=point(origin,0),size=point('panelWidth','panelHeight'),
                      anchors=[dict(elementIDs=[values[n]['id']],horizontal=.5,vertical=0)])
                 for n,(side,origin) in enumerate([('back','flapWidth'),('front','flapWidth+panelWidth+spineWidth')])]
        self.request('form_update_object',object_id=source_id,dimension_bindings=source_relations,artwork_regions=regions)
        self.request('form_link_artwork',object_id=identifier,source_object_id=source_id,fit='actual')
        self.request('form_paper',command='set_finish',object_id=identifier,finish=finish(source_id+'/jacket-foil','foil',[values[1]['id']],height=.008))
        return dict(object_id=identifier,source_object_id=source_id,definition=definition,dimension_bindings=relationships,source_dimension_bindings=source_relations,
                    note='Separate ordinary five-panel paper construction in book axes, sized from authoritative closed bounds. One independent registered source carries editable regions/anchors; generic component normalization still requires explicit scene registration.',
                    acceptance_pending=['Native placement/fit with bound source','Review all five jacket crops after material dimension changes'])


def build_book_study(call: Call, project_state: dict, *, kind: str = 'hardcover',
                     photo_path: str | None = None, include_dust_jacket: bool = False,
                     request_log: TextIO | None = None,page_count: int | None = None,name: str | None = None,
                     identity_seed: str | None = None,trim_mm: tuple[float,float] = TRIM) -> dict:
    builder=Builder(call,project_state,request_log=request_log)
    return builder.build(kind,photo_path=photo_path,include_dust_jacket=include_dust_jacket,page_count=page_count,name=name,identity_seed=identity_seed,trim_mm=trim_mm)


def build_book_studies(call: Call, project_state: dict, *, photo_path: str | None = None,
                      include_dust_jackets: bool = True, request_log: TextIO | None = None) -> dict:
    builder=Builder(call,project_state,request_log=request_log)
    hard=builder.build('hardcover',photo_path=photo_path,include_dust_jacket=include_dust_jackets)
    soft=builder.build('softcover',include_dust_jacket=False)
    return dict(project_id=builder.project_id,hardcover=hard,softcover=soft,
                request_count=len(builder.requests),request_digest=digest(builder.requests),
                physical_status='Original project-authored visual studies, not calibrated manufacturing specifications.')


def finish_bare_softcover_study(call:Call, project_state:dict, *, object_id:str,
                                publication_id:str, expected_project_id:str,
                                expected_snapshot_sha256:str, identity_seed:str|None=None,
                                request_log:TextIO|None=None)->dict:
    """Finish an explicitly guarded, precreated study without recreating pages.

    A new live public snapshot must exactly match the caller's reviewed snapshot.
    Existing nonempty page sources are never repainted. Only missing/empty page
    artwork is authored; one missing cover source is then created. The final
    relationships/construction/control-pruning edit uses one public batch.
    This is an explicit recovery entry point, not an automatic builder resume.
    """
    expected_id=str(uuid.UUID(expected_project_id)).upper()
    if str(uuid.UUID(project_state['id'])).upper()!=expected_id or digest(project_state)!=expected_snapshot_sha256:
        raise ValueError('Reviewed recovery snapshot/project guard does not match.')
    objects={item['id']:item for item in project_state['objects']}
    owner=objects.get(object_id);document=next((d for d in project_state.get('publications',[]) if d['id']==publication_id),None)
    if not owner or not document or owner.get('sheetAssembly',{}).get('publicationID')!=publication_id:
        raise ValueError('Recovery must target the existing physical owner and its exact publication.')
    initial=owner['sheetAssembly']
    if initial.get('enclosure') or initial.get('auxiliaryLeaves') or initial.get('leaves') is not None:
        raise ValueError('Only a bare implicit-leaf assembly can use this finish helper; retain existing cover edits.')
    entries=document['pages'];count=len(entries)
    if count<16 or count>192 or count%16:
        raise ValueError('The existing study needs complete 16-page gathers, at most192 pages.')
    pages=[objects[entry['objectID']] for entry in entries]
    trims={(page['parameters']['width'],page['parameters']['depth']) for page in pages}
    if len(trims)!=1:raise ValueError('This authored study requires a uniform existing trim.')
    trim=tuple(trims.pop());study_spec('softcover',page_count=count,trim_mm=trim,identity_seed=identity_seed)
    recipe=copy.deepcopy(next((r for r in project_state.get('recipes',[]) if r['id']==owner['recipeID']),None))
    if not recipe or recipe.get('parts') or recipe.get('solid'):
        raise ValueError('Retain the original project-owned empty construction-control recipe.')
    live={'boardMM','overhangMM','flapMM'}
    if not live.issubset(owner['parameters']) or not live.issubset({p['id'] for p in recipe['parameters']}):
        raise ValueError('The precreated assembly is missing its authored softcover controls.')
    if sum(obj['recipeID']==owner['recipeID'] for obj in project_state['objects'])!=1:
        raise ValueError('Review shared construction-control owners before pruning a recovery recipe.')
    parents=initial.get('parentSheets') or []
    if len(parents)!=count//4 or not initial.get('signatures'):
        raise ValueError('Retain a complete reviewed physical parent/signature plan before finishing.')
    def thickness(stock:dict)->float:
        return sum(ply['thicknessMM'] for ply in stock['plies']) if stock.get('plies') else stock['thicknessMM']
    body=sum(thickness(parent['stock'])*2 for parent in parents)
    controls={key:owner['parameters'][key] for key in control_values('softcover')}
    sizes=dimensions('softcover',body,controls=controls,trim_mm=trim)
    values={key:value for key,value in sizes.items() if key not in ('stack','allowance','body')}
    source_control=source_recipe(expected_id,'softcover','continuous_cover',values,identity_seed=identity_seed,name=document['name'])
    if any(r['id']==source_control['id'] for r in project_state.get('recipes',[])):
        raise ValueError('A cover source already exists or was partially created. Inspect it instead of creating a duplicate.')
    builder=Builder(call,project_state,request_log=request_log)
    builder.spec=dict(name=document['name'],identity_seed=identity_seed,page_count=count,trim_mm=trim)
    current=builder.request('form_get_project')
    if digest(current)!=expected_snapshot_sha256:
        raise ValueError('Live project changed after recovery review; no authoring requests were sent.')
    missing=[(index,page) for index,page in enumerate(pages) if not (page.get('artwork') or {}).get('elements')]
    edits=[dict(name='form_set_artwork',arguments=dict(object_id=page['id'],artwork=body_art(expected_id,'softcover',index,identity_seed=identity_seed))) for index,page in missing]
    for start in range(0,len(edits),50):builder.request('form_batch',operations=edits[start:start+50])
    cover,regions,names=cover_art(expected_id,'softcover',sizes,identity_seed=identity_seed,name=document['name'])
    source_id=builder.source('softcover','continuous_cover',values,cover)
    definition=copy.deepcopy(initial)
    definition['derived']=dict(initial.get('derived') or {});definition['derived'].update(cover_derived('softcover'))
    definition['enclosure']=cover_planes('softcover',source_id,names)
    definition['auxiliaryLeaves']=auxiliary_leaves(expected_id,'softcover',identity_seed=identity_seed)
    recipe['parameters']=[p for p in recipe['parameters'] if p['id'] in live]
    final_operations=[dict(name='form_update_object',arguments=dict(object_id=source_id,dimension_bindings=source_bindings(object_id,'softcover'),artwork_regions=regions)),
                      dict(name='form_publication',arguments=dict(command='sheet_assembly_configure',object_id=object_id,definition=definition)),
                      dict(name='form_create_recipe',arguments=dict(recipe=recipe,replace=True))]
    before_final=builder.request('form_get_project')
    builder.request('form_batch',operations=final_operations)
    after=builder.request('form_get_project')
    if str(uuid.UUID(after['id'])).upper()!=expected_id:raise ValueError('Active project changed during recovery; inspect the retained request log.')
    accepted={item['id']:item for item in after['objects']};missing_ids={p['id'] for _,p in missing}
    retained=[page['id'] for page in pages if page['id'] not in missing_ids]
    if any(accepted[identifier]!=objects[identifier] for identifier in retained):raise ValueError('An existing nonempty page source changed unexpectedly; inspect before continuing.')
    if after.get('camera')!=project_state.get('camera') or after['publications']!=project_state['publications']:
        raise ValueError('Existing camera or publication source changed unexpectedly during recovery.')
    return dict(project_id=expected_id,object_id=object_id,publication_id=publication_id,cover_source_id=source_id,
                authored_missing_page_ids=[p['id'] for _,p in missing],retained_page_ids=retained,
                reviewed_snapshot_sha256=expected_snapshot_sha256,final_batch_before_snapshot_sha256=digest(before_final),
                final_batch_before=before_final,after_snapshot_sha256=digest(after),final_operations=final_operations,
                definition=definition,cover_regions=regions,request_count=len(builder.requests),request_digest=digest(builder.requests),
                acceptance_pending=['Exact final-batch Undo/Redo and reopen','Native whole/underside views at closed,95,180 degrees','Review stock, flap/hinge controls and print-source preflight'])
