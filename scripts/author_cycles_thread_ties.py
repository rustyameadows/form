#!/usr/bin/env python3
"""Preserve and compare one paired tie-repeat reduction through public MCP."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

from author_cycles_materials import ROOT, SOURCE, protected_signature
from author_cycles_thread_density import DensityReview, artwork_geometry


def changed_ties(design):
    result=copy.deepcopy(design)
    process=result.get('process',{})
    if process.get('tieRepeats')!=2 or process.get('tieIn') is not True or process.get('tieOff') is not True:
        raise ValueError('This controlled comparison requires two enabled tie-in/off backtracking repeats')
    if any(r['spacing']!=.24 for r in result['regions'] if r['method'] in ('satin','fill')):
        raise ValueError('Keep the reviewed 0.24 mm satin/fill spacing fixed')
    process['tieRepeats']=1
    return result


def non_tie_geometry(program):
    return [{k:v for k,v in command.items() if k!='regionID'} for command in program['commands']
            if command.get('purpose') not in ('tieIn','tieOff')]


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()


class TieReview(DensityReview):
    def run_ties(self):
        self.begin_author_run();self.call('form_list_recipes')
        original,guard=self.restore_guard(self.refresh(protect=True));prior=original['id']
        try:
            self.open_study()
            last=next(a for a in reversed(self.state['diagnostics']['matched thread response']['render_attempts']) if a.get('state')=='completed')
            exports=Path(last['png']).parent.parent
            if exports.name!='Exports' or not exports.is_dir():raise RuntimeError('Current portable project Exports is unavailable')
            review=self.state.get('pending_thread_tie_review')
            if review is None:
                records=[]
                for case_id in ('thread-matte','thread-lustrous'):
                    for variant in range(2):
                        owner=self.state['cases'][case_id]['variants'][variant][0];current=self.full_object(owner)
                        expected=changed_ties(current['textile']['embroidery'])
                        before=self.export_program(owner,case_id+'-'+str(variant)+'-before2repeats',exports,'thread-ties')
                        records.append(dict(case_id=case_id,variant=variant,active_object_id=owner,before=before,expected=expected,
                                            source_parameters=current['parameters'],source_position=current['position'],
                                            source_artwork_sha256=digest(artwork_geometry(current['artwork']))))
                review=dict(before_repeats=2,after_repeats=1,spacing_mm=.24,tie_length_mm=.7,records=records,
                            basis='Authored visual comparison; not a sew-out or validated manufacturing recommendation',
                            build_identity=self.begin_author_run())
                self.state['pending_thread_tie_review']=review;self.save()
            edits=[]
            for record in review['records']:
                current=self.full_object(record['active_object_id'])
                if current['textile']['embroidery'] not in (record['before']['design'],record['expected']):
                    raise RuntimeError('An unrelated embroidery edit needs review before tie comparison')
                edits.append(dict(name='form_update_object',arguments=dict(object_id=current['id'],embroidery=record['expected'])))
            self.call('form_batch',dict(operations=edits))
            for record in review['records']:
                current=self.full_object(record['active_object_id'])
                if current['textile']['embroidery']!=record['expected'] or current['parameters']!=record['source_parameters'] or current['position']!=record['source_position'] or digest(artwork_geometry(current['artwork']))!=record['source_artwork_sha256']:
                    raise RuntimeError('Tie comparison changed an unrelated source value')
                record['after']=self.export_program(current['id'],record['case_id']+'-'+str(record['variant'])+'-after1repeat',exports,'thread-ties')
                before=json.loads((exports/Path(record['before']['project_file']).name).read_text())
                after=json.loads((exports/Path(record['after']['project_file']).name).read_text())
                if non_tie_geometry(before)!=non_tie_geometry(after):raise RuntimeError('Non-tie needle commands changed')
                record['non_tie_geometry_sha256']=digest(non_tie_geometry(before))
                for key in ('underlay_stitches','thread_diameter_mm'):
                    if record['before']['tool_result'][key]!=record['after']['tool_result'][key]:raise RuntimeError('Unrelated process count changed: '+key)
                for key in ('tie_in_stitches','tie_off_stitches'):
                    if record['before']['tool_result'][key]!=2*record['after']['tool_result'][key]:raise RuntimeError('Tie command count was not halved')
            for variant in range(2):
                pair=[r for r in review['records'] if r['variant']==variant]
                for phase in ('before','after'):
                    if pair[0][phase]['geometry_sha256']!=pair[1][phase]['geometry_sha256']:raise RuntimeError('Paired actual geometry differs')
            review['paired_needle_geometry_equal']=True;review['non_tie_commands_unchanged']=True
            self.state.setdefault('thread_tie_reviews',[]).append(copy.deepcopy(review));self.state.pop('pending_thread_tie_review');self.save()
            for record in review['records']:
                concise={k:record[k] for k in ('case_id','variant','active_object_id','source_artwork_sha256','non_tie_geometry_sha256')}
                for phase in ('before','after'):
                    p=record[phase];concise[phase]={k:p[k] for k in ('project_file','sha256','geometry_sha256')}
                    concise[phase].update({k:p['tool_result'][k] for k in ('commands','stitches','underlay_stitches','tie_in_stitches','tie_off_stitches','thread_diameter_mm')})
                self.call('form_add_note',dict(kind='decision',text='Controlled paired tie reduction\n'+json.dumps(concise,indent=2)+'\nOnly tieRepeats changes from 2 to 1, reducing four backtracking stitches per tie to two. Both tie-in/off remain enabled at 0.7 mm length. Satin/fill spacing 0.24 mm, running spacing, underlay, diameter, color, optics, source artwork, camera and lights remain fixed. Complete before/after editable definitions are in the exported JSON and project history; the 0.40 mm baseline objects remain untouched. Exact non-tie commands and paired matte/lustrous geometry were compared. This is an artist visual comparison, not a sew-out or validated manufacturing recommendation.'))
            self.threads()
        except BaseException as error:
            self.state['author_runs'][-1]['authoring_failure']=str(error);self.save();raise
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
    print(json.dumps(dict(apply_requested=args.apply,before_repeats=2,after_repeats=1,spacing_mm=.24,detail_renders=4)),flush=True)
    if args.apply:TieReview(args,json.loads((SOURCE/'corpus.json').read_text())).run_ties()


if __name__=='__main__':main()
