#!/usr/bin/env python3
"""Project-authored physical publication specimens, using existing public MCP.

Import-only helper: no launch, native call, model generation API or file access
happens until the explicit functions are invoked by the validation runner.
"""
from __future__ import annotations
import ast
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import uuid

from render_paper_packaging import camera

NS = uuid.UUID('24c67d3c-2d22-43ee-b0bb-750545b2ad80')
PAPER = '#F4EDDD'
FOREST = '#21483F'
GOLD = '#C3A365'


def uid(name):
    return str(uuid.uuid5(NS, name)).upper()


def profile(color=PAPER, texture='smooth', roughness=.92, depth=.006):
    return dict(texture=texture, color=color, roughness=roughness,
                textureScaleMM=.9, textureDepthMM=depth, opacity=1)


def stock(name, thickness, color=PAPER, texture='smooth', gsm=120):
    return dict(name=name, thicknessMM=thickness, grain='parallelHeight', gsm=gsm,
                verified=False, notes='Authored visual stock; physical binding and press proof remain unverified.',
                profile=profile(color, texture))


def board_stock(name, outside_is_front=True):
    end = dict(id=uid(name+'-end'),name='Endpaper',color=PAPER,thicknessMM=.15,
               profile=profile(PAPER, 'cotton'))
    wrap = dict(id=uid(name+'-wrap'),name='Printed cloth wrap',color=FOREST,thicknessMM=.15,
                profile=profile(FOREST, 'linen', .72, .018))
    core = dict(id=uid(name+'-core'),name='Board core',color='#AAA38E',thicknessMM=1.2,
                profile=profile('#AAA38E', 'recycled'))
    value = stock(name, 1.5, FOREST, 'linen', gsm=900)
    value['plies'] = [end, core, wrap] if outside_is_front else [wrap, core, end]
    return value


def element(kind, key, x, y, width, height, color, text='', points=12, **extra):
    value = dict(id=uid(key),name=key,kind=kind,x=x,y=y,width=width,height=height,
                 color=color,text=text,fontSize=points)
    if kind == 'text':
        value['typography'] = dict(fontName='HelveticaNeue-Medium', leading=points*1.35)
    value.update(extra)
    return value


def artwork(elements, color=PAPER, position=None, bleed=3):
    value = dict(background=color, backgroundOpacity=1, bleed=bleed, elements=elements, unit='mm')
    if position is not None:
        value['canvasPosition'] = dict(zip(('x', 'y'), position))
    return value


def finish(key, kind, ids, side='outside', depth=0, height=0, color=None):
    value = dict(id=uid(key),name=key,kind=kind,side=side,elementIDs=ids,
                 depthMM=depth,heightMM=height,opacity=1,enabled=True)
    if kind == 'foil':
        value.update(color=color or GOLD,roughness=.18,metallic=1)
    return value


def booklet(call, row):
    document = call('form_publication',command='get',publication_id=row['publication_id'])
    pages = document['pages']; w,h = row['width_mm'],row['height_mm']
    assert len(pages) == 12 and (w,h) == (148,210)
    front = [element('text','booklet-edition',16,17,w-32,8,PAPER,'FIELD OFFICE / NOTES / 001',9),
             element('text','booklet-title',16,49,w-32,70,PAPER,'Slow city.\nField notes.',52),
             element('ellipse','booklet-blind-seal',w-60,135,35,35,PAPER),
             element('text','booklet-front-foot',16,h-34,w-32,20,PAPER,'A record of walking, repair and ordinary attention.\nTWELVE PAGES / FIRST EDITION',8.5)]
    back = [element('text','booklet-back-title',16,43,w-32,65,PAPER,'Keep a record.\nMake another.',29),
            element('text','booklet-back-edition',16,h-30,w-32,12,PAPER,'FIELD OFFICE / 2026 / MADE IN LAB',9)]
    call('form_set_artwork',object_id=pages[0]['objectID'],artwork=artwork(front,FOREST,(500,40)))
    call('form_set_artwork',object_id=pages[-1]['objectID'],artwork=artwork(back,FOREST,(500+11*(w+36),40)))
    leaves=[]
    for i in range(6):
        value=dict(id=uid('booklet-leaf-'+str(i)),frontPageID=pages[2*i]['id'],backPageID=pages[2*i+1]['id'])
        if i in (0,5):
            value['stock']=stock('Printed cover / 0.25 mm',.25,FOREST,'coated',gsm=250)
        if i == 0:
            value['finishes']=[finish('Booklet / warm foil','foil',[front[0]['id']],height=.01),
                               finish('Booklet / blind seal','emboss',[front[2]['id']],height=.08)]
        if i == 5:
            value['finishes']=[finish('Booklet / reverse foil','foil',[back[1]['id']],side='inside',height=.01)]
        leaves.append(value)
    definition=dict(version=1,publicationID=document['id'],stock=stock('Body / 0.11 mm',.11),
                    openingDegrees=180,activeSpread=3,bendMM=.9,leaves=leaves)
    made=call('form_publication',command='sheet_assembly_create',publication_id=document['id'],
              definition=definition,name='Slow city / linked physical sheets',position=dict(x=-235,y=0,z=0))
    return dict(kind='booklet',name=row['name'],object_id=made['object_id'],definition=definition,
                width_mm=w,height_mm=h,page_count=12,position_mm=[-235,0,0],cover_source_ids=[pages[0]['objectID'],pages[-1]['objectID']])


def hardcover(call, row):
    w,h = row['width_mm'],row['height_mm']; assert (w,h) == (180,240)
    document=call('form_publication',command='get',publication_id=row['publication_id'])
    assert len(document['pages']) == 64
    cw,ch=w+6,h+6; nominal_spine=32*.12+3; maximum_spine=32*.18+3
    wrap_width=2*cw+maximum_spine
    # The same ordinary authored planar construction used for other paper goods.
    source=dict(version=1,name='Continuous cloth cover source',parameters=[],size=dict(x=wrap_width,y=ch),
        stockThickness=.18,panels=[dict(id='wrap',name='Continuous cover artwork',role='body',
            polygon=[dict(x=0,y=0),dict(x=wrap_width,y=0),dict(x=wrap_width,y=ch),dict(x=0,y=ch)])],
        hinges=[],joins=[],rootPanelID='wrap')
    wrap=call('form_construction',command='create',definition=source,name='Material atlas / continuous cover wrap',position=[0,0,0])['object_id']
    front_origin=cw+nominal_spine
    values=[element('text','atlas-back-title',18,49,cw-36,65,PAPER,'Useful edges.\nOriginal questions.',29),
            element('text','atlas-back-footer',18,ch-37,cw-36,20,PAPER,'FIELD OFFICE / MATERIAL STUDIES\n64 PAGES / FIRST EDITION',9),
            element('text','atlas-front-edition',front_origin+18,18,cw-36,8,PAPER,'FIELD OFFICE / MATERIAL STUDIES',10),
            element('text','atlas-front-title',front_origin+18,54,cw-36,86,PAPER,'Material\natlas.',62),
            element('ellipse','atlas-blind-mark',front_origin+cw-62,170,34,34,PAPER),
            element('text','atlas-front-footer',front_origin+18,ch-32,cw-36,15,PAPER,'A useful collection of surfaces, sections and observations.',8.5),
            element('text','atlas-spine-title',cw+nominal_spine/2-64,ch/2-3,128,6,PAPER,
                    'MATERIAL ATLAS / FIELD OFFICE',8,rotation=90)]
    values[-1]['typography']['alignment']='center'
    call('form_set_artwork',object_id=wrap,artwork=artwork(values,FOREST,(500,1160),bleed=6))
    call('form_paper',command='configure',object_id=wrap,stock=stock('Cloth wrap / 0.18 mm',.18,FOREST,'linen',gsm=180))
    for assignment in [finish('Atlas / warm metallic typography','foil',[values[2]['id'],values[6]['id'],values[1]['id']],height=.012),
                       finish('Atlas / blind raised mark','emboss',[values[4]['id']],height=.10)]:
        call('form_paper',command='set_finish',object_id=wrap,finish=assignment)
    end=call('form_add_object',recipe_id='artboard',name='Material atlas / independent endpaper',parameters=dict(width=cw,depth=ch))
    end_id=end.get('id') or end.get('object_id'); assert end_id
    end_art=[element('text','atlas-endpaper-label',17,18,cw-34,8,FOREST,'A FIELD FOR OBSERVATION',9)]
    for i in range(16):
        end_art.append(element('line','atlas-endpaper-rule-'+str(i),17,37+i*11,cw-34,.001,FOREST,
                               stroke=dict(color='#B9C4AF',width=.12)))
    call('form_set_artwork',object_id=end_id,artwork=artwork(end_art,PAPER,(950,1160)))
    # Reference geometry: a three-board case. Spine unfolds between the boards;
    # all three source crops retain actual dimensions and share one wrap source.
    p='(1-cos(radians(openingDegrees)))/2'; phi='(90+openingDegrees/2)'; s='(stackThickness+3)'
    front=dict(id='front-board',name='Front board',size=dict(x='width+6',y='height+6'),
        positionMM=dict(x=f'-3*cos(radians(openingDegrees))-0.75*sin(radians(openingDegrees))-({s}/2+3)*({p})',
                        y='stackThickness*(1+cos(radians(openingDegrees)))/2-3*sin(radians(openingDegrees))+0.75*cos(radians(openingDegrees))',z='-height/2-3'),
        rotationDegrees=dict(x=-90,y=0,z='openingDegrees'),stock=board_stock('Front case board'),
        front=dict(sourceObjectID=wrap,sourceSide='outside',sourceOriginMM=dict(x='width+6+stackThickness+3',y=0)),
        back=dict(sourceObjectID=end_id,sourceSide='outside',sourceOriginMM=dict(x=0,y=0)))
    back=dict(id='back-board',name='Back board',size=dict(x='width+6',y='height+6'),
        positionMM=dict(x=f'-3+({s}/2+3)*({p})',y=-.75,z='-height/2-3'),rotationDegrees=dict(x=-90,y=0,z=0),
        stock=board_stock('Back case board',False),front=dict(sourceObjectID=end_id,sourceSide='outside'),
        back=dict(sourceObjectID=wrap,sourceSide='outside',sourceOriginMM=dict(x=0,y=0)))
    spine=dict(id='spine-board',name='Spine board',size=dict(x=s,y='height+6'),
        positionMM=dict(x=f'-3.75*(1-({p}))-({s}/2)*cos(radians({phi}))',
                        y=f'(stackThickness/2)*(1-({p}))-0.75*({p})-({s}/2)*sin(radians({phi}))',z='-height/2-3'),
        rotationDegrees=dict(x=-90,y=0,z=phi),stock=board_stock('Spine case board'),
        front=dict(sourceObjectID=wrap,sourceSide='outside',sourceOriginMM=dict(x='width+6',y=0)))
    definition=dict(version=1,publicationID=document['id'],stock=stock('Book block / 0.12 mm',.12,'#F4EDDD','cotton'),
                    openingDegrees=180,activeSpread=16,bendMM=2.4,enclosure=[front,back,spine])
    made=call('form_publication',command='sheet_assembly_create',publication_id=document['id'],definition=definition,
              name='Material atlas / linked physical sheets',position=dict(x=240,y=1.5,z=0))
    return dict(kind='hardcover',name=row['name'],object_id=made['object_id'],definition=definition,
        width_mm=w,height_mm=h,page_count=64,position_mm=[240,1.5,0],cover_source_ids=[wrap,end_id],
        cover_wrap=dict(object_id=wrap,width_mm=wrap_width,height_mm=ch,bleed_mm=6,
            nominal_caliper_mm=.12,accepted_caliper_mm=[.12,.18],spine_width_mm=nominal_spine,
            maximum_spine_width_mm=maximum_spine,front_nominal_origin_mm=front_origin),
        assumptions=['Source wrap includes the maximum0.18mm caliper extent; cover marks retain at least18mm side margins.',
                     'Three independently authored board planes articulate without product-specific application code.',
                     'The case/binding is a visual physical assembly, not calibrated binding mechanics.'])


def create_physical_examples(call, rows):
    assert len(rows)==2
    result=[booklet(call,rows[0]),hardcover(call,rows[1])]
    return dict(version=1,assemblies=result,source_policy='Canonical publication pages and one shared editable cover wrap; no fitted artwork.',
                manufacturing_verified=False)


def number(value, variables):
    if isinstance(value,(int,float)):
        return float(value)
    functions=dict(sin=math.sin,cos=math.cos,radians=math.radians)
    def visit(node):
        if isinstance(node,ast.Constant) and type(node.value) in (int,float):return float(node.value)
        if isinstance(node,ast.Name) and node.id in variables:return variables[node.id]
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,(ast.USub,ast.UAdd)):
            v=visit(node.operand);return -v if isinstance(node.op,ast.USub) else v
        if isinstance(node,ast.BinOp):
            a,b=visit(node.left),visit(node.right)
            if isinstance(node.op,ast.Add):return a+b
            if isinstance(node.op,ast.Sub):return a-b
            if isinstance(node.op,ast.Mult):return a*b
            if isinstance(node.op,ast.Div):return a/b
        if isinstance(node,ast.Call) and isinstance(node.func,ast.Name) and node.func.id in functions and len(node.args)==1 and not node.keywords:
            return functions[node.func.id](visit(node.args[0]))
        raise ValueError('Unsupported authored bounds expression: '+str(value))
    result=visit(ast.parse(value,mode='eval').body)
    assert math.isfinite(result)
    return result


def transform(point, rotation, position):
    x,y,z=point;rx,ry,rz=[math.radians(v) for v in rotation]
    y,z=y*math.cos(rx)-z*math.sin(rx),y*math.sin(rx)+z*math.cos(rx)
    x,z=x*math.cos(ry)+z*math.sin(ry),-x*math.sin(ry)+z*math.cos(ry)
    x,y=x*math.cos(rz)-y*math.sin(rz),x*math.sin(rz)+y*math.cos(rz)
    return [x+position[0],y+position[1],z+position[2]]


def caliper(value):
    return sum(p['thicknessMM'] for p in value['plies']) if value.get('plies') else value['thicknessMM']


def physical_points(row, definition):
    w,h=row['width_mm'],row['height_mm'];count=(row['page_count']+1)//2
    stocks=[leaf.get('stock',definition['stock']) for leaf in definition.get('leaves', [{} for _ in range(count)])]
    thickness=sum(caliper(v) for v in stocks);angle=math.radians(definition['openingDegrees'])
    variables=dict(width=w,height=h,leafCount=count,pageCount=row['page_count'],stackThickness=thickness,
                   openingDegrees=definition['openingDegrees'],activeSpread=definition['activeSpread'],bendMM=definition['bendMM'])
    points=[];accumulated=0
    for index,paper in enumerate(stocks):
        t=caliper(paper);turned=definition['openingDegrees']!=0 and index<definition['activeSpread'];theta=angle if turned else 0
        offset=-(accumulated+t/2) if turned else thickness-accumulated-t/2
        base=thickness*(1+math.cos(angle))/2 if turned else 0
        rise=(definition['bendMM'] if not turned else -definition['bendMM']) if definition['openingDegrees'] else 0
        if rise:
            low,high=0,math.pi/2
            for _ in range(40):
                mid=(low+high)/2
                if w*(1-math.cos(mid))/mid<abs(rise):low=mid
                else:high=mid
            radius=w/((low+high)/2)*(1 if rise>0 else -1)
        for i in range(65):
            u=w*i/64
            for v in [0,h]:
                for z in [-t/2,t/2]:
                    if rise:
                        a=u/(radius-offset);local=[(radius-offset-z)*math.sin(a),-v,radius*(1-math.cos(a))+(offset+z)*math.cos(a)]
                        p=transform(local,[-90,0,math.degrees(theta)],[0,base,-h/2])
                    else:
                        p=transform([u,-v,z],[-90,0,math.degrees(theta)],[-offset*math.sin(theta),base+offset*math.cos(theta),-h/2])
                    points.append(p)
        accumulated+=t
    for plane in definition.get('enclosure',[]):
        size=[number(plane['size'][key],variables) for key in ('x','y')]
        pos=[number(plane['positionMM'][key],variables) for key in ('x','y','z')]
        rot=[number(plane['rotationDegrees'][key],variables) for key in ('x','y','z')]
        half=caliper(plane['stock'])/2
        for u in [0,size[0]]:
            for v in [0,size[1]]:
                for z in [-half,half]:points.append(transform([u,-v,z],rot,pos))
    placement=row['position_mm']
    return [[p[i]+placement[i] for i in range(3)] for p in points]


def assembly_variables(row, definition):
    count=len(definition.get('leaves') or []) or (row['page_count']+1)//2
    leaves=definition.get('leaves') or [{} for _ in range(count)]
    thickness=sum(caliper(leaf.get('stock',definition['stock'])) for leaf in leaves)
    return dict(width=row['width_mm'],height=row['height_mm'],pageCount=row['page_count'],leafCount=count,
                stackThickness=thickness,openingDegrees=definition['openingDegrees'],
                activeSpread=definition['activeSpread'],bendMM=definition['bendMM'])


def closed_definition(baseline, *, thicker=False):
    value=copy.deepcopy(baseline)
    value.update(openingDegrees=0,activeSpread=0,bendMM=0)
    if thicker:value['stock']['thicknessMM']=.18
    return value


def rolled_closed_definition(row, baseline):
    """Exact whole closed-book Rz(180) plus stack-height translation.

    Existing leaf controls express that rigid pose as all leaves turned left.
    Closed enclosure poses/crops are evaluated BEFORE changing those controls.
    Canonical source IDs, artwork, stock, finishes and material dimensions remain
    unchanged; the caller restores the complete accepted definition afterward.
    """
    value=closed_definition(baseline);variables=assembly_variables(row,value)
    thickness=variables['stackThickness']
    for plane in value.get('enclosure',[]):
        position={axis:number(plane['positionMM'][axis],variables) for axis in ('x','y','z')}
        rotation={axis:number(plane['rotationDegrees'][axis],variables) for axis in ('x','y','z')}
        plane['positionMM']=dict(x=-position['x'],y=thickness-position['y'],z=position['z'])
        plane['rotationDegrees']=dict(x=rotation['x'],y=rotation['y'],z=rotation['z']+180)
        plane['size']={axis:number(plane['size'][axis],variables) for axis in ('x','y')}
        for side in ('front','back'):
            face=plane.get(side)
            if face and 'sourceOriginMM' in face:
                face['sourceOriginMM']={axis:number(face['sourceOriginMM'][axis],variables) for axis in ('x','y')}
    value.update(openingDegrees=180,activeSpread=variables['leafCount'],bendMM=0)
    return value


def foreedge_crop_points(row, definitions):
    """The same world crop/camera for nominal and thicker physical blocks."""
    points=[p for definition in definitions for p in physical_points(row,definition)]
    far=max(p[0] for p in points);low=min(p[1] for p in points);high=max(p[1] for p in points)
    z=row['position_mm'][2]
    return [[x,y,depth] for x in (far-8,far+3) for y in (low-1,high+1) for depth in (z-32,z+32)]


def front_cover_crop_points(row, definition, *, emboss=False):
    variables=assembly_variables(row,definition);offset=row['position_mm']
    plane=next((p for p in definition.get('enclosure',[]) if p['id']=='front-board'),None)
    if plane:
        size=[number(plane['size'][axis],variables) for axis in ('x','y')]
        position=[number(plane['positionMM'][axis],variables) for axis in ('x','y','z')]
        rotation=[number(plane['rotationDegrees'][axis],variables) for axis in ('x','y','z')]
        half=caliper(plane['stock'])/2
        u=(size[0]-76,size[0]-12) if emboss else (12,size[0]-12)
        v=(154,218) if emboss else (12,37)
        return [[q[i]+offset[i] for i in range(3)] for x in u for y in v for height in (half,half+.15)
                for q in [transform([x,-y,height],rotation,position)]]
    raise ValueError('The authored case specimen needs its explicit front board for cover detail.')


def canonical_source_hash(project):
    # Saved output/history/camera are intentionally outside this source proof.
    source={key:project.get(key) for key in ('objects','publications','textStories','recipes','textStyles','swatches')}
    return hashlib.sha256(json.dumps(source,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def render_evidence(call, output:Path, physical, width=2000, height=1600):
    output=Path(output);folder=output/'physical-renders';folder.mkdir(parents=True,exist_ok=True)
    records=[];before=canonical_source_hash(call('form_get_project'))
    for row in physical['assemblies']:
        baseline=copy.deepcopy(row['definition']);identifier=row['object_id'];n=(row['page_count']+1)//2
        opened=copy.deepcopy(baseline);opened.update(openingDegrees=180,activeSpread=n//2)
        closed=closed_definition(baseline)
        variants=[dict(label='open-spread',definition=opened,outward=[.15,1,.35]),
                  dict(label='closed-front',definition=closed,outward=[.20,1,.40]),
                  dict(label='closed-back',definition=rolled_closed_definition(row,baseline),outward=[.20,1,.40],
                       pose_note='Rigid closed-book roll 180deg around world Z plus body-stack-height Y; true back faces remain upward under the existing lights.'),
                  dict(label='closed-spine',definition=closed,outward=[-1,.35,.12]),
                  dict(label='body-detail',definition=opened,outward=[.05,1,.15],detail='body')]
        if row['kind']=='hardcover':
            thicker=closed_definition(baseline,thicker=True)
            common_points=foreedge_crop_points(row,[closed,thicker])
            common_camera=camera(common_points,[1,.12,.16],margin=1.12,aspect=width/height)
            variants.extend([dict(label='thicker-block',definition=thicker,outward=[.25,1,.45]),
                dict(label='closed-foreedge-nominal',definition=closed,points=common_points,camera=common_camera,detail='foreedge',comparison='matched-caliper'),
                dict(label='closed-foreedge-thicker',definition=thicker,points=common_points,camera=common_camera,detail='foreedge',comparison='matched-caliper'),
                dict(label='cover-foil-cloth-detail',definition=closed,points=front_cover_crop_points(row,closed),outward=[.45,.30,.65],detail='foil-cloth'),
                dict(label='cover-emboss-cloth-detail',definition=closed,points=front_cover_crop_points(row,closed,emboss=True),outward=[-.8,.16,.4],detail='emboss-cloth')])
        else:
            points=foreedge_crop_points(row,[closed])
            variants.append(dict(label='closed-foreedge',definition=closed,points=points,outward=[1,.12,.16],detail='foreedge'))
        try:
            for variant in variants:
                definition=copy.deepcopy(variant['definition']);label=variant['label'];detail=variant.get('detail')
                call('form_publication',command='sheet_assembly_configure',object_id=identifier,definition=definition)
                points=variant.get('points') or physical_points(row,definition)
                if detail=='body':
                    x,y,z=row['position_mm']
                    points=[[x+dx,y+dy,z+dz] for dx in [-90,90] for dy in [0,8] for dz in [5,95]]
                state=variant.get('camera') or camera(points,variant['outward'],margin=1.15,aspect=width/height)
                shot=call('form_set_view',view='studio',studio_command='capture',name=row['kind']+' / '+label,
                    camera=state,reference_aspect=width/height,lighting='soft-side-v1',surface='Daylight',
                    visibility=dict(mode='objects',objectIDs=[identifier]),width=width,height=height)
                destination=folder/(row['kind']+'-'+label+'.render')
                try:
                    result=call('form_export',format='png',shot_id=shot['id'],path=str(destination))
                    png=Path(result['path']);data=png.read_bytes()
                    assert data[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24])==(width,height)
                    record=json.loads(Path(result['record']).read_text())
                    digest=hashlib.sha256(data).hexdigest();assert digest==record['png_sha256']
                    variables=assembly_variables(row,definition)
                    records.append(dict(example=row['kind'],view=label,object_id=identifier,path=str(png),record=result['record'],
                        png_sha256=digest,opening_degrees=definition['openingDegrees'],active_spread=definition['activeSpread'],bend_mm=definition['bendMM'],
                        stack_thickness_mm=variables['stackThickness'],source_definition=definition,
                        source_definition_sha256=hashlib.sha256(json.dumps(definition,sort_keys=True).encode()).hexdigest(),
                        camera=state,camera_sha256=hashlib.sha256(json.dumps(state,sort_keys=True).encode()).hexdigest(),
                        comparison_group=variant.get('comparison'),pose_note=variant.get('pose_note'),
                        intentional_closeup=bool(detail),detail=detail,lighting='soft-side-v1',
                        lighting_note='Existing fixed Studio lighting; detail uses a grazing camera, not repositioned raking lights.',
                        framing_warnings=record.get('framing_warnings',[])))
                finally:
                    # A saved shot references live design; it is not a hidden pose revision.
                    call('form_set_view',view='studio',studio_command='delete',shot_id=shot['id'])
        finally:
            call('form_publication',command='sheet_assembly_configure',object_id=identifier,definition=baseline)
    after=canonical_source_hash(call('form_get_project'))
    assert before==after,'Physical evidence must restore all canonical sources and complete assembly definitions exactly.'
    (output/'physical-source-preservation.json').write_text(json.dumps(dict(before_sha256=before,after_sha256=after,exact=True),indent=2)+'\n')
    (output/'physical-render-records.json').write_text(json.dumps(records,indent=2)+'\n')
    return records
