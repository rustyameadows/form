#!/usr/bin/env python3
"""Author reusable material studies through the ordinary installed LAB MCP.

Default is an offline plan. --apply edits only the dedicated new/resumed project;
the prior project is reopened in finally. Never launches an app or writes project
package JSON. Manufacturer photographs remain links, not distributed assets.
"""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import time
import uuid
import zlib
from datetime import datetime, timezone

from cycles_project_reads import ProjectReader, ProjectReadRevisionChanged, STALE_REVISION_MESSAGE

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'examples/cycles-materials'
NAMESPACE = uuid.UUID('cb66da59-e912-48a0-a472-cdb2215ba889')


def stable(value):
    return str(uuid.uuid5(NAMESPACE, value)).upper()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def protected_signature(project):
    required={'objects','materials','recipes','notes','camera'}
    projection=project.get('_project_read')
    if not required<=set(project) or (projection is not None and
        (not projection.get('object_details_complete') or not required<=set(projection.get('complete_sections',[])))):
        raise RuntimeError('Protected project hashes require complete scoped records, never object summaries')
    return {key:hashlib.sha256(json.dumps(project.get(key),sort_keys=True,separators=(',',':')).encode()).hexdigest()
            for key in ('objects','materials','recipes','notes','camera')}


def operation_record(name, arguments, elapsed, response):
    """Compact repeated project reads; retain mutation/status/error responses."""
    record=dict(tool=name,arguments=arguments,elapsed=elapsed)
    if name=='form_get_project' and not response.get('isError'):
        texts=[c.get('text') for c in response.get('content',[]) if c.get('type')=='text']
        try:
            payload=json.loads(texts[0]) if len(texts)==1 else response.get('structuredContent')
            if not isinstance(payload,dict):raise ValueError('Missing project envelope')
        except (ValueError,TypeError):
            record['response']=response;return record
        encoded=json.dumps(response,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')
        record['response_digest']=dict(format='result object / sorted compact UTF-8 JSON',sha256=hashlib.sha256(encoded).hexdigest(),bytes=len(encoded))
        record['read_metadata']={key:payload[key] for key in ('view','revision','pages','object_count','selected_object_count','response_complete','omitted_sections','section_counts') if key in payload}
        record['read_metadata']['project']={key:payload.get('project',{}).get(key) for key in ('id','name')}
        record['read_metadata']['section_keys']=list(payload.get('sections',{}))
        record['retention']='Repeated read payload omitted; exact protected field hashes remain in the restore checkpoint, and mutation/status/error responses remain complete.'
    else:record['response']=response
    return record


def capture_build_identity(app):
    """Read the installed bundle once; never infer a historical render's build."""
    app=app.resolve()
    with (app/'Contents/Info.plist').open('rb') as stream:info=plistlib.load(stream)
    executable=info.get('CFBundleExecutable')
    if not isinstance(executable,str) or not executable or Path(executable).name!=executable:
        raise ValueError('Installed app has no safe executable identity')
    paths=dict(app_executable='Contents/MacOS/'+executable,lab_mcp='Contents/MacOS/lab-mcp',
               renderer_helper='Contents/Helpers/lab-cycles-render',
               engine_provenance='Contents/Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json')
    files={}
    for key,relative in paths.items():
        path=app/relative
        if not path.is_file():raise RuntimeError('Installed build identity is missing '+relative)
        digest=hashlib.sha256();size=0
        with path.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk);size+=len(chunk)
        files[key]=dict(path=relative,sha256=digest.hexdigest(),size_bytes=size)
    provenance_path=app/paths['engine_provenance']
    if provenance_path.stat().st_size>1024*1024:raise ValueError('Bundled engine provenance exceeds 1 MiB')
    provenance=json.loads(provenance_path.read_text())
    engine={key:provenance[key] for key in ('source_url','source_commit','source_archive_sha256','dependency_commit','display_transform','protocol_version') if key in provenance}
    return dict(version=1,run_id=str(uuid.uuid4()),captured_at=datetime.now(timezone.utc).isoformat(),
                origin='Installed bundle files captured at author-run start; not inferred for historical attempts',
                app_bundle_name=app.name,files=files,engine=engine)


def png(path, width, height, pixels):
    """RGB technical maps, no image synthesis service or source-photo copying."""
    def chunk(tag, payload):
        return struct.pack('>I', len(payload)) + tag + payload + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff)
    scanlines = b''.join(b'\0' + pixels[y*width*3:(y+1)*width*3] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(scanlines, 9)) + chunk(b'IEND', b''))


def prepare_maps(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, roughness in [('matte', .8), ('lustrous', .3)]:
        png(output / (name + '-roughness.png'), 1, 1, bytes([round(roughness*255)]*3))
    # A repeatable analytic knitted-loop field. Explicitly estimated, never
    # described as a measured scan or used as the photographic acceptance target.
    size = 512
    values = []
    for y in range(size):
        for x in range(size):
            u, v = x / size * 8, y / size * 8
            row = math.floor(v)
            sx = (u + (row % 2)*.06) % 1
            sy = v % 1
            left = .5 - .31*math.sin(math.pi*sy)
            right = .5 + .31*math.sin(math.pi*sy)
            d = min(abs(sx-left), abs(sx-right))
            value = .16 + .68*math.exp(-(d/.085)**2)
            values.append(round(255*value))
    png(output / 'estimated-knit-height.png', size, size, bytes(v for value in values for v in [value]*3))


def appearance(case):
    return copy.deepcopy(case['appearance'])


def variant_case(case,index):
    value=copy.deepcopy(case)
    overrides=case.get('variant_overrides',[{},{}])[index]
    for key,item in overrides.items():
        if key=='appearance':value['appearance'].update(copy.deepcopy(item))
        else:value[key]=copy.deepcopy(item)
    if value.get('estimate_notes'):value['specification']+=' Variant assumption: '+value['estimate_notes']
    return value


def stock(case):
    return dict(name=case.get('variant_label',case['title']),notes=case['specification'],thicknessMM=case['thickness_mm'], gsm=case['gsm'], grain='unknown', verified=False,
                profile=dict(texture='vellum' if case['id']=='vellum' else 'cotton', roughness=case['roughness'],
                             textureScaleMM=.65, textureDepthMM=.001 if case['id']=='vellum' else .008,
                             opacity=1, appearance=appearance(case)))


def sheet_definition(name, width, height, caliper):
    return dict(version=3, name=name,
        parameters=[dict(name='width', value=width, minimum=20, maximum=400, unit='mm'),
                    dict(name='height', value=height, minimum=20, maximum=400, unit='mm'),
                    dict(name='stock', value=caliper, minimum=.05, maximum=2, unit='mm')],
        size=dict(x='width', y='height'), stockThickness='stock',
        panels=[dict(id='face', name='Sheet', role='body', polygon=[dict(x=0,y=0),dict(x='width',y=0),dict(x='width',y='height'),dict(x=0,y='height')])],
        hinges=[], joins=[], rootPanelID='face', components=[dict(id='sheet',name='Sheet',rootPanelID='face',anchor=dict(x='width/2',y='height/2'),position=dict(x=0,y=0,z=0),rotationDegrees=dict(x=-90,y=0,z=0))])


def element(case_id, name, kind, x, y, width, height, color, **other):
    value=dict(id=stable(case_id+'/'+name), name=name, kind=kind, x=x, y=y, width=width, height=height, color=color, text='', fontSize=14)
    value.update(other)
    return value


def cloth_mesh(width, depth, rise, gsm, variant, caliper=0, cols=32, rows=24):
    """Project-authored rest shape and real area-weighted masses, not app fixture code."""
    if type(cols) is not int or type(rows) is not int or min(cols,rows)<2 or (cols+1)*(rows+1)>4096 or 2*cols*rows>8192:
        raise ValueError('Cloth sampling exceeds the generic mesh budget')
    points, uv, triangles, links = [], [], [], []
    for y in range(rows+1):
        for x in range(cols+1):
            u, v = x/cols, y/rows
            z = (v-.5)*depth
            height = 20 + rise*(.5+.5*math.cos((u-.5)*math.pi*2.6))*(.7+.3*math.sin(v*math.pi))
            height += (variant*rise*.25)*math.sin(v*math.pi*2)*(u-.5)
            # A returned edge exposes the reverse surface and finite shell.
            # This is authored mesh data; the renderer adds only material caliper.
            xx=(u-.5)*width
            if variant and u>.72:
                length=(u-.72)*width
                radius=width*.28/math.pi
                angle=length/radius
                xx=.22*width+radius*math.sin(angle)
                height+=radius*(1-math.cos(angle))
            points.append(dict(x=xx, y=height, z=z));uv.append(dict(x=u,y=v))
            index = y*(cols+1)+x
            if x: links.append(dict(a=index-1,b=index,kind='warp'))
            if y: links.append(dict(a=index-cols-1,b=index,kind='weft'))
            if x and y: links.append(dict(a=index-cols-2,b=index,kind='shear'))
            if x>1: links.append(dict(a=index-2,b=index,kind='bendDistance'))
            if y>1: links.append(dict(a=index-2*(cols+1),b=index,kind='bendDistance'))
    for y in range(rows):
        for x in range(cols):
            a=y*(cols+1)+x;b=a+1;c=a+cols+1;d=c+1
            triangles += [dict(a=a,b=c,c=b),dict(a=b,b=c,c=d)]
    minimum_y=min(p['y'] for p in points)
    for point in points:point['y']+=caliper/2-minimum_y
    masses=[0.0]*len(points)
    for t in triangles:
        a,b,c=(points[t[k]] for k in ('a','b','c'))
        u=[b[k]-a[k] for k in ('x','y','z')];v=[c[k]-a[k] for k in ('x','y','z')]
        cross=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
        share=math.sqrt(sum(q*q for q in cross))*.5 / 1_000_000 * (gsm/1000) / 3
        for k in ('a','b','c'):masses[t[k]]+=share
    return dict(restPositionsMm=points,massesKg=masses,triangles=triangles,uv=uv,links=links,pins=[],panelIDs=[0]*len(points))


class Author:
    def __init__(self, args, corpus):
        self.args=args;self.corpus=corpus;self.output=args.output.resolve();self.output.mkdir(parents=True,exist_ok=True)
        self.helper=args.app.resolve()/'Contents/MacOS/lab-mcp'
        self.state_path=self.output/'state.json'
        self.state=json.loads(self.state_path.read_text()) if self.state_path.exists() else dict(version=1,cases={},textures={},project_id=None,visual_acceptance='pending')
        self.state.setdefault('authoring_token',str(uuid.uuid4()))
        self.project=None;self.imported_texture_keys=set();self.build_identity=None

    def save(self):write_json(self.state_path,self.state)

    def begin_author_run(self):
        if self.build_identity is None:
            self.build_identity=capture_build_identity(self.args.app)
            self.state.setdefault('author_runs',[]).append(copy.deepcopy(self.build_identity));self.save()
        return copy.deepcopy(self.build_identity)

    def call(self,name,args=None):
        request=dict(jsonrpc='2.0',id=1,method='tools/call',params=dict(name=name,arguments=args or {}))
        payload=json.dumps(request,separators=(',',':'))+'\n'
        if len(payload.encode())>8*1024*1024:raise ValueError('MCP request exceeds 8 MiB')
        start=time.monotonic()
        result=subprocess.run([str(self.helper)],input=payload,text=True,capture_output=True,timeout=3600 if name=='form_export' else 240)
        if result.returncode:raise RuntimeError(f'{name}: {result.stderr}')
        response=json.loads(result.stdout)
        if 'error' in response:raise RuntimeError(f'{name}: {response["error"]}')
        value=response['result']
        with (self.output/'operations.jsonl').open('a') as f:f.write(json.dumps(operation_record(name,args,time.monotonic()-start,value))+'\n')
        if value.get('isError'):
            if name=='form_get_project' and value.get('content')==[{'type':'text','text':STALE_REVISION_MESSAGE}]:
                raise ProjectReadRevisionChanged(STALE_REVISION_MESSAGE)
            raise RuntimeError(f'{name}: {value.get("content")}')
        texts=[c['text'] for c in value.get('content',[]) if c['type']=='text']
        return json.loads(texts[0]) if texts else value.get('structuredContent')

    def refresh(self,protect=False):
        self.project=ProjectReader(self.call).snapshot(protect=protect);return self.project

    def open_project(self,project_id,protect=False):
        self.project=ProjectReader(self.call).open(project_id,protect=protect);return self.project

    def object(self,name):
        matches=[o for o in self.refresh()['objects'] if o['name']==name]
        if len(matches)>1:raise RuntimeError('Ambiguous authored object name: '+name)
        return matches[0] if matches else None

    def texture(self,path,channel,scale_mm=None,max_dimension=None):
        source_sha=hashlib.sha256(path.read_bytes()).hexdigest()
        key=str(path.resolve())+':'+channel+':'+source_sha
        if max_dimension is not None:
            if type(max_dimension) is not int or not 1<=max_dimension<=4096:raise ValueError('Texture import size must be an integer from1 to4096')
            key+=':max'+str(max_dimension)
        if key not in self.imported_texture_keys:
            arguments=dict(command='import_texture',path=str(path.resolve()),color_space='srgb' if channel=='baseColor' else 'data')
            if max_dimension is not None:arguments['max_dimension']=max_dimension
            result=self.call('form_material',arguments)
            if max_dimension is not None:
                if result.get('original',{}).get('sha256')!=source_sha:raise RuntimeError('Bounded texture import did not identify the exact original source bytes')
                if result.get('derived',{}).get('sha256')!=result['texture'].get('sha256'):raise RuntimeError('Bounded texture import omitted verified derived asset provenance')
                if not result.get('resampling'):raise RuntimeError('Bounded texture import omitted explicit resampling metadata')
            self.state.setdefault('texture_imports',{})[key]=dict(source_file=path.name,source_sha256=source_sha,**result)
            self.state['textures'][key]=result['texture'];self.imported_texture_keys.add(key);self.save()
        value=copy.deepcopy(self.state['textures'][key])
        if scale_mm:
            xy=scale_mm if isinstance(scale_mm,(list,tuple)) else (scale_mm,scale_mm)
            if len(xy)!=2 or any(not isinstance(v,(int,float)) or not math.isfinite(v) or v<=0 for v in xy):
                raise ValueError('Physical texture repeat must contain two positive finite millimeter dimensions')
            value['scaleMM']=dict(x=xy[0],y=xy[1])
        return value

    def material(self,case):
        identifier='reference-'+case.get('material_variant',case['id']);value=appearance(case);maps={}
        if case.get('texture_family')=='paper':
            maps['baseColor']=self.texture(SOURCE/'assets/Paper001_1K-JPG_Color.jpg','baseColor',20)
            maps['normal']=self.texture(SOURCE/'assets/Paper001_1K-JPG_NormalGL.jpg','normal',20)
            maps['roughness']=self.texture(SOURCE/'assets/Paper001_1K-JPG_Roughness.jpg','roughness',20)
        if case.get('texture_asset_prefix'):
            prefix=case['texture_asset_prefix']
            files=case.get('texture_files',dict(normal=prefix+'_nor_gl_2k.jpg',roughness=prefix+'_rough_2k.jpg'))
            for channel,filename in files.items():
                maps[channel]=self.texture(SOURCE/'assets'/filename,channel,case['texture_repeat_mm'],case.get('texture_import_max_dimension'))
        if case.get('texture_rotation_degrees') is not None:
            for texture in maps.values():texture['rotationDegrees']=case['texture_rotation_degrees']
        if maps:value['textures']=maps
        refs=[dict(title=case['title']+' / specification',url=case['spec_url'],evidence='manufacturerSpecification',notes=case['specification']),
              dict(title=case['title']+' / real photograph',url=case['photo_url'],evidence='photograph',license='Copyright holder; linked only',notes='Compare real source photographs, not a renderer preview. Visual acceptance pending. Observed: '+json.dumps(case.get('photograph_review',{}),sort_keys=True))]
        optical_values=dict(roughness=case['roughness'],appearance={k:v for k,v in value.items() if k!='textures'})
        if case.get('back_surface'):optical_values['backSurface']=case['back_surface']
        refs.append(dict(title='Authored optical assumptions',url=case['spec_url'],evidence='estimated',notes='IOR, scattering, roughness, sheen, anisotropy and other shader coefficients are author estimates, not manufacturer BRDF measurements. Published donor scan extents describe only the donor; using that structure for the named manufacturer material is an estimated match. Paper donor scale is explicitly estimated. Optical values: '+json.dumps(optical_values,sort_keys=True)))
        refs += [dict(title=case['title']+' / additional real photograph',url=url,evidence='photograph',license='Copyright holder; linked only',notes='Supplementary real material response evidence.') for url in case.get('additional_photo_urls',[])]
        if case.get('texture_family')=='paper' or case.get('texture_asset_prefix'):
            provenance=json.loads((SOURCE/'assets/provenance.json').read_text())
            prefix='Paper001' if case.get('texture_family')=='paper' else case.get('texture_files',{}).get('normal',case['texture_asset_prefix']+'_nor_gl_2k.jpg')
            info=next(x for x in provenance if x['file'].startswith(prefix))
            refs.append(dict(title='Texture donor / '+case['texture_family'],url=info['source'],license=info['license'],evidence='estimated',notes=info['notes']+' Applied repeat in mm: '+str(case.get('texture_repeat_mm',20))+'. License: '+info['license_url']))
            if case.get('texture_import_max_dimension'):
                for channel,texture in maps.items():
                    imported=next(v for k,v in self.state.get('texture_imports',{}).items() if k in self.imported_texture_keys and v['texture']['sha256']==texture['sha256'])
                    metadata={k:imported[k] for k in ('source_file','source_sha256','original','derived','resampling')}
                    refs.append(dict(title='Portable texture derivation / '+channel,url=info['source'],asset=texture['asset'],license=info['license'],evidence='estimated',notes='Official CC0 donor resized by the generic native importer. Declared physical repeat remains unchanged. '+json.dumps(metadata,sort_keys=True)))
        if case.get('estimate_notes'):refs.append(dict(title='Authored variant assumption',url=case['spec_url'],evidence='estimated',notes=case['estimate_notes']))
        if case.get('comparison_spacing_note'):refs.append(dict(title='Standardized stitch comparison',url=case['spec_url'],evidence='estimated',notes=case['comparison_spacing_note']))
        if case.get('comparison_tie_note'):refs.append(dict(title='Authored tie comparison',url=case['spec_url'],evidence='estimated',notes=case['comparison_tie_note']))
        material=dict(id=identifier,name=case.get('variant_label',case['title']),category='Paper' if case['family']=='paper' else 'Fabric',color=case['color'],roughness=case['roughness'],metallic=0,thickness=case['thickness_mm'],appearance=value,references=refs)
        if case.get('back_surface'):material['backSurface']=copy.deepcopy(case['back_surface'])
        found=next((m for m in self.refresh()['materials'] if m['id']==identifier),None)
        if found:self.call('form_material',dict(command='update',material_id=identifier,patch={k:v for k,v in material.items() if k!='id'}))
        else:self.call('form_material',dict(command='create',material=material))
        return identifier,value

    def paper(self,case,index,position,material_id,response):
        name=f'{case.get("variant_label",case["title"])} / variant {index+1}';obj=self.object(name)
        if not obj:
            result=self.call('form_construction',dict(command='create',name=name,definition=sheet_definition(name,100,70,case['thickness_mm']),position=position,material_id=material_id))
            obj=next(o for o in self.refresh()['objects'] if o['id']==result['object_id'])
        owner=obj['id'];paper_stock=stock(case);paper_stock['profile']['appearance']=response
        self.call('form_update_object',dict(object_id=owner,material_id=material_id,position=position))
        self.call('form_paper',dict(command='configure',object_id=owner,stock=paper_stock))
        elements=[]
        if case['id']=='finished-cotton':
            elements=[element(name,'Ink','text',12,10,76,16,'#34483E',text='MATERIAL',fontSize=12),
                      element(name,'Foil','rectangle',12,34,30,3,'#BD8B35'),
                      element(name,'Blind','ellipse',68,34,16,16,'#000000')]
        elif case['id']=='cotton':
            elements=[element(name,'Fine rule','rectangle',12,49,76,.15,'#314139'),element(name,'Source label','text',12,13,76,12,'#314139',text=f'COTTON / {case["gsm"]} / {case["thickness_mm"]:g} mm',fontSize=9)]
        self.call('form_set_artwork',dict(object_id=owner,artwork=dict(background='#FFFFFF',backgroundOpacity=0,bleed=0,elements=elements)))
        if case['id']=='finished-cotton':
            finishes=[dict(id=stable(name+'/letterpress'),name='Letterpress',kind='letterpress',elementIDs=[elements[0]['id']],depthMM=.12*(index+1),color='#34483E',roughness=.8),
                      dict(id=stable(name+'/foil'),name='Metallic foil',kind='foil',elementIDs=[elements[1]['id']],heightMM=.02,color='#BD8B35',roughness=.17,metallic=1,appearance=dict(ior=1.5,coat=.25,coatRoughness=.08)),
                      dict(id=stable(name+'/emboss'),name='Blind relief',kind='emboss',elementIDs=[elements[2]['id']],heightMM=.12*(index+1))]
            for finish in finishes:
                override=case.get('finish_appearance_overrides',{}).get(finish['kind'])
                if override:finish['appearance']={**finish.get('appearance',{}),**copy.deepcopy(override)}
                self.call('form_paper',dict(command='set_finish',object_id=owner,finish=finish))
        ids=[owner]
        if (case['id']=='cotton' and index==1) or (case['id']=='vellum' and index==1):
            for layer in range(1,3 if case['id']=='cotton' else 2):
                copy_name=name+f' / sheet {layer+1}';existing=self.object(copy_name)
                if not existing:
                    existing=self.call('form_duplicate_object',dict(object_id=owner,mode='iteration',name=copy_name))
                self.call('form_paper',dict(command='configure',object_id=existing['id'],stock=paper_stock))
                self.call('form_set_artwork',dict(object_id=existing['id'],artwork=dict(background='#FFFFFF',backgroundOpacity=0,bleed=0,elements=elements)))
                self.call('form_update_object',dict(object_id=existing['id'],material_id=material_id,position=[position[0]+layer*6,position[1]+layer*(case['thickness_mm']+(.2 if case['id']=='vellum' else 0)),position[2]+layer*4]))
                ids.append(existing['id'])
        if case['id']=='vellum':
            backing_name=name+' / printed backing';backing=self.object(backing_name)
            if not backing:
                result=self.call('form_construction',dict(command='create',name=backing_name,definition=sheet_definition(backing_name,110,80,.5),position=[position[0],0,position[2]],material_id='chalk'))
                backing=next(o for o in self.refresh()['objects'] if o['id']==result['object_id'])
            self.call('form_update_object',dict(object_id=backing['id'],position=[position[0],0,position[2]]))
            marks=[element(backing_name,'Dark band','rectangle',10,20,90,9,'#1F3543'),element(backing_name,'Fine text','text',12,40,90,16,'#1F3543',text='TRANSLUCENT',fontSize=11)]
            self.call('form_set_artwork',dict(object_id=backing['id'],artwork=dict(background='#FFFFFF',backgroundOpacity=1,elements=marks,bleed=0)))
            ids.append(backing['id'])
        return ids

    def cloth(self,case,index,position,material_id):
        name=f'{case.get("variant_label",case["title"])} / variant {index+1}';obj=self.object(name)
        width=165 if case['id']=='knit' and index else 140
        if not obj:obj=self.call('form_add_object',dict(recipe_id='clothPanel',name=name,material_id=material_id,position=position,parameters=dict(width=width,depth=110,densityGSM=case['gsm'],resolution=24,supportRadius=20)))
        declaration=self.call('form_cloth',dict(command='get',object_id=obj['id']))['definition']
        if case.get('mesh_controls_file'):
            from prepare_compound_cloth import mesh as prepared_mesh
            path=(SOURCE/case['mesh_controls_file']).resolve()
            if not path.is_relative_to(SOURCE.resolve()):raise ValueError('Cloth controls must be authored corpus data')
            controls=json.loads(path.read_text());physical=controls['physical_inputs']
            if (physical['width_mm'],physical['depth_mm'],physical['gsm'],physical['caliper_mm'])!=(width,110,case['gsm'],case['thickness_mm']):
                raise ValueError('Prepared cloth controls differ from the declared material dimensions/caliper')
            declaration['mesh'],diagnostic=prepared_mesh(physical,controls['sampling'],controls['variants'][index])
            geometry=dict(kind='authored compound fold',controls=controls,diagnostic=diagnostic)
        else:
            resolution=case.get('mesh_resolution',dict(columns=32,rows=24))
            declaration['mesh']=cloth_mesh(width,110,28 if index==0 else 48,case['gsm'],index,case['thickness_mm'],resolution['columns'],resolution['rows'])
            geometry=dict(kind='analytic drape sampling',width_mm=width,depth_mm=110,rise=28 if index==0 else 48,variant=index,caliper_mm=case['thickness_mm'],resolution=resolution)
        self.state['cases'].setdefault(case['id'],{}).setdefault('authored_geometry',{})[str(index)]=geometry
        declaration['colliders']=[];declaration.pop('preparation',None)
        self.call('form_cloth',dict(command='configure',object_id=obj['id'],definition=declaration))
        self.call('form_update_object',dict(object_id=obj['id'],material_id=material_id,position=position))
        return [obj['id']]

    def thread(self,case,index,position,response):
        name=f'{case.get("variant_label",case["title"])} / variant {index+1}';obj=self.object(name)
        if not obj:obj=self.call('form_add_object',dict(recipe_id='textilePatch',name=name,material_id='linen',position=position,parameters=dict(width=80,depth=60,height=1,corner=2,borderWidth=0)))
        self.call('form_update_object',dict(object_id=obj['id'],position=position))
        rail=element(name,'Satin rail','line',12,14,54,.1,case['color'],productionRole='stitch')
        running=element(name,'Running path','line',12,46,54,.1,case['color'],productionRole='stitch')
        fill=element(name,'Fill','rectangle',20,24,40,12,case['color'],productionRole='stitch')
        source=[rail,running]+([fill] if index else [])
        self.call('form_set_artwork',dict(object_id=obj['id'],artwork=dict(background='#FFFFFF',backgroundOpacity=0,elements=source,bleed=0)))
        regions=[dict(id=stable(name+'/satin'),elementIDs=[rail['id']],method='satin',threadIndex=0,stitchLength=4,spacing=case['stitch_spacing_mm'],satinWidth=4,angle=0),
                 dict(id=stable(name+'/running'),elementIDs=[running['id']],method='running',threadIndex=0,stitchLength=2.5,spacing=.4,satinWidth=2,angle=0)]
        if index:regions.append(dict(id=stable(name+'/fill'),elementIDs=[fill['id']],method='fill',threadIndex=0,stitchLength=3,spacing=case['stitch_spacing_mm'],satinWidth=2,angle=35,underlay=dict(method='sparseFill',stitchLength=3,spacing=1.5,inset=.4)))
        design=dict(hoopWidth=100,hoopHeight=100,margin=5,trimJumpThreshold=4,maximumStitches=100000,
                    threads=[dict(name=case['title'],color=case['color'],brand='Madeira',roughness=case['roughness'],appearance=response)],regions=regions,
                    process=copy.deepcopy(case['thread_process']))
        self.call('form_update_object',dict(object_id=obj['id'],embroidery=design))
        return [obj['id']]

    def shots(self,case,ids,position):
        existing=self.call('form_set_view',dict(view='studio',studio_command='list'))
        existing=existing if isinstance(existing,list) else existing.get('result',[])
        y=position[1]+(18 if case['family']=='cloth' else 2)
        detail_z=position[2]-(16 if case['family']=='thread' else 2 if case['id']=='finished-cotton' else 0)
        close_distance=1.2 if case['id']=='finished-cotton' else .65
        specs=[('whole',.65,.68,4.0,[position[0]+95,y,position[2]]),('close',.25,1.05,close_distance,[position[0],y+(10 if case['family']=='cloth' else 0),detail_z]),('grazing',1.6,.2,2.0,[position[0]+190,y,position[2]])]
        if case['family']=='cloth':
            specs[-1]=('grazing',.9,.28,2.5,[position[0]+190,position[1]+35,position[2]])
        result=[]
        for label,azimuth,elevation,distance,target in specs:
            name=case['title']+' / '+label
            old=next((s for s in existing if s['name']==name),None)
            if self.args.view and label not in self.args.view:
                if old:result.append(old['id'])
                continue
            camera=dict(azimuth=azimuth,elevation=elevation,distance=distance,projection='perspective',target=dict(zip(('x','y','z'),[v/100 for v in target])))
            if label=='whole':
                light_position=dict(x=position[0]+95,y=y+350,z=position[2]+180);light_size=dict(x=350,y=250);power=1.4*self.args.key_power;environment=.18
            elif label=='grazing':
                if case['family']=='cloth':
                    light_position=dict(x=target[0]+100,y=target[1]+90,z=position[2]+140);light_size=dict(x=180,y=120);power=.25*self.args.key_power;environment=.18
                else:
                    light_position=dict(x=target[0]-160,y=y+75,z=position[2]+100);light_size=dict(x=140,y=80);power=.35*self.args.key_power;environment=.12
            else:
                light_position=dict(x=target[0]-100,y=target[1]+180,z=position[2]+100);light_size=dict(x=80,y=60);power=.48*self.args.key_power;environment=.12
            light=dict(id=stable(case['id']+'/'+label+'/key'),positionMM=light_position,targetMM=dict(zip(('x','y','z'),target)),sizeMM=light_size,color='#FFFFFF',powerWatts=power,shape='rectangle')
            settings=dict(renderer='cycles',device='automatic',samples=self.args.samples,previewSamples=64,noiseThreshold=.01,denoise=self.args.denoise,maxBounces=12,environmentColor='#FFFFFF',environmentStrength=environment,areaLights=[light],displacementDicingRate=2,displacementMaxTriangles=2000000,displacementMaxSubdivisions=10)
            # Preserve the authored reference camera. A different final aspect
            # uses LAB's framing expansion rather than silently cropping it.
            args=dict(view='studio',studio_command='capture',name=name,camera=camera,reference_aspect=4/3,visibility=dict(mode='objects',objectIDs=ids if label=='whole' else self.state['cases'][case['id']]['variants'][1 if label=='grazing' else 0]),surface='Graphite' if case['family']=='paper' else 'Daylight',lighting='soft-side-v1',width=self.args.width,height=self.args.height,render_settings=settings)
            if old:args.update(studio_command='update',shot_id=old['id'])
            shot=self.call('form_set_view',args);result.append(shot['id'])
            if self.args.render:
                self.render_shot(case['id'],label,shot['id'])
        return result

    def render_shot(self,case_id,label,shot_id):
        record=self.state['cases'][case_id]
        rounds=record.setdefault('render_attempts',[])
        attempt=1+sum(r['view']==label for r in rounds)
        entry=dict(view=label,attempt=attempt,label=f'{case_id}/{label}-{attempt:03d}',shot_id=shot_id,state='starting',output_location='project Exports',requested_samples=self.args.samples,requested_denoise=self.args.denoise,requested_pixels=dict(width=self.args.width,height=self.args.height),authored_reference=copy.deepcopy(record.get('reference',{})),authored_geometry=copy.deepcopy(record.get('authored_geometry',{})),build_identity=self.begin_author_run())
        rounds.append(entry);self.save()
        try:
            job=self.call('form_render',dict(command='start',project_id=self.state['project_id'],target='shot',shot_id=shot_id,pixels=dict(width=self.args.width,height=self.args.height)))
            entry.update(job);self.save();deadline=time.monotonic()+3600
            while job['state'] in ('preparing','rendering'):
                if time.monotonic()>deadline:
                    self.call('form_render',dict(command='cancel',job_id=job['job_id']))
                    raise RuntimeError('Render exceeded one hour and was cancelled')
                time.sleep(5)
                job=self.call('form_render',dict(command='status',job_id=job['job_id']))
                entry.update(job);self.save()
            if job['state']!='completed':raise RuntimeError('Render '+job['state']+': '+str(job.get('error')))
            entry.update(self.call('form_render',dict(command='result',job_id=job['job_id'])))
            for key in ('png','exr','record'):
                if not entry.get(key) or not Path(entry[key]).is_file():raise RuntimeError('Completed job omitted actual '+key+' output')
            project_files={}
            for key in ('png','exr','record'):
                file=Path(entry[key])
                if file.parent.suffix!='.render' or file.parent.parent.name!='Exports':raise RuntimeError('Default render escaped project Exports: '+str(file))
                project_files[key]='Exports/'+file.parent.name+'/'+file.name
            entry['project_files']=project_files
            entry['visual_acceptance']='pending';self.save()
        except BaseException as error:
            if entry.get('job_id') and entry['state'] in ('preparing','rendering'):
                try:self.call('form_render',dict(command='cancel',job_id=entry['job_id']))
                except Exception as cancel_error:entry['cancel_error']=str(cancel_error)
            entry.update(state='failed',failure=str(error));self.save();raise
        finally:
            # Relative package paths survive moving the .form project. Each
            # attempt is appended, including failures; no prior evidence is lost.
            evidence={key:entry[key] for key in ('label','view','attempt','shot_id','job_id','state','phase','device','fallback_reason','requested_samples','requested_denoise','requested_pixels','project_files','failure','visual_acceptance','build_identity') if key in entry}
            text='Render evidence / '+entry['label']+'\n'+json.dumps(evidence,indent=2,sort_keys=True)+'\nCompare these actual app outputs with this case’s linked original photographs before acceptance.'
            try:self.call('form_add_note',dict(text=text,kind='decision'))
            except Exception as error:
                entry['evidence_note_error']=str(error);self.save()
                if entry['state']=='completed':raise

    def restore_guard(self,current):
        pending=self.state.get('pending_restore')
        marker='cycles-materials/corpus.json v1:'+self.state['authoring_token']
        if pending and self.state['project_id'] is None and current.get('conversationReference')==marker:
            # The process may have stopped after create committed but before
            # receiving/checkpointing its reply. Recover only our unique marker.
            self.state['project_id']=current['id'];self.save()
        if pending:
            if current['id']==self.state['project_id'] and current['id']!=pending['id']:
                current=self.open_project(pending['id'],protect=True)
            if current['id']!=pending['id']:raise RuntimeError('Interrupted authoring has a pending restore to '+pending['name']+'; the active unrelated project will not be changed')
            if protected_signature(current)!=pending['signature']:raise RuntimeError('The protected original project changed after interrupted authoring')
        protected=current['id']!=self.state['project_id']
        if protected:
            pending=dict(id=current['id'],name=current['name'],signature=protected_signature(current))
            self.state['pending_restore']=pending
        self.save();return current,pending if protected else None

    def run(self):
        self.begin_author_run()
        status=self.call('form_status');self.call('form_list_recipes')
        original,guard=self.restore_guard(self.refresh(protect=True));prior_id=original['id']
        self.state.setdefault('original_project',dict(id=prior_id,name=original['name'],camera=original['camera']))
        self.state['app_status']=status;self.save()
        try:
            if self.state['project_id']:
                self.project=self.open_project(self.state['project_id'])
                if self.project['name']!=self.corpus['project_name']:raise RuntimeError('Checkpoint does not identify the authored material project')
            else:
                self.project=self.call('form_create_project',dict(name=self.corpus['project_name'],template='blank',conversation_reference='cycles-materials/corpus.json v1:'+self.state['authoring_token']))
                self.state['project_id']=self.project['id'];self.save()
            for notice in self.corpus.get('review_notices',[]):
                if not isinstance(notice,str) or not 1<=len(notice)<=4000:raise ValueError('Review notices must fit a project note')
                if not any(n.get('text')==notice for n in self.refresh().get('notes',[])):self.call('form_add_note',dict(text=notice,kind='decision'))
            for number,case in enumerate(self.corpus['cases']):
                if self.args.case and case['id'] not in self.args.case:continue
                position=[(number%2)*500,0,(number//2)*260]
                variants=[];material_ids=[]
                for index in range(2):
                    declared=variant_case(case,index)
                    material_id,response=self.material(declared);material_ids.append(material_id)
                    # Authored construction poses are grounded at localY0 by
                    # LAB. Object position is the bottom, not the slab center.
                    p=[position[0]+index*190,.5 if case['id']=='vellum' else 0,position[2]]
                    if case['family']=='paper':ids=self.paper(declared,index,p,material_id,response)
                    elif case['family']=='cloth':ids=self.cloth(declared,index,p,material_id)
                    else:ids=self.thread(declared,index,p,response)
                    variants.append(ids)
                record=self.state['cases'].setdefault(case['id'],{})
                record.update(material_id=material_ids[0],material_ids=material_ids,variants=variants,reference=case,visual_acceptance='pending');self.save()
                note=case['title']+'\n'+case['specification']+'\nReference: '+case['source_url']+'\nSpec: '+case['spec_url']+'\nPhotograph: '+case['photo_url']+'\nObserved reference: '+json.dumps(case.get('photograph_review',{}),sort_keys=True)+'\nVariant declarations: '+json.dumps(case.get('variant_overrides',{}),sort_keys=True)+'\nAcceptance pending: '+', '.join(case['review'])
                if len(note)>4000:raise ValueError('Reference note exceeds the project note limit')
                if not any(n.get('text')==note for n in self.refresh().get('notes',[])):self.call('form_add_note',dict(text=note,kind='decision'))
                for variant,geometry in record.get('authored_geometry',{}).items():
                    note='Authored cloth geometry / '+case['id']+' / variant '+variant+'\n'+json.dumps(geometry,sort_keys=True,separators=(',',':'))
                    if len(note)>4000:raise ValueError('Cloth geometry note exceeds the project note limit')
                    if not any(n.get('text')==note for n in self.refresh().get('notes',[])):self.call('form_add_note',dict(text=note,kind='decision'))
                record['shots']=self.shots(case,[i for v in variants for i in v],position);self.save()
            self.state['authored']=True;self.save()
        finally:
            restored=self.open_project(prior_id,protect=True)
            if guard and protected_signature(restored)!=guard['signature']:raise RuntimeError('Protected original project changed during authoring')
            self.state.pop('pending_restore',None);self.state['last_restored_project_id']=prior_id;self.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true');parser.add_argument('--render',action='store_true')
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/cycles-materials')
    parser.add_argument('--samples',type=int,default=512);parser.add_argument('--case',action='append')
    parser.add_argument('--view',action='append',choices=('whole','close','grazing'),help='Only update/render these saved views; repeat for multiple views')
    parser.add_argument('--width',type=int,default=1200);parser.add_argument('--height',type=int,default=900)
    parser.add_argument('--denoise',action=argparse.BooleanOptionalAction,default=True,help='Use --no-denoise for a controlled comparison; default on')
    parser.add_argument('--key-power',type=float,default=1.0,help='Scale the per-view review lights: whole1.4W,macro0.48W,grazing0.35W at1.0')
    args=parser.parse_args()
    if not 1<=args.samples<=4096:parser.error('samples must be 1–4096')
    if not (64<=args.width<=8192 and 64<=args.height<=8192 and args.width*args.height<=16777216 and .125<=args.width/args.height<=8):
        parser.error('pixels must be 64–8192 per side, at most16,777,216 total, with aspect1:8–8:1')
    if not math.isfinite(args.key_power) or not 0<args.key_power<=100:parser.error('key-power must be finite and0–100W')
    corpus=json.loads((SOURCE/'corpus.json').read_text())
    if args.case and not set(args.case)<={c['id'] for c in corpus['cases']}:parser.error('Unknown corpus case')
    for asset in json.loads((SOURCE/'assets/provenance.json').read_text()):
        path=SOURCE/'assets'/asset['file']
        if hashlib.sha256(path.read_bytes()).hexdigest()!=asset['sha256']:raise RuntimeError('Texture provenance hash mismatch: '+str(path))
    prepare_maps(args.output/'generated')
    write_json(args.output/'plan.json',dict(corpus=corpus,cases=args.case or [c['id'] for c in corpus['cases']],views=args.view or ['whole','close','grazing'],samples=args.samples,denoise=args.denoise,pixels=dict(width=args.width,height=args.height),reference_aspect=4/3,variants_per_case=2,will_launch_app=False,visual_acceptance='pending',apply_requested=args.apply))
    if args.apply:Author(args,corpus).run()
    print(json.dumps(dict(plan=str((args.output/'plan.json').resolve()),applied=args.apply,visual_acceptance='pending')))


if __name__=='__main__':main()
