#!/usr/bin/env python3
"""Author two acceptance addenda through the ONE already-running ordinary LAB.

Read an existing twelve-study report; preserve its cases and all original objects.
Only project data and saved presentation scenes are added. No app is launched,
no project files are edited directly, and no printer/device is contacted.
"""
import argparse
import copy
import json
from pathlib import Path
import struct
import uuid

from validate_paper_packaging import ROOT, Session, element, stable
from render_paper_packaging import camera, geometry
from check_paper_packaging import require, sha_file, svg_extent, close_values, xml_by_id, drawable_count

PALETTE = {'forest': '#214D46', 'clay': '#C65D3B', 'ochre': '#B69B53'}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False)+'\n')


def objects(project):
    return {o['id']: o for o in project['objects']}


def poster_artwork():
    """Ordinary authored vector elements, not an application object generator."""
    layers = {name: [] for name in PALETTE}
    def add(ink, kind, name, x, y, w, h, text='', size=14, **kwargs):
        layers[ink].append(element(kind, '13-poster-'+name, x,y,w,h,PALETTE[ink],text,size,**kwargs))
    add('forest','text','edition',22,23,250,8,'FIELD / PRINT LABORATORY                         NO. 013',10)
    # Font sizes are points; source frames are mm. Native CoreText measured
    # this face at124pt as a53.4mm typographic line.70mm retains ascent,
    # descent and leading; the earlier35/41mm frames silently overset.
    add('forest','text','common',20,40,257,70,'COMMON',124)
    add('forest','text','ground',20,99,257,70,'GROUND',124)
    add('clay','ellipse','sun',162,158,104,104)
    add('ochre','ellipse','disc',45,183,122,122)
    add('forest','rectangle','horizon',20,274,257,7)
    for i in range(6):
        add('clay','rectangle','stripe-'+str(i),20,305+i*5,257,.8)
    add('forest','text','footer',21,355,252,19,'THREE INKS. ONE SHARED GROUND.\nA screen-print study on uncoated recycled paper.',13)
    add('ochre','text','colophon',21,389,252,7,'297 × 420 MM  /  REGISTERED EDITABLE PLATES  /  VISUAL PROTOTYPE',7)
    for ink in PALETTE:
        for i,(x,y) in enumerate([(10,10),(287,10),(10,410),(287,410)]):
            add(ink,'rectangle',f'{ink}-registration-{i}-h',x-2.5,y-.2,5,.4)
            add(ink,'rectangle',f'{ink}-registration-{i}-v',x-.2,y-2.5,.4,5)
    return layers


class Addendum:
    def __init__(self, args):
        self.args=args;self.seed=json.loads(args.seed_report.read_text())
        require(len(self.seed.get('cases',[]))==12 and self.seed.get('project_id'),'Complete twelve-study report required')
        self.seed_hash=sha_file(args.seed_report)
        self.session=Session(args.app,args.socket,args.output)
        self.path=args.output/'acceptance-addendum.json'
        self.report=json.loads(self.path.read_text()) if self.path.exists() else {'project_id':self.seed['project_id'],'additional_cases':[]}
        require(self.report['project_id']==self.seed['project_id'],'Addendum belongs to another project')
        self.rows={r['case']:r for r in self.report['additional_cases']}
        initial=self.project();self.original=objects(initial)
        require(all(r['object_id'] in self.original for r in self.seed['cases']),'A seeded paper study is missing')
        prior=self.report.get('original_objects')
        if prior is not None:
            require(all(self.original.get(k)==v for k,v in prior.items()),'An original study changed since this addendum began')
        else:self.report['original_objects']=copy.deepcopy(self.original)
        self.protected=self.report['original_objects'];self.save()
    def save(self):write(self.path,self.report)
    def call(self,name,args=None):return self.session.call(name,args)
    def project(self):
        p=self.call('form_get_project');require(p['id']==self.seed['project_id'],'Open the supplied twelve-study project in LAB before running this script');return p
    def guard_originals(self):
        current=objects(self.project())
        require(all(current.get(k)==v for k,v in self.protected.items()),'An original project object was changed')
        require(sha_file(self.args.seed_report)==self.seed_hash,'The twelve-case seed report was rewritten')
    def sheet(self,key,filename,name,position):
        row=self.rows.get(key)
        if row:return row
        made=self.call('form_construction',dict(command='create',definition=json.loads((ROOT/'examples/paper-packaging'/filename).read_text()),name=name,position=position))
        row={'case':key,'object_id':made['object_id'],'name':name,'definition_file':filename}
        self.report['additional_cases'].append(row);self.rows[key]=row;self.save();return row
    def add(self,identifier,values,side='outside'):
        self.call('form_edit_artwork',dict(command='add',object_id=identifier,elements=values,physical_frame=dict(surface_id='front',side=side)))
    def finish(self,identifier,key,kind,ids,color=None,**other):
        value=dict(id=stable(key),name=key,kind=kind,side='outside',elementIDs=ids,**other)
        if color is not None:value['color']=color
        self.call('form_paper',dict(command='set_finish',object_id=identifier,finish=value));return value
    def author(self):
        poster=self.sheet('13','13-screen-printed-poster.json','13 · Common ground / three-color screen print',[-470,0,860])
        if not poster.get('authored'):
            self.call('form_paper',dict(command='configure',object_id=poster['object_id'],stock=dict(name='Warm recycled print paper / visual prototype',thicknessMM=.5,grain='parallelHeight',profile=dict(texture='recycled',color='#E7DFC9',roughness=.94,textureScaleMM=1.5,textureDepthMM=.035,opacity=1),verified=False,notes='Three prototype ink plates; press registration, substrate and mesh count require physical proof.')))
            self.session.clear_art(poster['object_id']);inks=poster_artwork()
            self.add(poster['object_id'],[e for values in inks.values() for e in values])
            poster['finishes']=[self.finish(poster['object_id'],'13 / '+name+' screen', 'screenPrint',[e['id'] for e in values],PALETTE[name],heightMM=.014,roughness=.8) for name,values in inks.items()]
            poster['registration']={name:[{k:e[k] for k in ['x','y','width','height']} for e in values if '-registration-' in e['name']] for name,values in inks.items()}
            require(len({json.dumps(v,sort_keys=True) for v in poster['registration'].values()})==1,'Ink registration marks are not coincident')
            poster['authored']=True;self.save()
        if poster.get('typography_revision')!=2:
            # Portable repair of existing addenda: replace the same editable
            # source IDs, retaining finish targets and all twelve baseline cases.
            titles=[e for e in poster_artwork()['forest'] if e['name'] in ['13-poster-common','13-poster-ground']]
            self.call('form_edit_artwork',dict(command='replace',object_id=poster['object_id'],elements=titles,physical_frame=dict(surface_id='front',side='outside')))
            poster['typography_revision']=2;self.save()
        reply=self.sheet('14','14-suite-response-card.json','14 · Gather / response card',[810,0,860])
        if not reply.get('authored'):
            self.call('form_paper',dict(command='configure',object_id=reply['object_id'],stock=dict(name='Gather cotton response / prototype',thicknessMM=.4,grain='parallelHeight',profile=dict(texture='cotton',color='#EEE5D0',roughness=.92,textureScaleMM=1.4,textureDepthMM=.025,opacity=1),verified=False)))
            self.session.clear_art(reply['object_id'])
            front=[element('text','14-reply-heading',9,12,87,12,'#34443A','Kindly reply',22),element('text','14-reply-date',9,27,87,8,'#34443A','BY THE FIRST OF JUNE',8),element('rectangle','14-reply-rule',9,42,87,.35,'#B69B53'),element('text','14-reply-choice',9,49,87,18,'#34443A','Your name __________________\nAccepts with pleasure / Regrets',8)]
            self.add(reply['object_id'],front)
            reply['finishes']=[self.finish(reply['object_id'],'14 / response ink','flatInk',[e['id'] for e in front if e['kind']=='text'],'#34443A')]
            inside=self.call('form_paper',dict(command='ensure_inside',object_id=reply['object_id']))['inside_source_id']
            self.session.clear_art(inside);reply['inside_source_id']=inside
            self.add(reply['object_id'],[element('text','14-reply-reverse',9,13,87,22,'#34443A','GATHER\nA celebration of ordinary beauty.',10)],side='inside')
            reply['authored']=True;self.save()
        envelope=self.seed['cases'][6];invite=self.seed['cases'][11]
        require(envelope.get('liner_object_id'),'The original invitation envelope has no real liner component')
        p=objects(self.project());finishes=p[invite['object_id']]['paperConstruction'].get('finishes',[])
        require({'letterpress','emboss','foil'}<={f['kind'] for f in finishes if f.get('enabled',True)},'Invitation suite must retain ink, blind relief and foil assignments')
        # This presentation needs an unprinted inside beneath translucent
        # vellum. The baseline envelope intentionally has large inside type;
        # copying only its ordinary construction/outside art to a fresh owner
        # gives this suite an independent clean inside without altering case07.
        baseline=p[envelope['object_id']]
        if not reply.get('suite_envelope_id'):
            made=self.call('form_construction',dict(command='create',definition=copy.deepcopy(baseline['paperConstruction']['authored']),name='14 · Gather / clean-lined suite envelope',position=[810,0,660]))
            reply['suite_envelope_id']=made['object_id'];self.save()
        suite_envelope=reply['suite_envelope_id']
        if reply.get('suite_envelope_revision')!=1:
            self.call('form_paper',dict(command='configure',object_id=suite_envelope,stock=copy.deepcopy(baseline['paperConstruction']['stock'])))
            self.call('form_construction',dict(command='parameter',object_id=suite_envelope,values=copy.deepcopy(baseline['parameters'])))
            outside=copy.deepcopy(baseline['artwork'])
            identities={e['id']:stable('14-suite-envelope-'+e['id']) for e in outside['elements']}
            for item in outside['elements']:
                item['id']=identities[item['id']]
                for field in ['parentID','clipID']:
                    if item.get(field) in identities:item[field]=identities[item[field]]
            self.call('form_set_artwork',dict(object_id=suite_envelope,artwork=outside))
            inside=self.call('form_paper',dict(command='ensure_inside',object_id=suite_envelope))['inside_source_id']
            self.session.clear_art(inside)
            reply.update(suite_envelope_inside_source_id=inside,suite_envelope_revision=1,baseline_envelope_id=envelope['object_id']);self.save()
        latest=objects(self.project())
        require(latest[suite_envelope]['paperConstruction']['insideArtworkSourceID']!=baseline['paperConstruction']['insideArtworkSourceID'],'Suite envelope must own independent inside artwork')
        require(latest[reply['suite_envelope_inside_source_id']]['artwork']['elements']==[],'Suite lining must not hide cropped prototype inside typography')
        reply['suite']={'envelope':suite_envelope,'liner':envelope['liner_object_id'],'invitation':invite['object_id'],'response':reply['object_id']}

        reply['fit_assumption']={'invitation_orientation_in_envelope_degrees':90,'body_mm':[190,140],'invitation_mm':[127,178],'clearance_after_in_plane_rotation_mm':[12,13],'manufacturing_verified':False}
        self.guard_originals();self.save()
    def undo_checks(self,row):
        identifier=row['object_id'];before=objects(self.project());width=before[identifier]['parameters']['width']
        self.call('form_construction',dict(command='parameter',object_id=identifier,values=dict(width=width+8)))
        changed=objects(self.project());require(changed[identifier]['parameters']['width']==width+8,'Width did not regenerate')
        require(changed[identifier]['artwork']==before[identifier]['artwork'],'Dimension edit stretched or rewrote artwork')
        self.call('form_undo');require(objects(self.project())==before,'Dimension Undo did not restore source')
        self.call('form_redo');require(objects(self.project())==changed,'Dimension Redo did not restore edit')
        self.call('form_undo');require(objects(self.project())==before,'Dimension edit not restored')
        finish=row['finishes'][0];edited=copy.deepcopy(finish);edited['color']='#7C4031'
        self.call('form_paper',dict(command='set_finish',object_id=identifier,finish=edited))
        changed=objects(self.project());require(changed[identifier]['paperConstruction']['finishes']!=before[identifier]['paperConstruction']['finishes'],'Ink edit did not change finish')
        require(changed[identifier]['artwork']==before[identifier]['artwork'],'Ink edit rewrote canonical art')
        self.call('form_undo');require(objects(self.project())==before,'Ink Undo did not restore source')
        self.call('form_redo');require(objects(self.project())==changed,'Ink Redo did not restore edit')
        self.call('form_undo');require(objects(self.project())==before,'Ink edit not restored')
        self.guard_originals();return {'dimension_undo_redo_exact':True,'finish_undo_redo_exact':True,'canonical_artwork_preserved':True}
    def packet(self,row):
        inspected=self.call('form_construction',dict(command='inspect',object_id=row['object_id']));size=inspected['net']['size']
        folder=self.args.output/(row['case']+'-handoff-'+uuid.uuid4().hex[:8]+'.packet')
        self.call('form_paper',dict(command='export',object_id=row['object_id'],format='packet',path=str(folder),bleed_mm=3,sheet_width=size['x']+40,sheet_height=size['y']+40,margin=10,count=1,handoff='separate'))
        record=json.loads((folder/'production.json').read_text());roots={}
        require(record['object_id']==row['object_id'] and record['hardware_commands']==[],'Packet source/contact metadata differs')
        for name,digest in record['artifact_sha256'].items():require(sha_file(folder/name)==digest,'Changed packet bytes: '+name)
        expected=[size['x']+6,size['y']+6];box=[-3,-3]+expected
        names=['outside-artwork.svg','cut-crease.svg']+[p['file'] for p in record['finishing_plates']]
        if row.get('inside_source_id'):names.append('inside-artwork.svg')
        for name in names:
            root,extent,viewbox=svg_extent(folder/name);close_values(extent,expected,name+' physical extent');close_values(viewbox,box,name+' registration');roots[name]=root
        for plate in record['finishing_plates']:
            artwork=xml_by_id(roots[plate['file']],'artwork');require(artwork is not None and drawable_count(artwork)>0,'Empty finish plate')
            for identifier in plate['assignment']['elementIDs']:require(xml_by_id(artwork,'layer-'+identifier.upper()) is not None,'Finish lost editable source identity')
        if row.get('inside_source_id'):
            require(xml_by_id(roots['inside-artwork.svg'],'layer-'+stable('14-reply-reverse').upper()) is not None,'Response reverse lost its independent source artwork')
        if row['case']=='13':
            # A source text record alone is insufficient: require actual outlined
            # glyph output per heading, which catches silent frame overset.
            for name in ['13-poster-common','13-poster-ground']:
                heading=xml_by_id(roots['outside-artwork.svg'],'layer-'+stable(name).upper())
                require(heading is not None and drawable_count(heading)>0,'Poster heading has no rendered glyphs: '+name)
            require(len(record['finishing_plates'])==3,'Poster needs three distinct screen-print plates')
            require({p['assignment']['color'] for p in record['finishing_plates']}==set(PALETTE.values()),'Poster ink palette changed')
        return {'path':str(folder),'plate_count':len(record['finishing_plates']),'registered_extent_mm':expected,'artifact_hashes_verified':len(record['artifact_sha256'])}
    def scene(self,name,placements,outward,lighting='soft-side-v1',detail=None):
        by_id=objects(self.project());points=[];instances=[]
        for identifier,position,rotation in placements:
            obj=copy.deepcopy(by_id[identifier]);obj['position']=dict(zip(['x','y','z'],position));obj['rotation']=rotation
            inspected=self.call('form_construction',dict(command='inspect',object_id=identifier))
            vertices,_=geometry(inspected,obj);points+=vertices
            instances.append(dict(id=stable('acceptance-scene-'+name+'-'+identifier),sourceObjectID=identifier,name=obj['name'],visible=True,positionMM=obj['position'],rotationDegrees=rotation))
        if detail:points=detail
        prior=next((s for s in self.call('form_studio_scene',dict(command='list')) if s['name']==name),None)
        scene=prior or self.call('form_studio_scene',dict(command='create',name=name))
        scene.update(instances=instances,camera=camera(points,outward,aspect=1.25),pixels=dict(width=2000,height=1600),lighting=lighting,surface='Daylight')
        saved=self.call('form_studio_scene',dict(command='save',scene=scene));self.guard_originals()
        result={'name':name,'scene_id':saved['id'],'source_ids':[p[0] for p in placements],'intentional_closeup':detail is not None}
        if self.args.render:
            folder=self.args.output/('render-'+str(len(self.report.get('renders',[])))+'-'+uuid.uuid4().hex[:8]+'.render')
            response=self.call('form_export',dict(format='png',scene_id=saved['id'],path=str(folder)))
            images=list(folder.rglob('*.png'));require(len(images)==1,'Native still did not contain one PNG')
            data=images[0].read_bytes();require(data[:8]==b'\x89PNG\r\n\x1a\n','Invalid rendered PNG')
            require(struct.unpack('>II',data[16:24])==(2000,1600),'Native output pixels differ')
            result.update(image=str(images[0]),sha256=sha_file(images[0]),response=response)
            if name=='13 / Common ground / three inks':
                from PIL import Image
                counts=dict.fromkeys(PALETTE,0)
                for r,g,b in Image.open(images[0]).convert('RGB').getdata():
                    if r>g*1.3 and r>b*1.5 and 35<r<240:counts['clay']+=1
                    if g>r*1.35 and g>b*1.04 and g>25:counts['forest']+=1
                    if r>g*1.05 and r<g*1.3 and g>b*1.35 and r>60:counts['ochre']+=1
                require(all(v>80 for v in counts.values()),'A declared poster ink is not visibly represented: '+str(counts));result['decoded_ink_pixel_populations']=counts
        self.report.setdefault('renders',[]).append(result);self.save();return result
    def run(self):
        self.author()
        for row in self.report['additional_cases']:
            row['checks']=self.undo_checks(row);row['packet']=self.packet(row);self.save()
        p=self.project();before=objects(p)
        self.call('form_open_project',dict(project_id=p['id']))
        require(objects(self.project())==before,'Reopen changed canonical objects')
        self.report['reopen_exact']=True
        poster=self.rows['13'];position=objects(self.project())[poster['object_id']]['position'];pos=[position[k] for k in ['x','y','z']]
        self.scene('13 / Common ground / three inks',[(poster['object_id'],pos,0)],[.05,1,.14])
        self.scene('13 / Common ground / paper and ink detail',[(poster['object_id'],pos,0)],[.14,.72,.6],lighting='rim-v1',detail=[[pos[0]+x,.25,pos[2]+z] for x in [-115,20] for z in [-155,-15]])
        suite=self.rows['14']['suite']
        placements=[(suite['envelope'],[0,0,0],180),(suite['liner'],[0,3,.5],180),(suite['invitation'],[-8,.6,125],-12),(suite['response'],[115,.3,52],14)]
        self.scene('14 / Gather / invitation suite',placements,[.3,1.05,1.15])
        self.scene('14 / Gather / printed and blind detail',placements,[.18,.65,1],lighting='rim-v1',detail=[[-80,.6,38],[70,.6,38],[-80,.6,210],[70,.6,210]])
        self.guard_originals();self.report['original_twelve_cases_unchanged']=True;self.report['status']='native_checks_passed_visual_review_pending' if self.args.render else 'source_checks_passed_native_renders_pending'
        self.report['visual_review']='Inspect actual whole/detail renders; palette counts and valid geometry alone do not establish visual quality.';self.save()
        print(json.dumps({k:self.report[k] for k in ['project_id','status','original_twelve_cases_unchanged','reopen_exact']}))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--socket',default='/tmp/form-501.sock')
    parser.add_argument('--seed-report',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--render',action='store_true',help='Export native whole/detail stills; Pillow is required for decoded ink checks.')
    args=parser.parse_args();args.output=args.output.resolve();args.output.mkdir(parents=True,exist_ok=True)
    worker=Addendum(args)
    try:worker.run()
    except Exception as error:
        worker.report.update(status='failed',error=repr(error));worker.save();raise


if __name__=='__main__':main()
