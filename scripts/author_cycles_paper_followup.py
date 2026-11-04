#!/usr/bin/env python3
"""Plan or author isolated paper-materiality comparisons through public LAB MCP.

Default is file-only. The original eight specimens and their shots are never
edited. Candidate objects are ordinary independent iterations, in free Table
space, with exactly translated copies of the source cameras and area lights.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import time

from author_cycles_curved_attachment import CurvedAttachment
from author_cycles_materials import ROOT, SOURCE, write_json
from cycles_project_reads import ProjectReader, ProjectReadRevisionChanged
from verify_cycles_app import verify_runtime_provenance

FIELDS=('objects','materials','recipes','notes','camera','studioPresentation','renderSettings',
        'publications','textStories','fontLibrary','textStyles')
ASSETS=SOURCE/'paper-followup'
EDGE_RESPONSE=dict(ior=1.5,diffuseTransmission=0,transmission=0,subsurface=0,
    subsurfaceRadiusMM=dict(x=1,y=.2,z=.1),sheen=0,sheenRoughness=.5,sheenTint='#FFFFFF',
    anisotropy=0,anisotropyRotation=0,coat=0,coatRoughness=.03,bumpStrength=1,
    normalStrength=1,displacementScaleMM=0,displacementMidlevel=.5,textures={})


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def translated_shot(source,delta,owner,samples,width,height):
    result=copy.deepcopy(source)
    for axis,value in zip(('x','y','z'),delta):
        result['camera']['target'][axis]+=value/100
    settings=result.get('renderSettings')
    if not settings or settings.get('renderer')!='cycles':
        raise ValueError('A baseline needs explicit persisted Cycles settings')
    settings['samples']=samples
    for light in settings.get('areaLights',[]):
        for key in ('positionMM','targetMM'):
            for axis,value in zip(('x','y','z'),delta):light[key][axis]+=value
    result['visibility']=dict(mode='objects',objectIDs=[owner])
    result['pixels']=dict(width=width,height=height)
    return result


def edge_macro_shot(source):
    """Increase magnification without changing incidence or illumination."""
    result=copy.deepcopy(source)
    distance=result['camera']['distance']
    if not math.isfinite(distance) or distance<=0:raise ValueError('Edge camera distance must be positive and finite')
    result['camera']['distance']=distance/3
    return result


def edge_raking_shot(source):
    result=copy.deepcopy(source);settings=result['renderSettings']
    if len(settings['areaLights'])!=1:raise ValueError('The matched raking control requires the single recorded key light')
    light=settings['areaLights'][0]
    for axis,offset in zip(('x','y','z'),(-60,60,20)):
        light['positionMM'][axis]=light['targetMM'][axis]+offset
    light['sizeMM']=dict(x=20,y=12)
    settings['environmentStrength']=.03
    return result


def edge_patch(textures,strength):
    if not 0<=strength<=2:raise ValueError('Bounded edge normal strength required')
    response=copy.deepcopy(EDGE_RESPONSE)
    response.update(normalStrength=strength,textures=copy.deepcopy(textures))
    return dict(profile=dict(edgeAppearance=response))


def shoulder_patches(definition,radius):
    if not 0<=radius<=2:raise ValueError('Shoulder radius must be0–2mm')
    selected=[f for f in definition.get('finishes',[]) if f.get('enabled',True) and f['kind'] in ('letterpress','emboss','deboss')]
    if not selected:raise ValueError('No editable relief finish is present')
    return [dict(id=f['id'],shoulderRadiusMM=radius) for f in selected]


def deboss_patches(definition):
    selected=[f for f in definition.get('finishes',[]) if f.get('enabled',True) and f['kind']=='emboss']
    if not selected or any(f.get('heightMM',0)<=0 or f.get('depthMM',0)!=0 for f in selected):
        raise ValueError('A matched sign comparison needs a positive blind emboss')
    return [dict(id=f['id'],kind='deboss',heightMM=0,depthMM=f['heightMM']) for f in selected]


def finish_patch_states(definition,patches):
    """Exact legal checkpoints for independently committed paper commands."""
    states=[copy.deepcopy(definition)]
    for patch in patches:
        state=copy.deepcopy(states[-1])
        selected=[f for f in state.get('finishes',[]) if f['id']==patch['id']]
        if len(selected)!=1:raise ValueError('A finish patch needs one existing finish ID')
        selected[0].update(copy.deepcopy(patch));states.append(state)
    return states


def non_paper_digest(value):
    result=copy.deepcopy(value);result.pop('paperConstruction',None)
    return digest(result)


def require_exact_owner(owner,expected):
    if digest(owner)!=digest(expected):
        raise RuntimeError('Selected control no longer matches its complete recorded object; use the explicit current revision label')


def parse_reuse_views(values):
    result={}
    for value in values or []:
        key,separator,previous=value.partition('=')
        if not separator or not key or not previous or key in result:
            raise ValueError('Use unique --reuse-view NEW_LABEL=EXISTING_LABEL mappings')
        result[key]=previous
    return result


def selected_views(stage,requested):
    available=dict(baseline=('single1mm','single0.5mm','letterpress','blind-relief','foil-highlight'),
        edge=('single1mm','single0.5mm'),
        **{'edge-macro':('baseline1mm','edge-0.25-1mm')},
        **{'edge-review':('baseline-whole','candidate-whole','baseline-raking','candidate-raking')},
        shoulder=('letterpress','blind-relief','foil-highlight'),
        deboss=('blind-relief','positive-changed-light','negative-changed-light','whole-pair'),final=())[stage]
    if requested and (len(set(requested))!=len(requested) or not set(requested)<=set(available)):
        raise ValueError('Views must be unique members of: '+', '.join(available))
    return tuple(v for v in available if not requested or v in requested)


def next_candidate_position(origin,candidates):
    # Revision aliases retain history but do not occupy another physical slot.
    count=len({record['object_id'] for record in candidates.values()})
    return [origin[0]+170*count,origin[1],origin[2]]


class PaperFollowup(CurvedAttachment):
    def __init__(self,args,corpus):
        super().__init__(args,corpus)
        if not self.state.get('project_id'):
            source=args.source_state.resolve()
            self.state=json.loads(source.read_text())
            if self.state.get('pending_restore'):raise RuntimeError('Finish or recover the prior authoring run first')
            self.state['followup_origin']=dict(path=str(source),sha256=hashlib.sha256(source.read_bytes()).hexdigest())
            self.state['author_runs']=[]
            self.save()
        self.review=self.state.setdefault('paper_materiality',dict(version=1,sources={},candidates={},shots={},attempts=[],visual_acceptance='pending'))

    def wants_view(self,label):
        return label in selected_views(self.args.stage,getattr(self.args,'view',None))

    def archive(self,kind,label,value):
        # Evidence files are immutable exports, never writes to project model
        # JSON. The actual prior render path establishes the correct package.
        previous=next((a for a in reversed(self.review['attempts']) if a.get('state')=='completed'),None)
        if previous is None:
            previous=next((a for case in self.state.get('cases',{}).values() for a in reversed(case.get('render_attempts',[])) if a.get('state')=='completed'),None)
        if previous is None:raise RuntimeError('A prior project export is required to archive a revision')
        exports=Path(previous['record']).resolve().parent.parent
        if exports.name!='Exports' or exports.parent.name!=self.state['project_id']+'.form' or not exports.is_dir():
            raise RuntimeError('Portable evidence destination is not the current project Exports')
        payload=dict(version=1,kind=kind,label=label,value=copy.deepcopy(value))
        data=(json.dumps(payload,sort_keys=True,indent=2)+'\n').encode()
        sha=hashlib.sha256(data).hexdigest();folder=exports/'paper-materiality';folder.mkdir(exist_ok=True)
        path=folder/(kind+'-'+sha+'.json')
        if path.exists():
            if path.read_bytes()!=data:raise RuntimeError('Immutable authoring evidence differs')
        else:
            with path.open('xb') as file:file.write(data)
        reference=dict(project_file='Exports/paper-materiality/'+path.name,sha256=sha)
        notes=self.review.setdefault('archive_notes',{})
        if sha not in notes:
            response=self.call('form_add_note',dict(kind='decision',text='Paper materiality immutable '+kind+'\n'+json.dumps(dict(label=label,**reference),sort_keys=True)+'\nThis archive retains the exact editable definition before a controlled revision or render. It is evidence, not a claim of visual acceptance.'))
            notes[sha]=dict(reference=reference,result=response);self.save()
        return reference

    def protected(self,target=None):
        for retry in range(3):
            initial=self.call('form_get_project',dict(view='summary',limit=64))
            reader=ProjectReader(self.call);revision,metadata=reader.envelope(initial,'summary')
            if target is not None and metadata['id']!=target:raise RuntimeError('Protected project identity changed')
            target=metadata['id'];value=dict(metadata)
            try:
                for section in FIELDS:
                    if section=='camera':continue
                    response=self.call('form_get_project',dict(view='scoped',sections=[section],offset=0,limit=64,expected_revision=revision))
                    reader.envelope(response,'scoped',revision,metadata)
                    page=response['pages'].get(section,{})
                    if page.get('kind')=='scalar':
                        if page.get('complete') is not True or section not in response['sections']:raise RuntimeError('Incomplete scalar protection')
                        value[section]=response['sections'][section]
                    else:value[section]=reader.array(section,response,'scoped',revision,metadata)
                return value,{key:digest(value[key]) for key in FIELDS}
            except ProjectReadRevisionChanged:
                if retry==2:raise
                # Discard every page and restart at the same explicit identity.
        raise RuntimeError('Could not read one coherent protected revision')

    def full_object(self,owner):
        for retry in range(3):
            try:return super().full_object(owner)
            except ProjectReadRevisionChanged:
                if retry==2:raise

    def source(self,key,case,variant):
        owner=self.state['cases'][case]['variants'][variant][0]
        current=self.full_object(owner)
        if key not in self.review['sources']:
            path=self.output/'before'/f'{key}.json'
            if path.exists() and json.loads(path.read_text())!=current:
                raise RuntimeError('Immutable before definition differs from the current source: '+key)
            self.review['sources'][key]=dict(object_id=owner,sha256=digest(current),object=copy.deepcopy(current))
            if not path.exists():write_json(path,current)
            self.save()
        baseline=self.review['sources'][key]
        if digest(current)!=baseline['sha256']:raise RuntimeError('Preserved source changed: '+key)
        return baseline['object']

    def source_shot(self,diagnostic,view):
        records=self.state['diagnostics'][diagnostic]['render_attempts']
        saved=next(r for r in reversed(records) if r.get('view')==view and r.get('state')=='completed')
        shot=self.call('form_set_view',dict(view='studio',studio_command='get',shot_id=saved['shot_id']))
        key=diagnostic+'/'+view
        sources=self.review.setdefault('source_shots',{})
        if key in sources and sources[key]!=shot:raise RuntimeError('Preserved source shot changed: '+key)
        sources.setdefault(key,copy.deepcopy(shot));self.save()
        return shot

    def candidate(self,key,source):
        record=self.review['candidates'].get(key)
        if record:
            current=self.full_object(record['object_id'])
            if current['position']!=record['position']:raise RuntimeError('Candidate was moved after its matched camera was established')
            if record.get('revision_from'):
                before=record['before_object'];renamed=copy.deepcopy(before);renamed['name']='Paper materiality / '+key
                if current==before:
                    self.call('form_update_object',dict(object_id=current['id'],name=renamed['name']))
                    current=self.full_object(current['id'])
                if non_paper_digest(current)!=non_paper_digest(renamed):
                    raise RuntimeError('Revision retry found an unrelated non-paper object change')
            return current
        prior_key=getattr(self.args,'revision_from',None)
        if prior_key:
            prior=self.review['candidates'].get(prior_key)
            if prior is None or key==prior_key:raise RuntimeError('Choose a distinct recorded comparison iteration to revise')
            current=self.full_object(prior['object_id'])
            if digest(current)!=self.args.expected_object_sha256:
                raise RuntimeError('Candidate does not match the explicitly expected complete prior object hash')
            if current['id'] in {v['object_id'] for v in self.review['sources'].values()} or prior['source_id']!=source['id']:
                raise RuntimeError('Only a matching comparison copy may be revised; historical sources are protected')
            archived=self.archive('before-object',key,current)
            self.review['candidates'][key]=dict(object_id=current['id'],position=copy.deepcopy(current['position']),
                delta_mm=[current['position'][axis]-source['position'][axis] for axis in ('x','y','z')],
                source_id=source['id'],revision_from=prior_key,before_object=copy.deepcopy(current),before_archive=archived)
            self.save()
            return self.candidate(key,source)
        # A deterministic name recovers a committed duplicate whose reply was
        # lost; unrelated names or source-parent changes fail closed.
        name='Paper materiality / '+key
        inventory=self.refresh()['objects']
        existing=[o for o in inventory if o['name']==name]
        if len(existing)>1:raise RuntimeError('Ambiguous comparison specimen')
        if 'layout_origin_mm' not in self.review:
            # These known100×70mm specimens occupy a fresh row at least1m
            # beyond the current study's object origins. Keeping the row
            # compact permits an honest whole-pair view as well as macros.
            self.review['layout_origin_mm']=[0,0,max(o['position']['z'] for o in inventory)+1000]
            self.save()
        origin=self.review['layout_origin_mm']
        planned=next_candidate_position(origin,self.review['candidates'])
        current=self.full_object(existing[0]['id']) if existing else self.call('form_duplicate_object',dict(object_id=source['id'],mode='iteration',name=name))
        if current.get('parentIterationID')!=source['id'] or current.get('designID')==source.get('designID'):
            raise RuntimeError('Comparison specimen is not an independent source iteration')
        self.call('form_update_object',dict(object_id=current['id'],position=planned))
        current=self.full_object(current['id'])
        delta=[current['position'][axis]-source['position'][axis] for axis in ('x','y','z')]
        self.review['candidates'][key]=dict(object_id=current['id'],position=current['position'],delta_mm=delta,source_id=source['id'])
        self.save();return current

    def candidate_baseline(self,key,source):
        record=self.review['candidates'].get(key,{})
        return copy.deepcopy(record['before_object']['paperConstruction'] if record.get('revision_from') else source['paperConstruction'])

    def texture_maps(self):
        provenance=json.loads((ASSETS/'provenance.json').read_text());maps={}
        for asset in provenance['assets']:
            path=ASSETS/asset['file']
            if hashlib.sha256(path.read_bytes()).hexdigest()!=asset['sha256']:raise RuntimeError('Prepared edge texture hash changed')
            maps[asset['channel']]=self.texture(path,asset['channel'],provenance['physical_repeat_mm'])
        self.review['edge_assets']=provenance;self.save();return maps

    def apply_finish_patches(self,owner,baseline,patches):
        # form_batch deliberately excludes paper edits. Each public command
        # commits independently, so accept only an exact saved prefix on retry.
        states=finish_patch_states(baseline,patches)
        current=owner['paperConstruction']
        if current not in states:raise RuntimeError('An unrelated candidate finish edit needs review')
        start=max(i for i,state in enumerate(states) if state==current)
        for patch,expected in zip(patches[start:],states[start+1:]):
            self.call('form_paper',dict(command='set_finish',object_id=owner['id'],finish=patch))
            owner=self.full_object(owner['id'])
            if owner['paperConstruction']!=expected:
                raise RuntimeError('Finish edit changed an unrelated paper field')
        return owner

    def capture(self,label,source_shot,source,owner):
        delta=[owner['position'][axis]-source['position'][axis] for axis in ('x','y','z')]
        definition=translated_shot(source_shot,delta,owner['id'],self.args.samples,self.args.width,self.args.height)
        return self.capture_definition(label,definition,source,owner,source_shot['id'],delta)

    def capture_definition(self,label,definition,source,owner,source_shot_id,delta):
        definition=copy.deepcopy(definition)
        reuse=getattr(self.args,'reuse_views',{}).get(label)
        reused=None
        if reuse:
            # On an interrupted retry prefer this round's already committed
            # shot. The prior alias remains an immutable historical snapshot.
            reused=self.review['shots'].get(label) or self.review['shots'].get(reuse)
            if reused is None or reused['primary_object_id']!=owner['id']:
                raise RuntimeError('A reused view must already target this exact comparison object')
            actual=self.call('form_set_view',dict(view='studio',studio_command='get',shot_id=reused['id']))
            if actual!=reused['definition']:raise RuntimeError('Reused shot differs from its complete saved definition')
            self.archive('before-shot',label,actual)
            definition=copy.deepcopy(actual);source_shot_id=reused['source_shot_id'];delta=reused['translation_mm']
        definition['renderSettings']['samples']=self.args.samples
        definition['pixels']=dict(width=self.args.width,height=self.args.height)
        name='Paper materiality / '+label
        shots=self.call('form_set_view',dict(view='studio',studio_command='list'))
        old=next((s for s in shots if s['name']==name),None)
        if reused:
            if old and old['id']!=reused['id']:raise RuntimeError('Requested shot name collides with another saved view')
            old=reused['definition']
        if not old and len(shots)>=64:raise RuntimeError('Saved-shot limit reached; explicitly reuse a comparison view')
        args=dict(view='studio',studio_command='update' if old else 'capture',name=name,camera=definition['camera'],
                  reference_aspect=definition['referenceAspect'],lighting=definition['lighting'],surface=definition['surface'],
                  visibility=definition['visibility'],width=self.args.width,height=self.args.height,render_settings=definition['renderSettings'])
        if old:args['shot_id']=old['id']
        saved=self.call('form_set_view',args)
        self.review['shots'][label]=dict(id=saved['id'],definition=saved,source_shot_id=source_shot_id,translation_mm=delta,primary_object_id=owner['id'])
        attempt=dict(label=label,stage=self.args.stage,shot_id=saved['id'],object_id=owner['id'],
                     source_object_id=source['id'],source_definition_sha256=digest(source),
                     authored_definition=copy.deepcopy(owner['paperConstruction']),
                     authored_object=copy.deepcopy(owner),shot_definition=copy.deepcopy(saved),
                     requested_samples=self.args.samples,requested_pixels=definition['pixels'],state='starting',
                     build_identity=self.begin_author_run(),visual_acceptance='pending')
        self.review['attempts'].append(attempt);self.save()
        try:
            attempt['authoring_archive']=self.archive('render-definition',label,dict(object=owner,shot=saved,source_object_id=source['id'],source_definition_sha256=digest(source),build_identity=attempt['build_identity']))
            self.save()
            result=self.call('form_render',dict(command='start',project_id=self.state['project_id'],target='shot',shot_id=saved['id']))
            attempt.update(result);self.save();deadline=time.monotonic()+2400
            while result['state'] in ('preparing','rendering'):
                if time.monotonic()>deadline:raise RuntimeError('Paper comparison render timed out')
                time.sleep(3);result=self.call('form_render',dict(command='status',job_id=result['job_id']));attempt.update(result);self.save()
            if result['state']!='completed':raise RuntimeError(str(result.get('error')))
            attempt.update(self.call('form_render',dict(command='result',job_id=result['job_id'])))
            attempt['runtime_verification']=verify_runtime_provenance(json.loads(Path(attempt['record']).read_text()),self.args.app.resolve())
            attempt['project_files']={key:'Exports/'+Path(attempt[key]).parent.name+'/'+Path(attempt[key]).name for key in ('png','exr','record')}
            print(json.dumps(dict(label=label,png=attempt['png'],actual_samples=attempt.get('sample'),visual_acceptance='pending')),flush=True)
        except BaseException as error:
            if attempt.get('job_id') and attempt['state'] in ('preparing','rendering'):self.call('form_render',dict(command='cancel',job_id=attempt['job_id']))
            attempt.update(state='failed',failure=str(error));raise
        finally:
            self.save()
            evidence={k:attempt[k] for k in ('label','stage','shot_id','object_id','source_object_id','state','project_files','authoring_archive','failure','requested_samples','requested_pixels','visual_acceptance') if k in attempt}
            evidence['build_identity_sha256']=digest(attempt['build_identity'])
            self.call('form_add_note',dict(kind='decision',text='Paper materiality follow-up evidence\n'+json.dumps(evidence,sort_keys=True)+'\nOriginal specimens and source shots are retained. Candidate iterations and matched translated cameras/lights are editable. Edge maps are analytic optical estimates, not measured cotton fibers; relief shoulder width is an authored visual control, not a manufacturing calibration. Completion is not visual acceptance.'))

    def execute(self):
        self.begin_author_run();self.call('form_list_recipes')
        summary=self.call('form_get_project',dict(view='summary',limit=1));current_id=summary['project']['id']
        pending=self.state.get('followup_restore')
        if pending:
            if current_id not in (pending['project_id'],self.state['project_id']):raise RuntimeError('Interrupted follow-up cannot switch an unrelated current project')
            self.call('form_open_project',dict(project_id=pending['project_id'],view='summary'))
            original,hashes=self.protected(pending['project_id'])
            if hashes!=pending['hashes']:raise RuntimeError('Original changed after interrupted follow-up')
        else:
            if current_id==self.state['project_id']:raise RuntimeError('Start from the preserved original project, not the study')
            original,hashes=self.protected(current_id)
            self.state['followup_restore']=dict(project_id=original['id'],hashes=hashes);self.save()
        try:
            self.open_study()
            cotton=[self.source('cotton-'+label,'cotton',i) for i,label in enumerate(('1mm','0.5mm'))]
            finished=self.source('finished-cotton','finished-cotton',0)
            if self.args.stage!='baseline':
                baseline=[a for a in self.review['attempts'] if a['stage']=='baseline' and a['state']=='completed']
                identity=self.begin_author_run()['files']
                if len({a['label'] for a in baseline if a['build_identity']['files']==identity})<5:
                    raise RuntimeError('Capture all five baseline controls on this exact installed build before changing fields')
            if self.args.stage in ('baseline','edge'):
                maps=self.texture_maps() if self.args.stage=='edge' else None
                for source,label in zip(cotton,('single1mm','single0.5mm')):
                    if not self.wants_view(label):continue
                    stage='baseline' if maps is None else 'edge-'+format(self.args.normal_strength,'.3g')
                    candidate_key=stage+'/'+label
                    owner=source if maps is None else self.candidate(candidate_key,source)
                    if maps is not None:
                        baseline=self.candidate_baseline(candidate_key,source)
                        expected=copy.deepcopy(baseline);expected['stock']['profile']['edgeAppearance']=edge_patch(maps,self.args.normal_strength)['profile']['edgeAppearance']
                        actual=owner['paperConstruction']
                        if actual not in (baseline,expected):raise RuntimeError('An unrelated candidate paper edit needs review')
                        self.call('form_paper',dict(command='configure',object_id=owner['id'],stock=edge_patch(maps,self.args.normal_strength)))
                        owner=self.full_object(owner['id'])
                        if owner['paperConstruction']!=expected:raise RuntimeError('Edge edit altered an unrelated stock/finish field')
                    self.capture(stage+'/'+label,self.source_shot('paper caliper edges',label),source,owner)
            if self.args.stage=='edge-macro':
                source=cotton[0]
                candidate=self.review['candidates'].get('edge-0.25/single1mm')
                if candidate is None:raise RuntimeError('The reviewed edge .25 specimen must already exist')
                owner=self.full_object(candidate['object_id'])
                previous=next((a for a in reversed(self.review['attempts']) if a['label']=='edge-0.25/single1mm' and a['state']=='completed'),None)
                if previous is None or owner['paperConstruction']!=previous['authored_definition']:
                    raise RuntimeError('The edge macro must retain the exact prior candidate appearance')
                macro=edge_macro_shot(self.source_shot('paper caliper edges','single1mm'))
                for label,subject in [('baseline1mm',source),('edge-0.25-1mm',owner)]:
                    if not self.wants_view(label):continue
                    self.capture('edge-macro/'+label,macro,source,subject)
            if self.args.stage=='edge-review':
                source=cotton[0];key='edge-'+format(self.args.normal_strength,'.3g')+'/single1mm'
                record=self.review['candidates'].get(key)
                if record is None:raise RuntimeError('The selected edge comparison copy must already exist')
                owner=self.full_object(record['object_id'])
                previous=next((a for a in reversed(self.review['attempts']) if a['label']==key and a['state']=='completed'),None)
                if previous is None or 'authored_object' not in previous:raise RuntimeError('Edge review requires the complete current comparison archive')
                require_exact_owner(owner,previous['authored_object'])
                macro_record=self.review['shots']['edge-macro/baseline1mm']
                macro=self.call('form_set_view',dict(view='studio',studio_command='get',shot_id=macro_record['id']))
                if macro!=macro_record['definition']:raise RuntimeError('Baseline macro changed after the matched control')
                raking=edge_raking_shot(macro)
                whole_id=next(a['shot_id'] for a in reversed(self.state['cases']['cotton']['render_attempts']) if a.get('view')=='whole' and a.get('state')=='completed')
                whole=self.call('form_set_view',dict(view='studio',studio_command='get',shot_id=whole_id))
                oldcenter=[sum(o['position'][axis] for o in cotton)/2 for axis in ('x','y','z')]
                delta=[source['position'][axis]-center for axis,center in zip(('x','y','z'),oldcenter)]
                whole=translated_shot(whole,delta,source['id'],self.args.samples,self.args.width,self.args.height)
                width=source['parameters']['width'];span=abs(cotton[1]['position']['x']-source['position']['x'])+width
                # A simple width ratio clipped the near corner at this
                # oblique view; retain that failed capture and give the full
                # diagonal silhouette25% more camera distance.
                whole['camera']['distance']*=1.25*width/span
                prefix='edge-review-'+format(self.args.normal_strength,'.3g')
                for view,template in [('whole',whole),('raking',raking)]:
                    for kind,subject in [('baseline',source),('candidate',owner)]:
                        label=kind+'-'+view
                        if self.wants_view(label):self.capture(prefix+'/'+label,template,source,subject)
                self.call('form_add_note',dict(kind='decision',text='Paper edge whole and changed-light comparison: '+source['id']+' is the unchanged1 mm source, '+owner['id']+' is the exact recorded strength'+str(self.args.normal_strength)+' comparison. Whole views recenter the original cotton whole camera/light from the two-stock midpoint onto one100 mm specimen and scale camera distance by1.25×100/290; both owners use the same relative camera and light. The first100/290 whole captures clipped the near corner and are retained as failed framing evidence. Raking views retain the recorded edge-macro camera/target/angles and change only the one area key and environment: key center offset(-60,+60,+20) mm from the front-wall midpoint, rectangle20×12 mm, original power0.04 W and color preserved; environment.12→.03. The light aims at the wall midpoint, with oblique incidence from above/side. All maps,8×2 mm repeat,caliper,face and edge response remain unchanged. This is an authored qualitative light control, not a calibrated photometric measurement.'))
            if self.args.stage in ('baseline','shoulder'):
                stage='baseline' if self.args.stage=='baseline' else 'shoulder-'+format(self.args.shoulder_radius_mm,'.3g')
                owner=finished if self.args.stage=='baseline' else self.candidate(stage+'/finished',finished)
                if self.args.stage=='shoulder':
                    baseline=self.candidate_baseline(stage+'/finished',finished)
                    expected=copy.deepcopy(baseline)
                    patches=shoulder_patches(expected,self.args.shoulder_radius_mm)
                    for finish in expected['finishes']:
                        if any(p['id']==finish['id'] for p in patches):finish['shoulderRadiusMM']=self.args.shoulder_radius_mm
                    owner=self.apply_finish_patches(owner,baseline,patches)
                    if owner['paperConstruction']!=expected:raise RuntimeError('Shoulder edit changed depth, height, artwork or optics')
                for label in ('letterpress','blind-relief','foil-highlight'):
                    if not self.wants_view(label):continue
                    self.capture(stage+'/'+label,self.source_shot('paper finish detail',label),finished,owner)
            if self.args.stage=='deboss':
                stage='shoulder-'+format(self.args.shoulder_radius_mm,'.3g')
                candidate=self.review['candidates'].get(stage+'/finished')
                if candidate is None:raise RuntimeError('Review and retain a shoulder specimen before a sign comparison')
                positive=self.full_object(candidate['object_id'])
                owner=self.candidate('deboss-'+format(self.args.shoulder_radius_mm,'.3g')+'/finished',positive)
                patches=deboss_patches(positive['paperConstruction'])
                expected=copy.deepcopy(positive['paperConstruction'])
                for finish in expected['finishes']:
                    patch=next((p for p in patches if p['id']==finish['id']),None)
                    if patch:finish.update(patch)
                owner=self.apply_finish_patches(owner,positive['paperConstruction'],patches)
                if owner['paperConstruction']!=expected:raise RuntimeError('Sign comparison changed an unrelated finish or stock value')
                prefix='deboss-'+format(self.args.shoulder_radius_mm,'.3g')
                base=self.source_shot('paper finish detail','blind-relief')
                if self.wants_view('blind-relief'):self.capture(prefix+'/blind-relief',base,finished,owner)
                for kind,subject in [('positive',positive),('negative',owner)]:
                    if not self.wants_view(kind+'-changed-light'):continue
                    delta=[subject['position'][axis]-finished['position'][axis] for axis in ('x','y','z')]
                    changed=translated_shot(base,delta,subject['id'],self.args.samples,self.args.width,self.args.height)
                    # Rotate every authored area-light position180° around its
                    # target in the paper plane. Power, size, camera and height
                    # remain fixed; the paired shoulder shadow reverses.
                    for light in changed['renderSettings']['areaLights']:
                        for axis in ('x','z'):light['positionMM'][axis]=2*light['targetMM'][axis]-light['positionMM'][axis]
                    self.capture_definition(prefix+'/'+kind+'-changed-light',changed,finished,subject,base['id'],delta)
                whole_id=next(a['shot_id'] for a in reversed(self.state['cases']['finished-cotton']['render_attempts']) if a.get('view')=='whole' and a.get('state')=='completed')
                whole=self.call('form_set_view',dict(view='studio',studio_command='get',shot_id=whole_id))
                source_pair=[self.full_object(v[0]) for v in self.state['cases']['finished-cotton']['variants']]
                oldcenter=[sum(o['position'][axis] for o in source_pair)/2 for axis in ('x','y','z')]
                newcenter=[(positive['position'][axis]+owner['position'][axis])/2 for axis in ('x','y','z')]
                delta=[b-a for a,b in zip(oldcenter,newcenter)]
                paired=translated_shot(whole,delta,owner['id'],self.args.samples,self.args.width,self.args.height)
                paired['visibility']['objectIDs']=[positive['id'],owner['id']]
                oldspan=abs(source_pair[1]['position']['x']-source_pair[0]['position']['x'])+100
                span=abs(owner['position']['x']-positive['position']['x'])+100
                paired['camera']['distance']*=span/oldspan
                if self.wants_view('whole-pair'):self.capture_definition(prefix+'/whole-pair',paired,finished,owner,whole['id'],delta)
                self.call('form_add_note',dict(kind='decision',text='Matched blind relief sign comparison: '+positive['id']+' retains positive emboss; '+owner['id']+' changes only kind to deboss, height to0 and depth to the exact prior positive height. Circle mask, selected shoulder radius, stock, letterpress, smooth foil height/optics are retained. The whole view shows both independent editable specimens; paired changed-light views rotate the same area light180° in the paper plane without altering power, camera or geometry. The Gmund reference circular impression is depressed. This is a controlled construction comparison, not a claim that an artist-estimated depth was measured from the reference.'))
            if self.args.stage=='final':
                # Final only recaptures explicitly selected preserved control
                # definitions; it never silently chooses a candidate strength.
                if not self.args.control:raise RuntimeError('Final stage requires --control labels reviewed by the user/root')
                for label in self.args.control:
                    shot=self.review['shots'].get(label)
                    if shot is None:raise RuntimeError('Unknown preserved comparison control: '+label)
                    owner=self.full_object(shot['primary_object_id'])
                    previous=next(a for a in reversed(self.review['attempts']) if a['label']==label and a['state']=='completed')
                    source=next(s['object'] for s in self.review['sources'].values() if s['object_id']==previous['source_object_id'])
                    expected=previous.get('authored_object')
                    if expected is None and owner['id']==source['id']:expected=source
                    if expected is None:
                        expected=next((r['before_object'] for r in self.review['candidates'].values() if r.get('before_object',{}).get('id')==owner['id'] and r['before_object']['paperConstruction']==previous['authored_definition']),None)
                    if expected is None:raise RuntimeError('Historical control lacks a complete owner archive; capture an explicit current revision first')
                    require_exact_owner(owner,expected)
                    self.capture_definition(label,shot['definition'],source,owner,shot['source_shot_id'],shot['translation_mm'])
            # Re-read exact original object records; all changes target copies.
            for baseline in self.review['sources'].values():
                if digest(self.full_object(baseline['object_id']))!=baseline['sha256']:raise RuntimeError('Historical specimen changed')
        except BaseException as error:
            self.state['author_runs'][-1]['authoring_failure']=str(error);self.save();raise
        finally:
            self.call('form_open_project',dict(project_id=original['id'],view='summary'))
            restored,after=self.protected(original['id'])
            proof=dict(project_id=original['id'],fields={k:after[k]==hashes[k] for k in FIELDS},before_hashes=hashes,after_hashes=after)
            write_json(self.output/'original-preservation.json',proof)
            if after!=hashes:raise RuntimeError('Protected original fields changed')
            self.state.pop('followup_restore',None);self.state['last_restored_project_id']=original['id'];self.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--stage',choices=('baseline','edge','edge-macro','edge-review','shoulder','deboss','final'),default='baseline')
    parser.add_argument('--normal-strength',type=float,default=.25)
    parser.add_argument('--shoulder-radius-mm',type=float,default=.08)
    parser.add_argument('--control',action='append',help='Exact reviewed control label to recapture in final stage')
    parser.add_argument('--view',action='append',help='Select only this stage view; repeat for a subset')
    parser.add_argument('--revision-from',help='Existing comparison-copy key to revise, retaining an immutable before archive')
    parser.add_argument('--expected-object-sha256',help='Exact complete prior object digest required for --revision-from')
    parser.add_argument('--reuse-view',action='append',help='NEW_LABEL=EXISTING_LABEL: reuse the exact saved camera/light and shot slot for the same owner')
    parser.add_argument('--app',type=Path,default=ROOT/'build/LAB.app')
    parser.add_argument('--source-state',type=Path,default=ROOT/'.local/cycles-materials/state.json')
    parser.add_argument('--output',type=Path,default=ROOT/'.local/cycles-materiality-followup')
    parser.add_argument('--samples',type=int);parser.add_argument('--width',type=int);parser.add_argument('--height',type=int)
    args=parser.parse_args();final=args.stage in ('final','edge-macro','edge-review')
    try:
        args.view=list(selected_views(args.stage,args.view));args.reuse_views=parse_reuse_views(args.reuse_view)
    except ValueError as error:parser.error(str(error))
    if args.revision_from:
        if args.stage not in ('edge','shoulder'):parser.error('Explicit copy revisions are supported only for edge and shoulder stages')
        if not args.expected_object_sha256 or len(args.expected_object_sha256)!=64 or any(c not in '0123456789abcdef' for c in args.expected_object_sha256):parser.error('Revision requires an exact lowercase SHA256 of the complete prior object')
        if args.stage=='edge' and len(args.view)!=1:parser.error('An explicit edge revision must select exactly one view/owner')
    elif args.expected_object_sha256:parser.error('--expected-object-sha256 requires --revision-from')
    args.samples=args.samples or (512 if final else 64);args.width=args.width or (3000 if final else 2000);args.height=args.height or (2000 if final else 1500)
    if not 1<=args.samples<=4096 or not (64<=args.width<=8192 and 64<=args.height<=8192 and args.width*args.height<=16777216):parser.error('Use bounded samples and output dimensions')
    if not 0<=args.normal_strength<=2 or not 0<=args.shoulder_radius_mm<=2:parser.error('Strength and shoulder radius must be0–2')
    if args.stage=='final' and not args.control:parser.error('Final stage requires explicit reviewed --control labels')
    plan=dict(stage=args.stage,apply_requested=args.apply,samples_budget=args.samples,pixels=[args.width,args.height],normal_strength=args.normal_strength,
              shoulder_radius_mm=args.shoulder_radius_mm,original_specimens='retained and hash-checked',app_mutations='none without --apply',
              views=args.view,revision_from=args.revision_from,expected_object_sha256=args.expected_object_sha256,reused_views=args.reuse_views,
              proposed_commands=['form_material import_texture','form_duplicate_object iteration','form_paper configure stock.profile.edgeAppearance',
                                 'form_paper set_finish shoulderRadiusMM','form_set_view capture/update matched translated shots','form_render start/status/result','form_add_note'],
              visual_acceptance='pending actual before/after review')
    print(json.dumps(plan,indent=2),flush=True)
    if args.apply:PaperFollowup(args,json.loads((SOURCE/'corpus.json').read_text())).execute()


if __name__=='__main__':main()
