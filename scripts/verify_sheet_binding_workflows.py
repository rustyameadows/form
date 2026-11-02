#!/usr/bin/env python3
"""Native disposable physical proof for one 52-page source and both bindings.

Runs only against an explicitly identified, already-running ordinary LAB. Uses
public MCP commands for every project/scene mutation; no app launch, model API,
private file editing or manufacturing command. This is a labelled physical test
specimen, not the finished visual magazine or a production-ink certification.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import uuid

from verify_publication_workflows import PublicationProof, art, digest, element, require
from magazine_physical_examples import create_magazine_physical
from render_paper_packaging import camera


def thickness(stock):
    return sum(p['thicknessMM'] for p in stock.get('plies') or []) or stock['thicknessMM']


def source_hash(project):
    return digest({k:project.get(k) for k in ('objects','publications','textStories','textStyles','recipes','swatches')})


def physical_points(definition, pose, placement=(0, 0, 0)):
    """Independent camera envelope derived from declared caliper and arc poses."""
    w, h = 215.9, 279.4
    parents = definition['parentSheets']
    calipers = [thickness(p['stock']) for p in parents]
    calipers += list(reversed(calipers))
    total, accumulated = sum(calipers), 0
    angle = math.radians(pose['openingDegrees'])
    active = pose['activeSpread'] if angle else 0
    side = pose.get('bindingStyle', definition['binding']['style']) == 'sideStaple'
    points = []
    for index, caliper in enumerate(calipers):
        turned = index < active
        offset = total-accumulated-caliper/2 if side or not turned else -(accumulated+caliper/2)
        accumulated += caliper
        for sample in range(65):
            x = w*sample/64
            for z in (-caliper/2, caliper/2):
                if side and angle:
                    pinned = definition['binding']['edgeInsetMM'] + max(1, 2*definition['binding']['wireDiameterMM'])
                    theta = angle if turned else 0
                    depth = max(0, total-caliper/2-offset)
                    radius = definition['binding']['flexWidthMM']/theta+depth if theta else 0
                    length = radius*theta if theta else definition['binding']['flexWidthMM']
                    if x <= pinned:
                        px, py = x, offset+z
                    elif theta and x < pinned+length:
                        a = (x-pinned)/radius
                        px, py = pinned+(radius-z)*math.sin(a), offset+radius*(1-math.cos(a))+z*math.cos(a)
                    else:
                        a = theta
                        start_x = pinned+radius*math.sin(a) if theta else pinned+length
                        start_y = offset+radius*(1-math.cos(a))
                        tail = x-pinned-length
                        px, py = start_x+tail*math.cos(a)-z*math.sin(a), start_y+tail*math.sin(a)+z*math.cos(a)
                else:
                    a = angle if turned else 0
                    px = x*math.cos(a)-(offset+z)*math.sin(a)
                    py = (total*(1+math.cos(angle))/2 if turned else 0)+x*math.sin(a)+(offset+z)*math.cos(a)
                for page_y in (-h/2, h/2):
                    points.append([placement[0]+px, placement[1]+py, placement[2]+page_y])
    return points


class BindingProof(PublicationProof):
    def __init__(self, args):
        require(not (args.output.resolve()/'binding-report.json').exists(), 'Choose a fresh binding evidence folder.')
        super().__init__(args)

    def save(self):
        (self.output/'binding-report.json').write_text(json.dumps(self.report, indent=2)+'\n')

    def save_scene(self, name, instances, points, outward=(.18, 1, .35), size=(2000, 1600)):
        scene=self.call('form_studio_scene',command='create',name=name)
        scene.update(instances=instances,camera=camera(points,outward,margin=1.14,aspect=size[0]/size[1]),
                     pixels=dict(zip(('width','height'),size)),lighting='soft-side-v1',surface='Daylight')
        return self.call('form_studio_scene',command='save',scene=scene)

    def instance(self, source, name, pose, position=(0,0,0)):
        return dict(id=str(uuid.uuid4()).upper(),name=name,sourceObjectID=source,visible=True,
                    positionMM=dict(zip(('x','y','z'),position)),rotationDegrees=0,sheetPose=copy.deepcopy(pose))

    def capture(self, scene, label):
        destination=self.output/'renders'/(label+'.render');destination.parent.mkdir(parents=True,exist_ok=True)
        result=self.call('form_export',format='png',scene_id=scene['id'],path=str(destination))
        path=Path(result['path']);data=path.read_bytes()
        dimensions=struct.unpack('>II',data[16:24])
        require(data[:8]==b'\x89PNG\r\n\x1a\n' and dimensions==(scene['pixels']['width'],scene['pixels']['height']), 'Native capture must retain the exact requested output pixels.')
        self.report['renders'].append(dict(label=label,path=str(path),sha256=hashlib.sha256(data).hexdigest(),scene=scene))
        self.save()

    def run(self):
        require(not (self.output/'binding-report-complete.json').exists(),'Use a fresh physical evidence folder.')
        self.call('form_create_project',name='Physical binding / 52-page labelled specimen',template='blank')
        self.report['project_id']=self.project()['id']
        publication=self.call('form_publication',command='create',name='52-page physical specimen',page_ids=[],
            layout=dict(facingPages=True,firstPageSide='recto'))['publication_id']
        pages=self.call('form_publication',command='create_pages',publication_id=publication,count=52,width=215.9,height=279.4)['page_ids']
        for number,identifier in enumerate(pages,1):
            elements=[element('text',f'binding-specimen-heading-{number}',18,16,180,20,'#111111',f'PHYSICAL STOCK / PAGE {number:02}',points=18),
                element('text',f'binding-specimen-number-{number}',18,46,175,45,'#111111',f'{number:02}',points=72),
                element('rectangle',f'binding-specimen-left-{number}',18,115,8,20,'#111111'),
                element('ellipse',f'binding-specimen-right-{number}',184,115,14,14,'#111111'),
                element('text',f'binding-specimen-footer-{number}',18,240,180,20,'#111111','8.5 × 11 in / canonical editable source',points=10)]
            self.set_art(identifier,art(elements,transparent=True,position=((number-1)%8*260,(number-1)//8*340)))
        physical=create_magazine_physical(self.call,publication)
        self.report['physical']=physical
        baseline=source_hash(self.project());source=physical['object_id'];definition=physical['definition']
        native=self.object(source)['sheetAssembly'];native_parents=native.get('parentSheets') or []
        self.check('52 canonical source pages, 13 persisted physical parent sheets',len(pages)==52 and len(native_parents)==13)
        self.check('Native source preserves declared nesting and print intent',
            [{k:p[k] for k in ('id','frontPageIDs','backPageIDs','printIntent')} for p in native_parents]
            ==[{k:p[k] for k in ('id','frontPageIDs','backPageIDs','printIntent')} for p in definition['parentSheets']])
        self.check('Native source retains the declared physical binding',native.get('binding')==definition['binding'])
        self.check('Persisted folded stock caliper is 2.96 mm',abs(sum(thickness(p['stock']) for p in native_parents)*2-2.96)<1e-9)
        scenes=[]
        for style in ('saddleStitch','sideStaple'):
            for label,opening,active in [('closed',0,0),('open90',90,13),('open180',180,13)]:
                pose=dict(openingDegrees=opening,activeSpread=active,bendMM=0,bindingStyle=style)
                scene=self.save_scene(style+' / '+label,[self.instance(source,style+' / '+label,pose)],physical_points(definition,pose))
                scenes.append(scene);self.capture(scene,style+'-'+label)
            pose=dict(openingDegrees=180,activeSpread=13,bendMM=0,bindingStyle=style)
            staple_z=50-279.4/2
            detail=[[x,y,z] for x in (-15,45) for y in (-1,20) for z in (staple_z-18,staple_z+18)]
            scene=self.save_scene(style+' / fastener detail',[self.instance(source,style+' / fastener detail',pose)],detail,outward=(.15,.75,.65))
            scenes.append(scene);self.capture(scene,style+'-fastener-detail')
        instances=[];points=[]
        for index,(opening,active) in enumerate(((115,4),(150,13),(175,22))):
            pose=dict(openingDegrees=opening,activeSpread=active,bendMM=0,bindingStyle='saddleStitch')
            position=(index*500,0,0)
            instances.append(self.instance(source,f'Independent spread {active}',pose,position))
            points+=physical_points(definition,pose,position)
        scene=self.save_scene('One source / three independent reader spreads',instances,points,size=(3000,1600))
        scenes.append(scene);self.capture(scene,'three-independent-spreads')
        self.check('Every scene pose/binding preserves one exact canonical source',source_hash(self.project())==baseline)
        before=copy.deepcopy(scene);changed=copy.deepcopy(scene);changed['instances'][0]['sheetPose']['openingDegrees']=65
        self.call('form_studio_scene',command='save',scene=changed)
        self.call('form_undo')
        self.check('One Undo restores the complete scene pose independently',self.call('form_studio_scene',command='get',scene_id=scene['id'])==before)
        self.check('Scene Undo cannot rewrite canonical page or parent stock',source_hash(self.project())==baseline)
        self.call('form_open_project',project_id=self.report['project_id'])
        self.check('Save/reopen retains all source stock and independent poses',source_hash(self.project())==baseline and self.call('form_studio_scene',command='get',scene_id=scene['id'])==before)
        self.report.update(passed=True,scene_ids=[s['id'] for s in scenes],visual_acceptance='Requires inspection of actual native renders; automation does not certify appearance.',production_ink_acceptance='Labelled physical prototype only. Original issue runner separately proves actual process-K and mixed-color PDF output.')
        self.save();(self.output/'binding-report-complete.json').write_text(json.dumps(dict(project_id=self.report['project_id'],renders=len(self.report['renders'])),indent=2)+'\n')
        print(json.dumps(dict(project_id=self.report['project_id'],report=str(self.output/'binding-report.json')),indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True);parser.add_argument('--socket',required=True)
    parser.add_argument('--library',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
    proof=BindingProof(parser.parse_args())
    try:proof.run()
    except Exception as error:
        proof.report.update(passed=False,error=str(error));proof.save();raise


if __name__=='__main__':main()
