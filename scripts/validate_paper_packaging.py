#!/usr/bin/env python3
"""Replay twelve editable paper studies through the installed native MCP bridge.

No project JSON is written behind the app. Source definitions live in examples/;
all model/artwork/material/finish changes use the public tool commands.
"""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = uuid.UUID('18e1ee04-ac4a-4775-a018-69d8f111eec6')
CASES = [
 ('01-rsc-shipping.json','Dispatch / Shipping carton','recycled','#B39868','#25392E',[-670,0,-430]),
 ('02-straight-tuck-carton.json','Botanical / Tuck carton','coated','#EDE6D6','#173C36',[-230,0,-430]),
 ('03-locking-mailer.json','Field kit / Locking mailer','recycled','#C0A17B','#1C4644',[180,0,-430]),
 ('04-two-piece-board-box.json','Meridian / Presentation box','smooth','#ECE4D3','#193938',[650,0,-430]),
 ('05-archival-clamshell.json','Archive / Clamshell case','linen','#D5D5BD','#283F32',[-650,0,0]),
 ('06-commercial-envelope.json','Correspondence / Envelope','smooth','#EAE4D8','#243E4B',[-190,0,0]),
 ('07-invitation-envelope.json','Gather / Lined envelope','laid','#E8E3D6','#45402E',[230,0,0]),
 ('08-hang-tag.json','Collected / Hang tag','cotton','#E5DBC8','#3F482D',[650,0,0]),
 ('09-duplex-business-card.json','Studio Field / Duplex card','cotton','#EAE2CF','#203B35',[-430,0,370]),
 ('10-postcard.json','Open country / Postcard','recycled','#E0D7C3','#2C5650',[-145,0,370]),
 ('11-folded-greeting-card.json','A small joy / Greeting card','smooth','#E9DFCE','#7E493B',[170,0,370]),
 ('12-finished-invitation.json','Gather / Invitation','cotton','#EEE5D0','#34443A',[490,0,370]),
]


def stable(text):
    return str(uuid.uuid5(NAMESPACE, text)).upper()


def element(kind, name, x, y, w, h, color, text='', size=14, **other):
    value = dict(id=stable(name), kind=kind, name=name, x=x, y=y, width=w, height=h,
                 color=color, text=text, fontSize=size)
    if kind == 'text':
        value['typography'] = dict(fontName='HelveticaNeue-Medium', alignment='left')
    value.update(other)
    return value


class Session:
    def __init__(self, app, socket, output):
        self.app = app.resolve()
        self.helper = self.app / 'Contents/MacOS/lab-mcp'
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, LAB_SOCKET_PATH=socket,
                        LAB_LIBRARY_PATH=str(self.output / 'Library'))
        self.report = dict(project_id=None, cases=[], assumptions=[
            'All stocks, dimensions and print processes are prototype assumptions, not measured manufacturer profiles.',
            'Native finish shading, geometric construction and tooling verification are reported separately.',
            'The manufacturer template is a controlled LAB-authored SVG acceptance fixture.'])

    def save(self):
        (self.output / 'report.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def call(self, name, args=None, expected_failure=False):
        args = args or {}
        start = time.monotonic()
        result = subprocess.run([str(self.helper), '--call', name, json.dumps(args)], env=self.env,
                                text=True, capture_output=True, timeout=240)
        record = dict(name=name, arguments=args, elapsed_seconds=time.monotonic()-start,
                      returncode=result.returncode)
        if result.returncode:
            record['error'] = result.stderr
            with (self.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(record) + '\n')
            if expected_failure:
                return record
            self.save()
            raise RuntimeError(f'{name}: {result.stderr}')
        if expected_failure:
            raise AssertionError(f'{name} incorrectly accepted the invalid request')
        data = json.loads(result.stdout)
        record['response_sha256'] = hashlib.sha256(result.stdout.encode()).hexdigest()
        with (self.output / 'requests.jsonl').open('a') as f:
            f.write(json.dumps(record) + '\n')
        return data

    def launch(self):
        log = (self.output / 'native-app.log').open('ab')
        process = subprocess.Popen([str(self.app / 'Contents/MacOS/LAB')], env=self.env,
                                   stdout=log, stderr=log)
        (self.output / 'pid.txt').write_text(str(process.pid))
        deadline = time.monotonic()+45
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Native app exited before opening its MCP bridge')
            if Path(self.env['LAB_SOCKET_PATH']).exists():
                try:
                    status = self.call('form_status')
                    assert Path(status['library_path']).resolve() == (self.output/'Library').resolve()
                    return process
                except (RuntimeError, json.JSONDecodeError):
                    pass
            time.sleep(.15)
        raise TimeoutError('Native bridge startup timeout')

    def clear_art(self, object_id):
        self.call('form_set_artwork', dict(object_id=object_id,
                  artwork=dict(background='#FFFFFF', backgroundOpacity=0, elements=[], bleed=3)))

    def add_panel(self, object_id, panel, label, case_key, ink, side='outside'):
        points = panel['polygon']
        width = max(p['x'] for p in points)-min(p['x'] for p in points)
        height = max(p['y'] for p in points)-min(p['y'] for p in points)
        angle = math.radians(panel.get('artworkRotationDegrees', 0))
        if abs(math.sin(angle)) > .99:
            width, height = height, width
        if width < 18 or height < 20:
            return {}
        margin = min(12, max(4, width*.09))
        prefix = f'{case_key}-{side}-{panel["id"]}'
        title = label.split(' / ')[0] if side=='outside' else 'Made to keep.'
        # Artwork frames are millimeters; nominal type size is document points.
        size = min(80, min(width*.18, (width-2*margin)/max(1,len(title)*.58), min(height*.31,34)*.78)*72/25.4)
        title_y = max(15, height*.25)
        if case_key == '08':
            title_y = 29
        values = [
            element('text',prefix+'-brand',margin,6,width-2*margin,6,ink,
                    'FIELD  /  '+case_key,8),
            element('text',prefix+'-title',margin,title_y,width-2*margin,min(height*.31,34),ink,
                    title,size),
            element('rectangle',prefix+'-rule',margin,height*.65,width*.55,.42,ink),
            element('text',prefix+'-copy',margin,height*.78,width-2*margin,min(16,height*.17),ink,
                    ('PAPER LABORATORY\nEDITABLE STUDY  /  '+case_key) if side=='outside' else
                    'A quiet detail. A lasting impression.\nDesigned in FIELD.',7.5),
        ]
        diameter = min(24, width*.21, height*.17)
        if height > 65:
            values.append(element('star' if case_key=='12' else 'ellipse',prefix+'-seal',
                          width-margin-diameter,height*.57,diameter,diameter,ink,
                          sides=12,starInset=.8))
        self.call('form_edit_artwork', dict(object_id=object_id, command='add', elements=values,
                  physical_frame=dict(surface_id=panel['id'], side=side)))
        return {kind:values[i]['id'] for i,kind in enumerate(['brand','title','rule','copy'])} | (
            {'seal':values[-1]['id']} if len(values)>4 else {})

    def finish(self, object_id, key, name, kind, targets, side='outside', **options):
        value = dict(id=stable(key+'-'+name), name=name, kind=kind, side=side,
                     elementIDs=targets, **options)
        self.call('form_paper', dict(command='set_finish', object_id=object_id, finish=value))
        return value

    def seed(self, resume=False):
        if self.report.get('seed_completed'):
            return
        if not resume:
            self.call('form_create_project', dict(name='FIELD / Twelve paper studies', template='blank'))
            self.report['project_id'] = self.call('form_get_project')['id']
        self.call('form_set_view', dict(view='canvas'))
        for index,(file,label,texture,stock_color,ink,position) in enumerate(CASES, 1):
            key=f'{index:02d}'
            definition=json.loads((ROOT/'examples/paper-packaging'/file).read_text())
            row=next((r for r in self.report['cases'] if r['case']==key),None)
            if row and row.get('inspection'):
                continue
            if row:
                made=self.call('form_construction',dict(command='inspect',object_id=row['object_id']))
                row['finishes']=[]
            else:
                made=self.call('form_construction', dict(command='create',definition=definition,
                               name=key+' · '+label,position=position))
                row=dict(case=key,name=label,object_id=made['object_id'],definition_file=file,
                         expected_panels=len(made['net']['panels']),position=position,finishes=[])
                self.report['cases'].append(row)
            object_id=row['object_id'];self.save()
            values={p['name']:p['value'] for p in definition['parameters']}
            caliper=values['stock']
            profile=dict(texture=texture,color=stock_color,roughness=.94 if texture!='coated' else .34,
                         textureScaleMM=1.4 if texture=='cotton' else 1.1,
                         textureDepthMM=.025 if texture in ['cotton','recycled','linen'] else .008,opacity=1)
            stock=dict(name='FIELD '+texture+' / prototype',thicknessMM=caliper,profile=profile,
                       grain='parallelHeight',verified=False,notes='Visual prototype stock; verify caliper, grain, creases and print with a physical sample.')
            if key=='09':
                stock['plies']=[dict(id=stable('09-back-ply'),name='Forest back',color='#223D35',thicknessMM=caliper/2,
                                     profile=dict(profile,color='#223D35')),
                                dict(id=stable('09-front-ply'),name='Cotton front',color=stock_color,thicknessMM=caliper/2,profile=profile)]
            if key=='04':
                stock['plies']=[dict(id=stable('04-board'),name='Board core',color='#B49D7A',thicknessMM=caliper-.2),
                                dict(id=stable('04-wrap'),name='Warm wrap',color=stock_color,thicknessMM=.2,profile=profile)]
            if key=='05':
                stock['plies']=[dict(id=stable('05-lining'),name='Laid lining',color='#EDE6D5',thicknessMM=.2,
                                     profile=dict(profile,texture='laid',color='#EDE6D5')),
                                dict(id=stable('05-board'),name='Archival board / prototype',color='#B3A38A',thicknessMM=caliper-.4),
                                dict(id=stable('05-cover'),name='Linen cover',color=stock_color,thicknessMM=.2,profile=profile)]
            self.call('form_paper',dict(command='configure',object_id=object_id,stock=stock))
            self.clear_art(object_id)
            main={'04':'lid-floor','05':'front-cover','11':'front'}.get(key,'front')
            chosen=[]
            for p in made['net']['panels']:
                if p['id'] in {main,'back','base-front'} and p['role'] not in ['glue','dust']:
                    ids=self.add_panel(object_id,p,label,key,ink)
                    if p['id']==main: row['primary_artwork']=ids; chosen=list(ids.values())
            if key in ['03','06','07','08','09','10','11','12']:
                inside=self.call('form_paper',dict(command='ensure_inside',object_id=object_id))
                row['inside_source_id']=inside['inside_source_id'];self.clear_art(inside['inside_source_id'])
                p=next(p for p in made['net']['panels'] if p['id']==main)
                row['inside_artwork']=self.add_panel(object_id,p,label,key,'#DBD9C6' if key=='09' else ink,'inside')
            ids=row.get('primary_artwork',{})
            if ids:
                if key in ['02','04','08','09','11','12']:
                    row['finishes'].append(self.finish(object_id,key,'Warm metallic mark','foil',[ids['brand']],color='#C49B48',roughness=.18,metallic=1))
                if key in ['05','08','12'] and 'seal' in ids:
                    row['finishes'].append(self.finish(object_id,key,'Blind raised seal','emboss',[ids['seal']],heightMM=.09,roughness=.92))
                if key=='09':
                    row['finishes'].append(self.finish(object_id,key,'Blind studio name','deboss',[ids['title']],depthMM=.08))
                if key=='12':
                    row['finishes'].append(self.finish(object_id,key,'Pressed invitation wording','letterpress',[ids['title'],ids['copy']],color=ink,depthMM=.10))
                if key in ['01','03','10']:
                    row['finishes'].append(self.finish(object_id,key,'Single color print','screenPrint',[ids['title']],color=ink,heightMM=.012,roughness=.82))
            if key in ['05','07','11']:
                self.call('form_update_object',dict(object_id=object_id,rotation=-90 if key=='11' else 180))
            if key in ['03','04','05','07','11']:

                self.call('form_update_object',dict(object_id=object_id,parameters={'opening':65 if key=='07' else 100 if key in ['04','05'] else 45}))
            row['inspection']=self.call('form_paper',dict(command='inspect',object_id=object_id))
            self.save()
        if not self.report['cases'][3].get('contents_object_id'):self.add_contents()
        if not self.report['cases'][4].get('contents_object_id'):self.add_archive_contents()
        if not self.report['cases'][6].get('liner_object_id'):self.add_liner()
        if not self.report['cases'][2].get('template'):self.template_fixture()
        self.call('form_add_note',dict(kind='decision',text='Twelve-case paper and packaging laboratory. All stocks and finish depths are prototype assumptions; verify fit, press tooling, adhesive and registration physically. See docs/paper-packaging-validation-plan.md.'))
        self.call('form_set_view',dict(view='table'))
        self.call('form_set_view',dict(view='fit'))
        self.report['seed_completed']=True
        self.save()

    def add_contents(self):
        row=self.report['cases'][3];position=row['position']
        made=self.call('form_add_object',dict(recipe_id='box',name='04 · Modeled contents / 56 × 20 × 44 mm',
                  parameters=dict(width=56,height=20,depth=44,corner=4),
                  position=[position[0],position[1]+1.8,position[2]],material_id='graphite'))
        project=self.call('form_get_project')
        target=next(o for o in project['objects'] if o['name']=='04 · Modeled contents / 56 × 20 × 44 mm')
        row['contents_object_id']=target['id']
        row['contents_clearance_mm']=0
        row['contents_fit']=self.call('form_paper',dict(command='preflight',object_id=row['object_id'],
                      contents_object_id=target['id'],interior_id='base-interior',clearance_mm=0))

    def add_archive_contents(self):
        row=self.report['cases'][4]
        inspection=self.call('form_construction',dict(command='inspect',object_id=row['object_id']))
        interior=next(i for i in inspection['interiors'] if i['id']=='tray-interior')
        axes=[interior[k] for k in ['uAxis','vAxis','wAxis']]
        size=interior['sizeMM'];origin=interior['origin']
        assert abs(axes[1]['y']-1)<1e-8, 'Archive contents require the declared upright cavity'
        local=[origin[k]+axes[0][k]*size['x']/2+axes[1][k]*4+axes[2][k]*size['z']/2 for k in ['x','y','z']]
        position=[row['position'][i]+local[i] for i in range(3)]
        name='05 · Modeled archival contents'
        self.call('form_add_object',dict(recipe_id='box',name=name,parameters=dict(width=size['x']-20,height=30,depth=size['z']-20,corner=.5),position=position,material_id='paper-superfine'))
        target=next(o for o in self.call('form_get_project')['objects'] if o['name']==name)
        row['contents_object_id']=target['id']
        row['contents_fit']=self.call('form_paper',dict(command='preflight',object_id=row['object_id'],contents_object_id=target['id'],interior_id='tray-interior',clearance_mm=1))

    def add_liner(self):
        row=self.report['cases'][6];x,y,z=row['position']
        d=json.loads((ROOT/'examples/paper-packaging/07-liner-component.json').read_text())
        made=self.call('form_construction',dict(command='create',definition=d,
                  name='07 · Separate patterned envelope liner',position=[x,y+3,z+.5]))
        liner=made['object_id'];row['liner_object_id']=liner
        self.call('form_paper',dict(command='configure',object_id=liner,stock=dict(name='Loose vellum liner / prototype',
                  profile=dict(texture='vellum',color='#E3DFC9',roughness=.7,textureScaleMM=.7,textureDepthMM=.006,opacity=.72))))
        self.call('form_update_object',dict(object_id=liner,rotation=180))
        self.clear_art(liner)
        source=self.call('form_paper',dict(command='ensure_inside',object_id=liner))['inside_source_id']
        self.clear_art(source)
        pattern=[]
        for r in range(8):
            for c in range(10):
                pattern.append(element('star',f'07-liner-motif-{r}-{c}',8+c*17,8+r*15,5,5,'#56735F',sides=6,starInset=.65))
        self.call('form_edit_artwork',dict(command='add',object_id=liner,elements=pattern,
                  physical_frame=dict(surface_id='front',side='inside')))

    def template_fixture(self):
        row=self.report['cases'][2];net=row['inspection']['net'];w,h=net['size']['x'],net['size']['y']
        lines=''.join(f'<path d="M{e["start"]["x"]},{e["start"]["y"]} L{e["end"]["x"]},{e["end"]["y"]}"/>' for e in net['cutEdges'])
        folds=''.join(f'<path d="M{e["start"]["x"]},{e["start"]["y"]} L{e["end"]["x"]},{e["end"]["y"]}"/>' for e in net['folds'])
        source=f'<svg xmlns="http://www.w3.org/2000/svg" width="{w+20}mm" height="{h+20}mm" viewBox="-10 -10 {w+20} {h+20}"><g id="supplier-cut" fill="none" stroke="red">{lines}</g><g id="supplier-crease" fill="none" stroke="blue">{folds}</g><g id="supplier-notes"><text x="0" y="-3" font-size="2">LAB controlled supplier fixture · REV A · actual size</text></g></svg>'
        path=self.output/'supplier-fixture.svg';path.write_text(source)
        row['template']=self.call('form_paper',dict(command='template_attach',object_id=row['object_id'],path=str(path),
                  vendor='LAB validation fixture (not a commercial supplier)',revision='A',
                  instructions='Return artwork separately, registered to the retained source in actual millimeters. Retain original cut and crease IDs. Do not print instruction text.',
                  technical_mapping=[dict(elementID='supplier-cut',kind='cut'),dict(elementID='supplier-crease',kind='crease'),dict(elementID='supplier-notes',kind='instructions')],
                  canonical_to_template=dict(a=1,b=0,c=0,d=1,tx=0,ty=0)))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--socket',default='/tmp/lab-paper-packaging-twelve.sock')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/validation/paper-packaging/twelve-round-one')
    parser.add_argument('--launch',action='store_true')
    parser.add_argument('--resume',action='store_true')
    options=parser.parse_args();session=Session(options.app,options.socket,options.output)
    if options.resume:session.report=json.loads((session.output/'report.json').read_text())
    if options.launch:session.launch()
    if options.resume:session.call('form_open_project',dict(project_id=session.report['project_id']))
    session.seed(resume=options.resume);print(json.dumps(dict(project_id=session.report['project_id'],cases=len(session.report['cases']),report=str(session.output/'report.json'))))


if __name__=='__main__':
    main()
