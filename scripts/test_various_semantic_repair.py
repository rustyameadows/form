#!/usr/bin/env python3
"""Offline semantic repair regressions; no app, helper, socket or files in a project."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from author_various_quarterly import (EDITORIAL, MagazineAuthor, canonical, digest, editorial_repair_transition,
    node, raster_frame, raster_requires_fit, remap_vector, semantic_asset_repair, stable, verify_k_element, verify_library_scope, native_generated_element, verify_recorded_semantic_batch, NATIVE_TYPOGRAPHY_DEFAULTS, projection_note_repair)


def fixture():
    ink=stable('test-ink');records=[];visuals=[];old_assets={};assets={};patches={}
    black=dict(id=stable('black-page'),artwork=dict(elements=[],backgroundOpacity=0,bleed=0))
    white=dict(id=stable('white-page'),artwork=dict(elements=[],backgroundOpacity=0,bleed=0))
    source=lambda key:dict(elements=[node('rectangle',key+'-source',0,0,100,100,color='#2477AD')])
    def add(key,old,new,page,box):
        obj=black if page==1 else white
        placement=dict(key=key,logical_page=page,box_mm=box,title='Across the gutter' if key=='room_accident_04' else key,caption='')
        if old['kind']=='vector':elements=remap_vector(old['artwork'],placement,ink if page==1 else None)
        else:
            x,y,w,h=box;image=node('image',key+'-original-image',x,y,w,h,color='#FFFFFF',asset='original-'+key+'.png',imageCrop=dict(x=0,y=.2,width=1,height=.6))
            elements=[image]
        obj['artwork']['elements']+=elements
        record=dict(placement,object_id=obj['id'],actual_kind=old['kind'],manifest_entry=old,element_ids=[e['id'] for e in elements])
        if old['kind']=='raster':record.update(project_asset=elements[0]['asset'],original_sha256=old['sha256'])
        old_assets[key]=old;assets[key]=new;records.append(record);visuals.append(placement)
        if old!=new:patches[key]=dict(prior_entry_sha256=digest(old),entry=new,reason='Explicit reviewed subject correction.')
    vec=lambda key:dict(kind='vector',artwork=source(key),black_only_artwork=source(key))
    ras=lambda key,group=False:dict(kind='raster',sha256=key*64,path='/tmp/'+key+'.png',width_px=2400,height_px=1333,source_instances=[{},{}] if group else [])
    add('black-diagram',vec('old-black'),vec('literal-black'),1,[18,26,179.9,35])
    add('room_accident_04',vec('old-fold'),vec('actual-fold'),2,[18,26,179.9,35])
    add('vector-to-raster',vec('old-vector'),ras('a'),2,[18,80,90,50])
    add('raster-to-vector',ras('b'),vec('new-vector'),2,[116,80,80,50])
    add('group-photo',ras('c',True),ras('c',True),2,[18,150,179.9,35])
    old_caption='Across the gutter\nOne continuous image crosses two page crops.'
    white['artwork']['elements'] += [node('text','room_accident_04-caption',18,65,179.9,15,old_caption),
                                    node('text','unrelated-caption',18,140,170,10,'Native unrelated caption'),
                                    node('text','linked-body-frame',18,210,80,40,'',storyFrame=dict(storyID=stable('shared-story'))),
                                    node('rectangle','native-manual-mark',177,212,4,4,color='#E8B228',rotation=13)]
    project=dict(id=stable('project'),objects=[black,white],textStories=[dict(id=stable('shared-story'),text='Complete original body, untrimmed.',textRuns=[dict(location=9,length=8,weight='bold')])],publications=[dict(id=stable('doc'))],studioPresentation=dict(scenes=[dict(name='Independent native scene',instances=[dict(name='Open copy',sheetPose=dict(activeSpread=10))])]))
    plan=SimpleNamespace(visuals=visuals,black_pages={1})
    report=dict(placements=records)
    revision=dict(key='room_accident_04',before='One continuous image crosses two page crops.',after='A folded view returns within a single page.')
    names={'a'*64:'new-a.png','b'*64:'original-raster-to-vector.png','c'*64:'original-group-photo.png'}
    return project,report,plan,dict(version=1,patches=patches),assets,names,ink,revision


class VariousSemanticRepairTests(unittest.TestCase):
    def test_editorial_revision_reconstructs_exact_prior_bytes_and_preserves_all_body_sources(self):
        editorial=json.loads(EDITORIAL.read_text());revision=json.loads(EDITORIAL.with_name('editorial-revision.json').read_text())
        prior=editorial_repair_transition(editorial,revision)
        self.assertEqual(hashlib.sha256((json.dumps(prior,ensure_ascii=False,indent=2)+'\n').encode()).hexdigest(),revision['prior_editorial_sha256'])
        self.assertEqual(prior['word_counts']['total'],6541);self.assertEqual(editorial['word_counts']['total'],6542)
        self.assertEqual([s['body'] for s in prior['sections']],[s['body'] for s in editorial['sections']])
        changed=copy.deepcopy(editorial);changed['sections'][0]['body'][0]+=' Incorrect rewrite.'
        bad_revision=copy.deepcopy(revision);bad_revision['revised_editorial_sha256']=hashlib.sha256((json.dumps(changed,ensure_ascii=False,indent=2)+'\n').encode()).hexdigest()
        with self.assertRaisesRegex(AssertionError,'more than'):editorial_repair_transition(changed,bad_revision)

    def test_source_aspect_and_group_photo_fit_preserve_whole_originals_inside_the_authored_frame(self):
        source=dict(source_size_mm=dict(x=100,y=28),elements=[node('rectangle','three-real-views',0,0,100,28)])
        result=remap_vector(source,dict(key='native-views',box_mm=[18,216,179.9,35]))
        self.assertEqual(result[0]['contentSize'],dict(x=100,y=28));self.assertEqual(result[0]['width'],125);self.assertEqual(result[0]['height'],35)
        self.assertAlmostEqual(result[0]['x'],45.45);self.assertEqual(result[-1]['width'],179.9)
        frame,crop=raster_frame(dict(width_px=2400,height_px=1333),[18,216,179.9,35],fit=True)
        self.assertIsNone(crop);self.assertEqual(frame['height'],35);self.assertAlmostEqual(frame['width']/frame['height'],2400/1333)
        self.assertGreater(frame['x'],18);self.assertLess(frame['x']+frame['width'],197.9)
        with self.assertRaises(AssertionError):remap_vector(dict(source,source_size_mm=dict(x=100,y=0)),dict(key='invalid',box_mm=[0,0,10,10]))

    def test_whole_view_role_fits_an_unchanged_single_photo_without_resetting_detail_photos(self):
        project,report,plan,patch,assets,names,ink,revision=fixture()
        key='raster-to-vector';record=next(r for r in report['placements'] if r['key']==key)
        entry=copy.deepcopy(record['manifest_entry']);entry['width_px']=2000;entry['height_px']=1600
        record['manifest_entry']=copy.deepcopy(entry);assets[key]=entry;patch['patches'].pop(key)
        placement=next(p for p in plan.visuals if p['key']==key)
        placement['image_role']='whole-view';placement['box_mm']=[80.5,22,54.9,84];record['box_mm']=placement['box_mm'][:]
        self.assertTrue(raster_requires_fit(entry,placement))
        self.assertFalse(raster_requires_fit(entry,dict(placement,image_role='detail')))
        self.assertFalse(raster_requires_fit(entry,dict(box_mm=placement['box_mm'],title='Wide view')),
                         'Titles must not silently change an intentional crop; the layout role is explicit.')
        self.assertTrue(raster_requires_fit(dict(entry,source_instances=[{},{}]),dict(image_role='detail')))
        original=copy.deepcopy(project);old=next(e for o in project['objects'] for e in o['artwork']['elements'] if e['id']==record['element_ids'][0])
        candidate,records,proof=semantic_asset_repair(project,report,plan,patch,assets,names,ink,'#000000',revision)
        actual=next(e for o in candidate['objects'] for e in o['artwork']['elements'] if e['id']==old['id'])
        self.assertEqual(project,original);self.assertNotIn('imageCrop',actual)
        for name,value in zip(('x','y','width','height'),(80.5,42.04,54.9,43.92)):self.assertAlmostEqual(actual[name],value)
        self.assertEqual({k:v for k,v in actual.items() if k not in ('x','y','width','height','imageCrop')},
                         {k:v for k,v in old.items() if k not in ('x','y','width','height','imageCrop')})
        self.assertEqual(next(r for r in records if r['key']==key)['image_placement'],'fit')
        self.assertFalse(next(r for r in proof['placements'] if r['key']==key)['semantic_replacement'])

    def test_explicit_subject_changes_preserve_story_frames_other_captions_native_edits_and_true_k(self):
        project,report,plan,patch,assets,names,ink,revision=fixture();before=copy.deepcopy(project)
        candidate,records,proof=semantic_asset_repair(project,report,plan,patch,assets,names,ink,'#1A1919',revision)
        self.assertEqual(project,before);self.assertEqual(candidate['textStories'],project['textStories'])
        self.assertEqual(candidate['studioPresentation'],project['studioPresentation']);self.assertEqual(candidate['publications'],project['publications'])
        old={e['id']:e for o in project['objects'] for e in o['artwork']['elements']};new={e['id']:e for o in candidate['objects'] for e in o['artwork']['elements']}
        for key in ('unrelated-caption','linked-body-frame','native-manual-mark'):self.assertEqual(old[stable(key)],new[stable(key)])
        caption=stable('room_accident_04-caption');self.assertEqual(new[caption]['text'],'Across the gutter\nA folded view returns within a single page.')
        self.assertEqual({k:v for k,v in old[caption].items() if k!='text'},{k:v for k,v in new[caption].items() if k!='text'})
        by_key={r['key']:r for r in records}
        self.assertEqual(by_key['vector-to-raster']['actual_kind'],'raster');self.assertEqual(by_key['vector-to-raster']['project_asset'],'new-a.png')
        self.assertEqual(by_key['raster-to-vector']['actual_kind'],'vector')
        self.assertEqual(by_key['group-photo']['element_ids'],next(r for r in report['placements'] if r['key']=='group-photo')['element_ids'])
        group=new[by_key['group-photo']['element_ids'][0]];self.assertNotIn('imageCrop',group);self.assertEqual(group['height'],35)
        self.assertAlmostEqual(group['width']/group['height'],2400/1333)
        for identity in by_key['black-diagram']['element_ids']:verify_k_element(new[identity],ink,{})
        self.assertEqual(len(proof['placements']),5)

    def test_changed_attribution_or_unrecorded_native_children_reject_without_mutating_source(self):
        project,report,plan,patch,assets,names,ink,revision=fixture();before=copy.deepcopy(project)
        bad=copy.deepcopy(patch);bad['patches']['black-diagram']['prior_entry_sha256']='wrong'
        with self.assertRaisesRegex(AssertionError,'attribution'):semantic_asset_repair(project,report,plan,bad,assets,names,ink,'#000000',revision)
        self.assertEqual(project,before)
        root=stable('room_accident_04-placed-vector');project['objects'][1]['artwork']['elements'].append(node('text','native-new-child',0,0,15,10,'Native edit',parentID=root))
        before=copy.deepcopy(project)
        with self.assertRaisesRegex(AssertionError,'Unrecorded'):semantic_asset_repair(project,report,plan,patch,assets,names,ink,'#000000',revision)
        self.assertEqual(project,before)

    def test_nonprinting_alternative_updates_do_not_reset_an_unchanged_native_photo(self):
        project,report,plan,patch,assets,names,ink,revision=fixture()
        record=next(r for r in report['placements'] if r['key']=='raster-to-vector')
        old=record['manifest_entry'];updated=copy.deepcopy(old);updated['black_only_artwork']=dict(elements=[node('rectangle','unused-alternative',0,0,20,20)])
        assets['raster-to-vector']=updated;patch['patches']['raster-to-vector']=dict(prior_entry_sha256=digest(old),entry=updated,reason='Unused K alternative only.')
        image=next(e for o in project['objects'] for e in o['artwork']['elements'] if e['id']==record['element_ids'][0]);image['imageCrop']=dict(x=.1,y=.2,width=.7,height=.5);image['imageAdjustments']=dict(brightness=.17,contrast=1.2,saturation=.7)
        preserved=copy.deepcopy(image)
        candidate,records,proof=semantic_asset_repair(project,report,plan,patch,assets,names,ink,'#000000',revision)
        actual=next(e for o in candidate['objects'] for e in o['artwork']['elements'] if e['id']==image['id'])
        self.assertEqual(actual,preserved)
        self.assertFalse(next(p for p in proof['placements'] if p['key']=='raster-to-vector')['source_changed'])

    def test_generated_native_dto_has_exact_typography_defaults_without_erasing_explicit_style(self):
        source=node('text','sparse-technical-label',0,0,40,10,'96 mm',fontSize=7,stroke=None,
                    typography=dict(fontName='HelveticaNeue',leading=9.2,tracking=.37,alignment='right',features={'6':1}))
        original=copy.deepcopy(source);typed=native_generated_element(source)
        self.assertEqual(source,original);self.assertNotIn('stroke',typed)
        self.assertEqual(typed['typography']['tracking'],.37);self.assertEqual(typed['typography']['alignment'],'right')
        self.assertEqual(typed['typography']['leading'],9.2);self.assertEqual(typed['typography']['features'],{'6':1})
        self.assertEqual(typed['typography']['horizontalScale'],100);self.assertEqual(typed['typography']['paragraphAfter'],0)
        self.assertEqual(typed['typography']['pairKerning'],{});self.assertFalse(typed['typography']['underline'])

    def test_applied_receipt_accepts_only_generated_dto_defaults_and_rejects_unrelated_or_real_changes(self):
        project,report,plan,patch,assets,names,ink,revision=fixture()
        assets['room_accident_04']['artwork']['elements'].append(node('text','generated-subject-label',0,0,30,10,'Actual fold'))
        expected,_,proof=semantic_asset_repair(project,report,plan,patch,assets,names,ink,'#000000',revision)
        generated={identity for p in proof['placements'] if p['source_changed'] for identity in p['new_ids']}
        affected={p['object_id'] for p in proof['placements'] if p['source_changed']}
        raw=copy.deepcopy(expected)
        for obj in raw['objects']:
            for element in obj['artwork']['elements']:
                if element['id'] not in generated:continue
                element['stroke']=None
                if element.get('typography'):
                    for key,default in NATIVE_TYPOGRAPHY_DEFAULTS.items():
                        if key not in ('fontName','leading') and element['typography'].get(key)==default:element['typography'].pop(key)
        operations=[dict(name='form_set_artwork',arguments=dict(object_id=o['id'],artwork=o['artwork'])) for o in raw['objects'] if o['id'] in affected]
        receipt=verify_recorded_semantic_batch(project,expected,operations,proof,expected)
        self.assertEqual(receipt['generated_layer_count'],len(generated))
        unrelated=copy.deepcopy(expected)
        text=next(e for o in unrelated['objects'] for e in o['artwork']['elements'] if e['id']==stable('unrelated-caption'))
        text['typography']['horizontalScale']=100
        with self.assertRaisesRegex(AssertionError,'Applied native source'):verify_recorded_semantic_batch(project,unrelated,operations,proof,expected)
        changed=copy.deepcopy(expected)
        element=next(e for o in changed['objects'] for e in o['artwork']['elements'] if e['id'] in generated and e.get('typography'))
        element['typography']['tracking']+=.1
        with self.assertRaisesRegex(AssertionError,'Applied native source'):verify_recorded_semantic_batch(project,changed,operations,proof,expected)
        invalid=copy.deepcopy(operations);invalid[0]['name']='form_delete_objects'
        with self.assertRaisesRegex(AssertionError,'unapproved'):verify_recorded_semantic_batch(project,expected,invalid,proof,expected)

    def test_projection_note_fit_changes_only_point_size_and_matching_leading_from_native_diagnostics(self):
        ink=stable('ink');long=node('text','actual/projection-note',8,94,90,6,'PARAMETER WIREFRAME / BEVELS OMITTED',12,
            typography=dict(fontName='HelveticaNeue-Bold',leading=13.92,tracking=.13),fillSwatchID=ink,parentID=stable('owner'),opacity=1)
        short=node('text','short/projection-note',8,94,90,6,'DIAMETRAL SECTION',12,typography=dict(fontName='HelveticaNeue-Bold',leading=13.92),fillSwatchID=ink)
        body=node('text','body-frame',18,40,80,120,'All original body copy stays.',fontSize=11)
        page=stable('page');project=dict(id=stable('project'),objects=[dict(id=page,artwork=dict(elements=[long,short,body]))],textStories=[dict(text='Canonical shared source')])
        diagnostics=[dict(issues=[dict(severity='error',message='Text is overset or wider than its frame. Add capacity before physical output.',object_id=page,element_id=long['id'])])]
        original=copy.deepcopy(project);candidate,changes=projection_note_repair(project,diagnostics)
        self.assertEqual(project,original);self.assertEqual(len(changes),1)
        fixed=candidate['objects'][0]['artwork']['elements'][0]
        self.assertEqual(fixed['fontSize'],10);self.assertEqual(fixed['typography']['leading'],11.6)
        self.assertEqual(fixed['text'],long['text']);self.assertEqual(fixed['parentID'],long['parentID']);self.assertEqual(fixed['fillSwatchID'],ink)
        restored=copy.deepcopy(fixed);restored['fontSize']=12;restored['typography']['leading']=13.92;self.assertEqual(restored,long)
        self.assertEqual(candidate['objects'][0]['artwork']['elements'][1:],[short,body]);self.assertEqual(candidate['textStories'],project['textStories'])
        wrong=copy.deepcopy(diagnostics);wrong[0]['issues'][0]['element_id']=body['id']
        with self.assertRaisesRegex(AssertionError,'not a local'):projection_note_repair(project,wrong)
        changed=copy.deepcopy(project);changed['objects'][0]['artwork']['elements'][0]['width']=89
        with self.assertRaisesRegex(AssertionError,'changed since'):projection_note_repair(changed,diagnostics)

    def test_normal_library_requires_explicit_existing_project_scope_and_all_source_guards(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);library=root/'NormalLibrary';report=root/'report.json';snapshot=root/'public-source.json'
            report.write_text('{}');snapshot.write_text('{}');source_hash='a'*64;resume=(report,snapshot,source_hash)
            with self.assertRaises(AssertionError):verify_library_scope(library)
            with self.assertRaises(AssertionError):verify_library_scope(library,resume=resume,project_id=stable('project'),expected_source_hash=source_hash)
            with self.assertRaises(AssertionError):verify_library_scope(library,verified_existing=True)
            with self.assertRaises(AssertionError):verify_library_scope(library,verified_existing=True,resume=resume,project_id=stable('project'),expected_source_hash='wrong')
            with self.assertRaises(AssertionError):verify_library_scope(library,verified_existing=True,resume=resume,project_id='other',expected_source_hash=source_hash)
            self.assertEqual(verify_library_scope(library,verified_existing=True,resume=resume,project_id=stable('project'),expected_source_hash=source_hash),'verified_existing_project')
            self.assertEqual(verify_library_scope(root/'.local'/'validation'/'Library'),'disposable_validation')
            self.assertFalse(library.exists(),'A scope check must never create or modify the normal library')

    def test_resuming_cannot_use_staging_or_undo_without_the_exact_guarded_phase(self):
        calls=[];author=MagazineAuthor.__new__(MagazineAuthor);author.resuming=True;author.report=dict(project_id=stable('project'));author.repairing=False;author.semantic_phase=None
        author.session=SimpleNamespace(call=lambda tool,args:calls.append((tool,args)))
        with self.assertRaises(AssertionError):author.call('form_import_image',object_id='wrong',path='/tmp/source.png')
        with self.assertRaises(AssertionError):author.call('form_undo')
        author.semantic_phase='stage';author._staging_arguments=dict(object_id='expected',element_id='specific-image',path='/tmp/exact.png')
        author.call('form_import_image',**author._staging_arguments)
        with self.assertRaises(AssertionError):author.call('form_import_image',**dict(author._staging_arguments,path='/tmp/other.png'))
        self.assertEqual(len(calls),1)


if __name__=='__main__':unittest.main()
