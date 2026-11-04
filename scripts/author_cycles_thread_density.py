#!/usr/bin/env python3
"""Retain editable thread baselines and compare a paired authored density change."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import uuid

from author_cycles_curved_attachment import CurvedAttachment
from author_cycles_materials import ROOT, SOURCE, protected_signature


def changed_spacing(design, spacing):
    result=copy.deepcopy(design)
    for region in result['regions']:
        if region['method'] in ('satin','fill'):region['spacing']=spacing
    return result


def artwork_geometry(artwork):
    return {k:v for k,v in artwork.items() if k!='canvasPosition'}


def geometry_digest(program):
    # Region UUIDs/name/source digest differ between appearances. Needle
    # positions, order, actions, thread indices and purposes must not differ.
    commands=[{k:v for k,v in command.items() if k!='regionID'} for command in program['commands']]
    encoded=json.dumps(commands,sort_keys=True,separators=(',',':')).encode()
    return hashlib.sha256(encoded).hexdigest()


class DensityReview(CurvedAttachment):
    def export_program(self, owner, label, folder, prefix='thread-density'):
        path=folder/(prefix+'-'+label+'-'+str(uuid.uuid4())+'.json')
        if path.exists():raise RuntimeError('New evidence path already exists')
        result=self.call('form_export_artwork',dict(object_id=owner,format='json',embroidery_format='json',path=str(path)))
        if Path(result['path'])!=path or path.stat().st_size>16*1024*1024:raise RuntimeError('Unexpected needle program export')
        data=path.read_bytes();program=json.loads(data)
        if result['commands']!=len(program['commands']):raise RuntimeError('Exported command count differs from actual program')
        return dict(tool_result=result,project_file='Exports/'+path.name,sha256=hashlib.sha256(data).hexdigest(),
                    geometry_sha256=geometry_digest(program),design=program['design'])

    def run_density(self):
        self.begin_author_run();self.call('form_list_recipes')
        original,guard=self.restore_guard(self.refresh(protect=True));prior=original['id']
        try:
            self.open_study()
            last=next(a for a in reversed(self.state['diagnostics']['matched thread response']['render_attempts']) if a.get('state')=='completed')
            exports=Path(last['png']).parent.parent
            if exports.name!='Exports' or not exports.is_dir():raise RuntimeError('Current portable project Exports is unavailable')
            records=[];edits=[];baseline_ids=[]
            for material_index,case_id in enumerate(('thread-matte','thread-lustrous')):
                for variant in range(2):
                    owner=self.state['cases'][case_id]['variants'][variant][0];current=self.full_object(owner)
                    name=current['name']+' / retained spacing 0.40 mm'
                    baseline=self.object(name)
                    if baseline:baseline=self.full_object(baseline['id'])
                    else:
                        if any(r['spacing']!=.4 for r in current['textile']['embroidery']['regions'] if r['method'] in ('satin','fill')):
                            raise RuntimeError('No retained original exists for an already-modified source')
                        baseline=self.call('form_duplicate_object',dict(object_id=owner,mode='iteration',name=name))
                        self.call('form_update_object',dict(object_id=baseline['id'],position=[3000+material_index*500+variant*190,0,780]))
                    if any(r['spacing']!=.4 for r in baseline['textile']['embroidery']['regions'] if r['method'] in ('satin','fill')):
                        raise RuntimeError('Retained editable baseline no longer has its original spacing')
                    expected=changed_spacing(baseline['textile']['embroidery'],.24)
                    if current['textile']['embroidery'] not in (baseline['textile']['embroidery'],expected) or artwork_geometry(current['artwork'])!=artwork_geometry(baseline['artwork']):
                        raise RuntimeError('An unrelated source/program change needs review before this comparison')
                    before=self.export_program(baseline['id'],case_id+'-'+str(variant)+'-before040',exports)
                    records.append(dict(case_id=case_id,variant=variant,active_object_id=owner,baseline_object_id=baseline['id'],
                                        before=before,source_parameters=current['parameters'],source_position=current['position'],
                                        source_artwork_sha256=hashlib.sha256(json.dumps(artwork_geometry(current['artwork']),sort_keys=True,separators=(',',':')).encode()).hexdigest(),
                                        expected=expected))
                    baseline_ids.append(baseline['id'])
                    edits.append(dict(name='form_update_object',arguments=dict(object_id=owner,embroidery=expected)))
            group=self.call('form_group_objects',dict(object_ids=baseline_ids))
            self.call('form_batch',dict(operations=edits))
            for record in records:
                actual=self.full_object(record['active_object_id'])
                if actual['textile']['embroidery']!=record.pop('expected') or actual['parameters']!=record['source_parameters'] or actual['position']!=record['source_position']:
                    raise RuntimeError('Density edit changed an unrelated source parameter')
                sha=hashlib.sha256(json.dumps(artwork_geometry(actual['artwork']),sort_keys=True,separators=(',',':')).encode()).hexdigest()
                if sha!=record['source_artwork_sha256']:raise RuntimeError('Source artwork changed during density comparison')
                record['after']=self.export_program(actual['id'],record['case_id']+'-'+str(record['variant'])+'-after024',exports)
                for key in ('underlay_stitches','tie_in_stitches','tie_off_stitches','thread_diameter_mm'):
                    if record['before']['tool_result'][key]!=record['after']['tool_result'][key]:raise RuntimeError('Unrelated process command count changed: '+key)
            for variant in range(2):
                pair=[r for r in records if r['variant']==variant]
                for phase in ('before','after'):
                    if pair[0][phase]['geometry_sha256']!=pair[1][phase]['geometry_sha256']:
                        raise RuntimeError('Matte/lustrous needle geometry is not identical for '+phase)
            review=dict(before_spacing_mm=.4,after_spacing_mm=.24,spacing_basis='Authored visual comparison, not a manufacturer recommendation or measured optimum',
                        baseline_group=group,records=records,paired_needle_geometry_equal=True,build_identity=self.begin_author_run())
            self.state.setdefault('thread_density_reviews',[]).append(review);self.save()
            for record in records:
                concise={k:record[k] for k in ('case_id','variant','active_object_id','baseline_object_id','source_artwork_sha256')}
                for phase in ('before','after'):
                    p=record[phase];concise[phase]={k:p[k] for k in ('project_file','sha256','geometry_sha256')}
                    concise[phase].update({k:p['tool_result'][k] for k in ('commands','stitches','underlay_stitches','tie_in_stitches','tie_off_stitches','thread_diameter_mm')})
                self.call('form_add_note',dict(kind='decision',text='Editable thread density comparison\n'+json.dumps(concise,indent=2)+'\nRetained baseline iterations are spatially separate and grouped. Only satin/fill spacing changes from0.40 to0.24mm; running path, underlay, ties, diameter, color and optical settings stay fixed. Paired actual command geometry is identical between matte/lustrous, verified after ignoring region UUIDs only. The exported JSON contains complete digitizing definitions. This is an authored visual comparison, outside the stated manufacturer spacing recommendations; no sew-out is claimed. Existing main shot visibility IDs stay unchanged.'))
            self.threads()
        finally:
            restored=self.open_project(prior,protect=True)
            if guard and protected_signature(restored)!=guard['signature']:raise RuntimeError('Original project changed')
            self.state.pop('pending_restore',None);self.state['last_restored_project_id']=prior;self.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true');parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/cycles-materials')
    parser.add_argument('--samples',type=int,default=64);parser.add_argument('--width',type=int,default=1200);parser.add_argument('--height',type=int,default=900)
    args=parser.parse_args();args.detail=['thread-highlight','thread-fill']
    if not 1<=args.samples<=4096 or not (64<=args.width<=8192 and 64<=args.height<=8192 and args.width*args.height<=16777216):parser.error('Use bounded samples/pixels')
    print(json.dumps(dict(apply_requested=args.apply,before_spacing_mm=.4,after_spacing_mm=.24,editable_retained_baselines=4,detail_renders=4)),flush=True)
    if args.apply:DensityReview(args,json.loads((SOURCE/'corpus.json').read_text())).run_density()


if __name__=='__main__':main()
