#!/usr/bin/env python3
"""Add editable optical diagnostics through the ordinary LAB MCP, then restore."""
import argparse
import json
from pathlib import Path
import time

from author_cycles_materials import Author, ROOT, SOURCE, element, protected_signature, sheet_definition, stable, stock


class Optics(Author):
    def material_value(self, identifier, name, color, roughness, metallic=0):
        value=dict(id=identifier,name=name,category='Surface',color=color,roughness=roughness,metallic=metallic,thickness=1,appearance=dict(ior=1.5))
        if any(m['id']==identifier for m in self.refresh()['materials']):
            self.call('form_material',dict(command='update',material_id=identifier,patch={k:v for k,v in value.items() if k!='id'}))
        else:self.call('form_material',dict(command='create',material=value))
        return identifier

    def box(self, name, position, size, material):
        found=self.object(name)
        if not found:
            found=self.call('form_add_object',dict(recipe_id='box',name=name,position=position,material_id=material,parameters=dict(zip(('width','height','depth'),size))|dict(corner=0)))
        self.call('form_update_object',dict(object_id=found['id'],position=position,material_id=material,parameters=dict(zip(('width','height','depth'),size))))
        return found['id']

    def sheet(self, name, position, size, caliper, material, vertical=False):
        found=self.object(name)
        if not found:
            definition=sheet_definition(name,size[0],size[1],caliper)
            if vertical:definition['components'][0]['rotationDegrees']=dict(x=0,y=0,z=0)
            result=self.call('form_construction',dict(command='create',name=name,definition=definition,position=position,material_id=material))
            found=next(o for o in self.refresh()['objects'] if o['id']==result['object_id'])
        self.call('form_update_object',dict(object_id=found['id'],position=position,material_id=material))
        return found['id']

    def artwork(self, owner, elements, background_opacity=0):
        self.call('form_set_artwork',dict(object_id=owner,artwork=dict(background='#FFFFFF',backgroundOpacity=background_opacity,bleed=0,elements=elements)))

    def reverse_art(self, owner):
        inside=self.call('form_paper',dict(command='ensure_inside',object_id=owner))['inside_source_id']
        # The source is registered in outside full-net coordinates. This is the
        # same inverse X reflection as PhysicalArtworkFrame.paper(inside:true):
        # readable from the actual underside, mirrored in front transmission.
        mirror=dict(a=-1,b=0,c=0,d=1,tx=100,ty=0)
        self.artwork(inside,[element('reverse/'+owner,'Reverse word','text',10,28,80,16,'#182F70',text='REVERSE',fontSize=12,affine=mirror),
                            element('reverse/'+owner,'Reverse block','rectangle',12,49,26,7,'#B7223B',affine=mirror),
                            element('reverse/'+owner,'Reverse registration','rectangle',68,12,14,8,'#182F70',affine=mirror)])
        return inside

    def settings(self, lights, environment=.12):
        return dict(renderer='cycles',device='automatic',samples=self.args.samples,previewSamples=64,noiseThreshold=.01,denoise=True,maxBounces=12,
                    exposure=0,environmentColor='#FFFFFF',environmentStrength=environment,areaLights=lights)

    def light(self, name, position, target, size, power):
        return dict(id=stable(name),positionMM=dict(zip(('x','y','z'),position)),targetMM=dict(zip(('x','y','z'),target)),
                    sizeMM=dict(x=size[0],y=size[1]),powerWatts=power,color='#FFFFFF',shape='rectangle')

    def shot(self, diagnostic, label, ids, camera, settings):
        name='Optics / '+diagnostic+' / '+label
        old=next((s for s in self.call('form_set_view',dict(view='studio',studio_command='list')) if s['name']==name),None)
        args=dict(view='studio',studio_command='update' if old else 'capture',name=name,camera=camera,reference_aspect=4/3,
                  width=getattr(self.args,'width',1200),height=getattr(self.args,'height',900),surface='Graphite',lighting='soft-side-v1',visibility=dict(mode='objects',objectIDs=ids),render_settings=settings)
        if old:args['shot_id']=old['id']
        saved=self.call('form_set_view',args)
        record=self.state.setdefault('diagnostics',{}).setdefault(diagnostic,dict(render_attempts=[]))
        attempt=1+sum(r['view']==label for r in record['render_attempts'])
        entry=dict(view=label,attempt=attempt,shot_id=saved['id'],object_ids=ids,state='starting',visual_acceptance='pending',build_identity=self.begin_author_run(),
                   requested_samples=self.args.samples,requested_pixels=dict(width=args['width'],height=args['height']))
        record['render_attempts'].append(entry);self.save()
        try:
            result=self.call('form_render',dict(command='start',project_id=self.state['project_id'],target='shot',shot_id=saved['id']))
            entry.update(result);self.save();deadline=time.monotonic()+1800
            while result['state'] in ('preparing','rendering'):
                if time.monotonic()>deadline:raise RuntimeError('Diagnostic render timed out')
                time.sleep(3);result=self.call('form_render',dict(command='status',job_id=result['job_id']));entry.update(result);self.save()
            if result['state']!='completed':raise RuntimeError(str(result.get('error')))
            entry.update(self.call('form_render',dict(command='result',job_id=result['job_id'])))
            entry['project_files']={key:'Exports/'+Path(entry[key]).parent.name+'/'+Path(entry[key]).name for key in ('png','exr','record')}
            self.save()
        except BaseException as error:
            if entry.get('job_id') and entry['state'] in ('preparing','rendering'):
                self.call('form_render',dict(command='cancel',job_id=entry['job_id']))
            entry.update(state='failed',failure=str(error));self.save();raise
        finally:
            evidence={key:entry[key] for key in ('view','attempt','shot_id','state','project_files','failure','visual_acceptance','build_identity') if key in entry}
            self.call('form_add_note',dict(kind='decision',text='Optical diagnostic evidence / '+diagnostic+'\n'+json.dumps(evidence,indent=2)))

    def vellum(self):
        case=next(c for c in self.corpus['cases'] if c['id']=='vellum')
        for variant in self.state['cases']['vellum']['variants']:
            for owner in variant[:-1]:self.reverse_art(owner)
        center=[1000,80,1000]
        owner=self.sheet('Vellum / raised backlight comparison',center,[100,70],case['thickness_mm'],'reference-vellum')
        self.call('form_paper',dict(command='configure',object_id=owner,stock=stock(case)))
        self.artwork(owner,[element('backlight','Front label','text',10,8,80,12,'#222222',text='FRONT',fontSize=9)])
        inside=self.reverse_art(owner)
        supports=[self.box('Vellum / support '+str(i),[center[0]+x,0,center[2]+z],[5,80,5],'graphite')
                  for i,(x,z) in enumerate([(-45,-30),(45,-30),(-45,30),(45,30)])]
        ids=[owner]+supports
        camera=dict(azimuth=.25,elevation=.95,distance=1.8,projection='perspective',target=dict(x=10,y=.8,z=10))
        for label,light in [('frontlit',self.light('vellum/frontlight',[1000,280,1100],center,[120,90],.45)),
                            ('backlit',self.light('vellum/backlight',[1000,30,1000],center,[70,45],.04))]:
            self.shot('vellum reverse artwork',label,ids,camera,self.settings([light],.05))
        underside=dict(azimuth=3.391592653589793,elevation=-.4,distance=1.6,projection='perspective',target=dict(x=10,y=.8,z=10))
        self.shot('vellum reverse artwork','underside',ids,underside,self.settings([self.light('vellum/backlight',[1000,30,1000],center,[70,45],.04)],.05))
        self.call('form_add_note',dict(kind='decision',text='Vellum optical comparison: the existing overlays and raised study have registered reverse-side source artwork authored through ensure_inside. Raised study source '+inside+' is independently editable on Canvas. The first diagnostic round assigned unmirrored canonical text: readable through the front, mirrored from inside. That authoring discrepancy is preserved in the first PNGs. Current reverse artwork applies the full-net X reflection, matching readable inside physical-face coordinates. Expect mirrored REVERSE through the front and readable REVERSE in the underside shot. The matched frontlit/backlit views keep the same geometry and camera; the light is below the 80 mm raised sheet and above the floor. This is an optical diagnostic, not manufacturer-calibrated transmission.'))

    def reflection(self):
        mirror_material=self.material_value('optics-mirror','Optics / polished neutral reflector','#FFFFFF',.015,1)
        paper_material=self.material_value('optics-card','Optics / matte artwork card','#FFFFFF',.8)
        mirror=self.box('Optics / reflection panel',[1500,0,0],[120,5,100],mirror_material)
        printed=self.sheet('Optics / off-camera printed card',[1500,275,-350],[160,120],.5,paper_material,vertical=True)
        blank=self.sheet('Optics / off-camera blank control',[1500,275,-350],[160,120],.5,paper_material,vertical=True)
        profile=dict(name='Matte card assumption',thicknessMM=.5,profile=dict(texture='smooth',color='#FFFFFF',roughness=.8,textureDepthMM=0,appearance=dict(ior=1.5)))
        for owner in (printed,blank):self.call('form_paper',dict(command='configure',object_id=owner,stock=profile))
        self.artwork(printed,[element('reflect','Red','rectangle',0,0,53,120,'#E31838'),element('reflect','Green','rectangle',53,0,54,120,'#1AA84E'),
                              element('reflect','Blue','rectangle',107,0,53,120,'#194FE0'),element('reflect','Indirect label','text',12,42,136,28,'#FFFFFF',text='INDIRECT',fontSize=18)],1)
        self.artwork(blank,[],1)
        camera=dict(azimuth=0,elevation=.65,distance=2.8,projection='perspective',target=dict(x=15,y=.05,z=0))
        # Camera is near(1500,174,223)mm. The grounded card's lower edge is275mm,
        # above the eye; the entire card is outside the downward camera frustum.
        # Its reflection is near the mirror center via the virtual card below y0.
        for label,card in [('artwork-on',printed),('artwork-off',blank)]:
            self.shot('off-camera reflection',label,[mirror,card],camera,self.settings([],.3))
        reference=dict(azimuth=.3,elevation=.5,distance=10,projection='perspective',target=dict(x=15,y=1.8,z=-1.5))
        self.shot('off-camera reflection','reference-layout',[mirror,printed],reference,self.settings([],.3))
        self.call('form_add_note',dict(kind='decision',text='Indirect-visibility diagnostic: a120×100mm metallic mirror at y5mm faces an editable160×120mm artwork card whose grounded object origin is(1500,275,-350)mm. The card spans y275–395mm; earlier center wording was incorrect because construction roots denote their bottom. In the matched camera at azimuth0/elevation0.65/distance2.8, the entire artwork card lies above/outside the downward direct camera frustum. Artwork-on and artwork-off substitute identically placed printed/blank cards, preserving geometry and illumination. Reference-layout shows both objects directly. Compare reflected RGB bands and mirrored lettering; a camera-culled source would remove them incorrectly. All objects and saved views are ordinary project data.'))

    def run(self):
        self.begin_author_run()
        self.call('form_list_recipes');original,guard=self.restore_guard(self.refresh(protect=True));prior=original['id']
        if not self.state.get('project_id'):raise RuntimeError('Author the base material corpus first')
        try:
            if self.open_project(self.state['project_id'])['name']!=self.corpus['project_name']:raise RuntimeError('Unexpected target project')
            self.vellum();self.reflection()
        finally:
            restored=self.open_project(prior,protect=True)
            if guard and protected_signature(restored)!=guard['signature']:raise RuntimeError('Original project changed')
            self.state.pop('pending_restore',None);self.state['last_restored_project_id']=prior;self.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/cycles-materials')
    parser.add_argument('--samples',type=int,default=64)
    parser.add_argument('--width',type=int,default=1200);parser.add_argument('--height',type=int,default=900)
    args=parser.parse_args()
    if not 1<=args.samples<=4096:parser.error('samples must be1–4096')
    if not (64<=args.width<=8192 and 64<=args.height<=8192 and args.width*args.height<=16777216 and .125<=args.width/args.height<=8):parser.error('Use bounded64–8192 pixel sides, at most16,777,216 total and aspect1:8–8:1')
    Optics(args,json.loads((SOURCE/'corpus.json').read_text())).run()


if __name__=='__main__':main()
