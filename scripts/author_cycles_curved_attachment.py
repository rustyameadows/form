#!/usr/bin/env python3
"""Prepare or author an extra curved-cloth stitch contact control via public MCP.

No app call occurs without --apply. This control requires the installed shared
physical attachment mapper; it does not modify the main eight material cases.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path

from author_cycles_details import Details
from author_cycles_materials import ROOT, SOURCE, cloth_mesh, protected_signature
from cycles_project_reads import ProjectReader


def curved_mesh(parent):
    width, depth, radius = (parent[k] for k in ('width_mm', 'depth_mm', 'radius_mm'))
    if not (0 < width/(2*radius) < math.pi/2):
        raise ValueError('The authored cylindrical panel must remain a single upward-facing arch')
    mesh = cloth_mesh(width, depth, 0, parent['gsm'], 0, parent['caliper_mm'], parent['columns'], parent['rows'])
    baseline = math.cos(width/(2*radius))
    for point, uv in zip(mesh['restPositionsMm'], mesh['uv']):
        angle = (uv['x']-.5)*width/radius
        point.update(x=radius*math.sin(angle), y=radius*(math.cos(angle)-baseline)+parent['caliper_mm']/2,
                     z=(uv['y']-.5)*depth)
    masses = [0.0]*len(mesh['restPositionsMm'])
    area = 0
    for triangle in mesh['triangles']:
        a, b, c = (mesh['restPositionsMm'][triangle[k]] for k in ('a', 'b', 'c'))
        u = [b[k]-a[k] for k in ('x', 'y', 'z')]; v = [c[k]-a[k] for k in ('x', 'y', 'z')]
        cross = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
        if cross[1] <= 0:
            raise ValueError('The authored panel has a reversed or degenerate triangle')
        triangle_area = math.sqrt(sum(x*x for x in cross))/2
        area += triangle_area
        for k in ('a', 'b', 'c'):
            masses[triangle[k]] += triangle_area*parent['gsm']/3e9
    mesh['massesKg'] = masses
    return mesh, dict(vertices=len(masses), triangles=len(mesh['triangles']), area_mm2=area,
                      mass_kg=sum(masses), crest_height_mm=max(p['y'] for p in mesh['restPositionsMm']))


def plan(controls):
    parent, patch = controls['parent'], controls['patch']
    mesh, diagnostic = curved_mesh(parent)
    angle = math.radians(patch['rotation_degrees'])
    half_u = (abs(math.cos(angle))*patch['width_mm']+abs(math.sin(angle))*patch['depth_mm'])/2
    half_v = (abs(math.sin(angle))*patch['width_mm']+abs(math.cos(angle))*patch['depth_mm'])/2
    center_u = (patch['anchor_uv'][0]-.5)*parent['width_mm']
    center_v = (patch['anchor_uv'][1]-.5)*parent['depth_mm']
    margins = [parent['width_mm']/2-abs(center_u)-half_u, parent['depth_mm']/2-abs(center_v)-half_v]
    if min(margins) <= 0 or patch['panel'] != 0:
        raise ValueError('The entire patch must remain within the one authored panel')
    diagnostic.update(patch_material_half_extents_mm=[half_u, half_v], panel_margin_mm=margins,
                      normal_offset_mm=(parent['caliper_mm']+patch['caliper_mm'])/2,
                      maximum_patch_arch_drop_mm=parent['radius_mm']*(1-math.cos(half_u/parent['radius_mm'])),
                      visual_acceptance='pending actual installed-app captures')
    return mesh, diagnostic


def patch_update(target, source_design, parent_id, parent, patch, mesh, normal_offset):
    if target.get('patternAssemblyAttachment') or target.get('textile',{}).get('attachment'):
        raise ValueError('The retained control acquired a different attachment; review before changing it')
    attachment=target.get('clothAttachment')
    if attachment:
        anchor=attachment['anchor'];index=anchor['triangle'];weights=[anchor['weights'][k] for k in ('x','y','z')]
        if attachment['surfaceObjectID']!=parent_id or not math.isclose(attachment['rotationDegrees'],patch['rotation_degrees'],abs_tol=1e-9) or not math.isclose(anchor['normalOffsetMm'],normal_offset,abs_tol=1e-9):
            raise ValueError('The retained parent, rotation or normal offset changed; review before authoring')
        if type(index) is not int or not 0<=index<len(mesh['triangles']) or any(not math.isfinite(w) or w < -1e-9 for w in weights) or not math.isclose(sum(weights),1,abs_tol=1e-9):
            raise ValueError('The retained material anchor is invalid')
        triangle=mesh['triangles'][index]
        uv=[sum(w*mesh['uv'][triangle[k]][axis] for w,k in zip(weights,('a','b','c'))) for axis in ('x','y')]
        if any(not math.isclose(a,b,abs_tol=1e-9) for a,b in zip(uv,patch['anchor_uv'])):
            raise ValueError('The retained material coordinates changed; review before authoring')
    update=dict(object_id=target['id'],embroidery=copy.deepcopy(source_design),
                parameters=dict(width=patch['width_mm'],depth=patch['depth_mm'],height=patch['caliper_mm']))
    if not attachment:update['position']=parent['position_mm']
    return update


class CurvedAttachment(Details):
    def full_object(self, owner):
        summary=self.call('form_get_project',dict(view='summary',object_ids=[owner],limit=1))
        reader=ProjectReader(self.call);revision,metadata=reader.envelope(summary,'summary')
        scoped=self.call('form_get_project',dict(view='scoped',sections=['objects'],object_ids=[owner],limit=1,expected_revision=revision))
        reader.envelope(scoped,'scoped',revision,metadata)
        values=scoped['sections'].get('objects');page=scoped['pages'].get('objects',{})
        if not isinstance(values,list) or len(values)!=1 or values[0].get('id')!=owner or page.get('complete') is not True or page.get('total')!=1 or page.get('has_more') is not False:
            raise RuntimeError('Expected exactly one complete source object')
        return values[0]

    def author_control(self, controls):
        parent, patch = controls['parent'], controls['patch']
        mesh, diagnostic = plan(controls)
        material = self.state['cases'][parent['material_case']]['material_ids'][parent['material_variant']]
        actual_material = self.call('form_material',dict(command='get',material_id=material))
        if actual_material['thickness'] != parent['caliper_mm']:
            raise RuntimeError('Parent material caliper differs from the authored contact calculation')
        source_id = self.state['cases'][patch['source_case']]['variants'][patch['source_variant']][0]
        source = self.full_object(source_id)
        if source.get('recipeID')!='textilePatch' or not source.get('textile',{}).get('embroidery') or not source.get('artwork'):
            raise RuntimeError('Choose the existing independently editable embroidery patch source')
        if any(source['parameters'].get(k)!=patch[field] for k,field in [('width','width_mm'),('depth','depth_mm')]):
            raise RuntimeError('Source patch dimensions changed; review the diagnostic footprint before applying')
        cloth = self.object(parent['name'])
        if not cloth:
            cloth=self.call('form_add_object',dict(recipe_id='clothPanel',name=parent['name'],material_id=material,position=parent['position_mm'],
                parameters=dict(width=parent['width_mm'],depth=parent['depth_mm'],densityGSM=parent['gsm'],resolution=24,supportRadius=20)))
        declaration=self.call('form_cloth',dict(command='get',object_id=cloth['id']))['definition']
        declaration['mesh']=mesh;declaration['colliders']=[];declaration.pop('preparation',None)
        self.call('form_cloth',dict(command='configure',object_id=cloth['id'],definition=declaration))
        self.call('form_update_object',dict(object_id=cloth['id'],material_id=material,position=parent['position_mm']))
        target=self.object(patch['name'])
        if target:target=self.full_object(target['id'])
        else:target=self.call('form_duplicate_object',dict(object_id=source_id,mode='iteration',name=patch['name']))
        update=patch_update(target,source['textile']['embroidery'],cloth['id'],parent,patch,mesh,diagnostic['normal_offset_mm'])
        artwork=copy.deepcopy(source['artwork'])
        if target.get('artwork',{}).get('canvasPosition') is not None:
            artwork['canvasPosition']=target['artwork']['canvasPosition']
        self.call('form_set_artwork',dict(object_id=target['id'],artwork=artwork))
        # Existing surface-bound objects must be repositioned through the
        # material anchor below, never through a competing world position.
        self.call('form_update_object',update)
        self.call('form_cloth',dict(command='attach',object_id=target['id'],surface_object_id=cloth['id'],u=patch['anchor_uv'][0],v=patch['anchor_uv'][1],
            panel=patch['panel'],offset_mm=diagnostic['normal_offset_mm'],rotation=patch['rotation_degrees']))
        record=self.state.setdefault('diagnostics',{}).setdefault('curved cloth attachment',dict(render_attempts=[]))
        record.update(parent_object_id=cloth['id'],patch_object_id=target['id'],source_object_id=source_id,controls=controls,geometry_diagnostic=diagnostic,
                      verified_previous_attachment=copy.deepcopy(target.get('clothAttachment')),
                      source_artwork_and_embroidery_sha256=hashlib.sha256(json.dumps({'artwork':source['artwork'],'embroidery':source['textile']['embroidery']},sort_keys=True,separators=(',',':')).encode()).hexdigest())
        self.save()
        note='Curved cloth contact control / editable project data\n'+json.dumps({k:record[k] for k in ('parent_object_id','patch_object_id','source_object_id','geometry_diagnostic','source_artwork_and_embroidery_sha256')},indent=2)+'\n'+json.dumps(controls,sort_keys=True,separators=(',',':'))
        if len(note)>4000:raise ValueError('Diagnostic note exceeds the project note bound')
        self.call('form_add_note',dict(kind='decision',text=note))
        center=[parent['position_mm'][0],parent['position_mm'][1]+diagnostic['crest_height_mm']+diagnostic['normal_offset_mm']+patch['caliper_mm']/2,parent['position_mm'][2]]
        light=self.light('curved-cloth/contact/key',[center[0]-110,center[1]+180,center[2]-90],center,[100,50],.35)
        for label,distance,elevation,azimuth in [('whole',3.0,.65,.7),('oblique',1.55,.65,.6),('grazing',1.7,.16,1.2)]:
            self.shot('curved cloth attachment',label,[cloth['id'],target['id']],self.camera(center,distance,elevation,azimuth),self.settings([light],.12))

    def run(self, controls):
        self.begin_author_run();self.call('form_list_recipes')
        original,guard=self.restore_guard(self.refresh(protect=True));prior=original['id']
        try:
            self.open_study();self.author_control(controls)
        except BaseException as error:
            self.state['author_runs'][-1]['authoring_failure']=str(error);self.save();raise
        finally:
            restored=self.open_project(prior,protect=True)
            if guard and protected_signature(restored)!=guard['signature']:raise RuntimeError('Original project changed')
            self.state.pop('pending_restore',None);self.state['last_restored_project_id']=prior;self.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/cycles-materials')
    parser.add_argument('--samples',type=int,default=64)
    parser.add_argument('--width',type=int,default=1200);parser.add_argument('--height',type=int,default=900)
    args=parser.parse_args()
    if not 1<=args.samples<=4096:parser.error('samples must be1–4096')
    if not (64<=args.width<=8192 and 64<=args.height<=8192 and args.width*args.height<=16777216 and .125<=args.width/args.height<=8):parser.error('Use bounded output pixels/aspect')
    controls=json.loads((SOURCE/'geometry/curved-embroidery-controls.json').read_text())
    _,diagnostic=plan(controls)
    print(json.dumps(dict(apply_requested=args.apply,controls=controls,diagnostic=diagnostic),indent=2),flush=True)
    if args.apply:CurvedAttachment(args,json.loads((SOURCE/'corpus.json').read_text())).run(controls)


if __name__=='__main__':main()
