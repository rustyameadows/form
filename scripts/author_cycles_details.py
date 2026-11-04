#!/usr/bin/env python3
"""Author the next material close-up evidence through ordinary public LAB MCP."""
import argparse
import json
import math
from pathlib import Path

from author_cycles_materials import ROOT, SOURCE, cloth_mesh, protected_signature
from author_cycles_optics import Optics


class Details(Optics):
    @staticmethod
    def camera(target, distance, elevation, azimuth=.25):
        return dict(azimuth=azimuth,elevation=elevation,distance=distance,projection='perspective',target=dict(zip(('x','y','z'),[v/100 for v in target])))

    def paper_edges(self):
        for index,(x,caliper,label) in enumerate([(0,1,'single1mm'),(190,.5,'single0.5mm')]):
            if self.args.detail and label not in self.args.detail:continue
            owner=self.state['cases']['cotton']['variants'][index][0]
            target=[x,caliper/2,35]
            light=self.light('cotton/'+label+'/edge',[x-40,60,105],target,[80,50],.04)
            self.shot('paper caliper edges',label,[owner],self.camera(target,.45,.16),self.settings([light],.12))
        self.call('form_add_note',dict(kind='decision',text='Caliper close-up evidence isolates one600gsm/approximately1mm sheet and one300gsm/estimated0.5mm sheet at the same camera distance and light geometry. The construction resolver grounds each sheet at its local bottom; objectY0 is floor contact. The 600gsm caliper is a published approximation; the thinner caliper remains an explicit author estimate. Compare actual edge width and bevel at matching scale, not pixel width between different perspective regions.'))

    def finishes(self):
        owner=self.state['cases']['finished-cotton']['variants'][0][0]
        definitions=[('letterpress',[480,1,-20],.55,.8),('blind-relief',[526,1,7],.48,.65),('foil-highlight',[477,1,.5],.6,.7)]
        for label,target,distance,elevation in definitions:
            if self.args.detail and label not in self.args.detail:continue
            if label=='foil-highlight':
                # Reflect camera direction about the horizontal paper normal:
                # opposite horizontal components, same positive elevation.
                length=120
                offset=[-math.sin(.25)*math.cos(elevation)*length,math.sin(elevation)*length,-math.cos(.25)*math.cos(elevation)*length]
                light=self.light('finish/foil/specular',[target[i]+offset[i] for i in range(3)],target,[40,30],.006)
                settings=self.settings([light],.12)
            else:
                light=self.light('finish/'+label+'/key',[target[0]-70,90,target[2]+45],target,[100,60],.1)
                settings=self.settings([light],.16)
            self.shot('paper finish detail',label,[owner],self.camera(target,distance,elevation),settings)
        self.call('form_add_note',dict(kind='decision',text='Finish detail shots separately frame the full MATERIAL impression, complete16mm blind-relief circle, and30×3mm metallic foil strip. The foil highlight light is placed opposite the camera horizontal vector about the physical paper normal; its power is an authored review-light choice, not a calibrated illuminant. These views repair the earlier clipped macro framing while preserving artwork and finish assumptions.'))

    def threads(self):
        for case_id,x in [('thread-matte',0),('thread-lustrous',500)]:
            variants=self.state['cases'][case_id]['variants']
            definitions=[('thread-highlight',variants[0][0],[x,1.15,764],.65,1.05,.25),
                         ('thread-fill',variants[1][0],[x+190,1.15,780],.7,.45,.35)]
            for label,owner,target,distance,elevation,azimuth in definitions:
                if self.args.detail and label not in self.args.detail:continue
                light=self.light(case_id+'/'+label+'/key',[target[0]-100,target[1]+180,target[2]-100],target,[80,20],.48)
                self.shot('matched thread response',case_id+'/'+label,[owner],self.camera(target,distance,elevation,azimuth),self.settings([light],.1))
        if not self.args.detail or any(v.startswith('thread-') for v in self.args.detail):
            spacings={c['stitch_spacing_mm'] for c in self.corpus['cases'] if c['id'] in ('thread-matte','thread-lustrous')}
            if len(spacings)!=1:raise RuntimeError('Paired thread spacing declarations differ')
            spacing=next(iter(spacings))
            processes=[c['thread_process'] for c in self.corpus['cases'] if c['id'] in ('thread-matte','thread-lustrous')]
            if processes[0]!=processes[1]:raise RuntimeError('Paired thread process declarations differ')
            self.call('form_add_note',dict(kind='decision',text=f'Matched thread response views keep the exact authored stitch method, source artwork, satin/fill spacing {spacing:g} mm, color #A14E3C, process diameter 0.22 mm, underlay and ties identical between matte and lustrous cases. Current process: '+json.dumps(processes[0],sort_keys=True)+'. Camera and light offsets are identical relative to each patch. The 80×20 mm key sits at target (-100,+180,-100) mm with 0.48 W and environment 0.1 to demonstrate strand-aligned highlights. Tighter oblique fill/underlay views expose crossings and actual backing contact. The 0.40 mm baseline and denser 0.24 mm artist comparison are separate retained iterations; the latter is outside manufacturer spacing recommendations. The tie-repeat reduction retains before/after editable definitions and all non-tie commands. Ties remain compact raised knots in a noncompressing round-strand model; no calibrated tie mechanics or validated sew-out is claimed. These are editable review scenes, not manufacturer-calibrated illumination.'))

    def satin_faces(self):
        if self.args.detail and 'satin-faces' not in self.args.detail:return
        case=next(c for c in self.corpus['cases'] if c['id']=='satin')
        material=self.state['cases']['satin']['material_id']
        self.call('form_material',dict(command='get',material_id=material))
        record=self.state.setdefault('diagnostics',{}).setdefault('matched satin faces',dict(render_attempts=[]))
        owner=record.get('object_id')
        if not owner:
            created=self.call('form_add_object',dict(recipe_id='clothPanel',name='Satin / flat face-back response control',material_id=material,
                position=[2000,200,0],parameters=dict(width=140,depth=110,densityGSM=case['gsm'],resolution=8,supportRadius=20)))
            owner=created['id'];record['object_id']=owner;self.save()
        declaration=self.call('form_cloth',dict(command='get',object_id=owner))['definition']
        declaration['mesh']=cloth_mesh(140,110,0,case['gsm'],0,case['thickness_mm'],8,6)
        declaration['colliders']=[];declaration.pop('preparation',None)
        self.call('form_cloth',dict(command='configure',object_id=owner,definition=declaration))
        self.call('form_update_object',dict(object_id=owner,material_id=material,position=[2000,200,0]))
        # Mirror the camera/key about each actual flat shell face. Both stay
        # above the floor, and have identical incident/view angle and distance.
        for label,sign,target_y in [('front',1,200+case['thickness_mm']),('back',-1,200)]:
            target=[2000,target_y,0];elevation=.65;distance=120
            light=self.light('satin/flat/'+label,[2000,target_y+sign*math.sin(elevation)*distance,-math.cos(elevation)*distance],target,[30,10],.004)
            self.shot('matched satin faces',label,[owner],self.camera(target,2.8,sign*elevation,0),self.settings([light],0))
        self.call('form_add_note',dict(kind='decision',text='Matched satin face/back control uses one editable flat140×110mm cloth swatch with the same material as the folded silk studies, estimated0.18mm caliper and actual separate front/back shell slots. The object is raised200mm so the underside camera and light stay above the floor. Camera and30×10mm key are mirrored about each actual flat shell face at identical0.65radian angle and distance; unlike globally mirrored curved cloth this controls local incidence. The first0.04W key clipped the front lobe; both keys were reduced to0.004W. Initial rounds retained environment0.08, whose lower hemisphere is occluded by the floor: body luminances therefore are not a fully matched illumination comparison. Final controls disable environment illumination; floor secondary contribution remains possible, so this is a qualitative optical control, not a calibrated BRDF measurement. Front/back shader responses are author estimates, not calibrated Dharma silk values. The official CC0 crepe_satin donor remains a different material. Compare directional highlight width; the flat control does not replace folded-reference review.'))

    def open_study(self):
        project=self.open_project(self.state['project_id'])
        if project['name']!=self.corpus['project_name']:raise RuntimeError('Unexpected target project')

    def run(self):
        self.begin_author_run()
        self.call('form_list_recipes');original,guard=self.restore_guard(self.refresh(protect=True));prior=original['id']
        if not self.state.get('project_id'):raise RuntimeError('Author the base material corpus first')
        try:
            self.open_study()
            self.paper_edges();self.finishes();self.threads();self.satin_faces()
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
    parser.add_argument('--detail',action='append',choices=('single1mm','single0.5mm','letterpress','blind-relief','foil-highlight','thread-highlight','thread-fill','satin-faces'))
    args=parser.parse_args()
    if not 1<=args.samples<=4096:parser.error('samples must be1–4096')
    if not (64<=args.width<=8192 and 64<=args.height<=8192 and args.width*args.height<=16777216 and .125<=args.width/args.height<=8):parser.error('Use bounded64–8192 pixel sides, at most16,777,216 total and aspect1:8–8:1')
    Details(args,json.loads((SOURCE/'corpus.json').read_text())).run()


if __name__=='__main__':main()
