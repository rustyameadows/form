#!/usr/bin/env python3
"""Offline ownership, copy and print-intent regressions; never contact LAB."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from author_various_quarterly import EDITORIAL, IssuePlan, MagazineAuthor, canonical, clipped_vector_repair, digest, node, remap_vector, stable, verify_k_element, verify_resume_app, verify_resume_source, raster_requires_fit, raster_frame


class QuarterlyPlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.editorial=json.loads(EDITORIAL.read_text())
        cls.plan=IssuePlan(cls.editorial)

    def test_every_word_fragment_and_visual_slot_has_authored_capacity(self):
        plan=self.plan
        self.assertEqual(len(plan.pages),52)
        self.assertEqual(len(plan.visuals),110)
        self.assertEqual(len(plan.stories),26)
        self.assertEqual(plan.copy_proof['editorial_words']['total'],6542)
        for section in self.editorial['sections']:
            actual=[v for v in plan.visuals if v['logical_page'] in section['logical_pages']]
            self.assertEqual(len(actual),len(section['works']))
            if section['kind']=='dispatches':
                story_sources={s['source'] for s in plan.stories}
                self.assertTrue(all(module['body'] in story_sources for module in section['modules']))
        for story in plan.stories:
            self.assertGreater(len(story['source']),0)
            self.assertTrue(story['frames'])
            self.assertTrue(all(frame['element_id'] in {e['id'] for e in plan.pages[frame['logical_page']]['elements']} for frame in story['frames']))

    def test_one_canonical_wide_hero_is_owned_by_white_page_twenty(self):
        heroes=[v for v in self.plan.visuals if v.get('across_pages')]
        self.assertEqual(len(heroes),1)
        hero=heroes[0]
        self.assertEqual(hero['key'],'useful_gap_01')
        self.assertEqual(hero['logical_page'],20)
        self.assertEqual(hero['across_pages'],[20,21])
        self.assertGreater(hero['box_mm'][0]+hero['box_mm'][2],215.9)
        self.assertFalse(set(hero['across_pages']) & self.plan.black_pages)
        self.assertNotIn(hero,self.plan.pages[21]['placements'])

    def test_explicit_wide_view_layout_retains_the_complete_single_model_without_copy_changes(self):
        whole=[p for p in self.plan.visuals if p.get('image_role')=='whole-view']
        self.assertEqual([p['key'] for p in whole],['various_back_05'])
        placement=whole[0];self.assertEqual(placement['title'],'Wide view')
        self.assertEqual(placement['caption'],'The complete silhouette establishes shared proportions.')
        self.assertEqual(placement['box_mm'],[80.5,22,54.9,84])
        source=dict(width_px=2000,height_px=1600)
        self.assertTrue(raster_requires_fit(source,placement))
        frame,crop=raster_frame(source,placement['box_mm'],fit=raster_requires_fit(source,placement))
        self.assertIsNone(crop)
        for name,value in zip(('x','y','width','height'),(80.5,42.04,54.9,43.92)):self.assertAlmostEqual(frame[name],value)
        self.assertEqual(self.plan.copy_proof['editorial_words']['total'],6542)

    def test_parent_stock_assignment_has_exact_cover_and_interior_faces(self):
        self.assertEqual(sorted(self.plan.black_pages),[1,2,9,10,17,18,25,26,27,28,35,36,43,44,51,52])
        self.assertEqual({i-2 for i in self.plan.black_pages if 3<=i<=50},{7,8,15,16,23,24,25,26,33,34,41,42})
        for page in self.plan.pages.values():
            # There is no full-page stock-tint rectangle anywhere in the offline source plan.
            self.assertFalse(any(e['kind']=='rectangle' and e['height']>1 for e in page['elements']))

    def test_editable_vector_placement_namespaces_sources_and_only_rebinds_black_ink(self):
        source=node('rectangle','colored-source',0,0,100,100,color='#2F6B8E')
        stroke=dict(color='#C43A22',width=.6)
        source['stroke']=stroke
        artwork=dict(elements=[source])
        original=copy.deepcopy(artwork)
        a=dict(key='placement-a',box_mm=[18,25,90,45])
        b=dict(key='placement-b',box_mm=[18,25,90,45])
        white=remap_vector(artwork,a)
        black=remap_vector(artwork,b,stable('process-k'),'#171717')
        self.assertEqual(artwork,original)
        self.assertEqual(white[1]['color'],'#2F6B8E')
        self.assertEqual(white[1]['stroke']['color'],'#C43A22')
        self.assertNotIn('fillSwatchID',white[1])
        self.assertEqual(black[1]['fillSwatchID'],stable('process-k'))
        self.assertEqual(black[1]['stroke']['swatchID'],stable('process-k'))
        self.assertEqual(white[0]['width'],white[0]['height'])
        self.assertEqual(white[0]['width'],45)
        self.assertNotEqual(white[1]['id'],black[1]['id'])
        self.assertEqual(white[1]['parentID'],white[0]['id'])

    def test_implicit_line_stroke_becomes_explicit_process_k_consumer(self):
        ink=stable('k')
        source=node('line','implicit-line',0,0,100,.001)
        placed=remap_vector(dict(elements=[source]),dict(key='line-slot',box_mm=[18,18,80,80]),ink)
        self.assertEqual(placed[1]['stroke']['swatchID'],ink)
        self.assertEqual(placed[1]['stroke']['width'],.5)
        self.assertNotIn('stroke',source)

    def test_unflattened_black_alternatives_reject_raster_and_unsupported_paint(self):
        placement=dict(key='bad',box_mm=[18,18,80,80])
        with self.assertRaisesRegex(AssertionError,'editable vector'):
            remap_vector(dict(elements=[node('image','bad-image',0,0,100,100)]),placement,stable('k'))
        value=node('rectangle','gradient',0,0,100,100,gradient=dict(stops=[]))
        with self.assertRaisesRegex(AssertionError,'contour/fill/stroke'):
            remap_vector(dict(elements=[value]),placement,stable('k'))

    def test_empty_bound_frames_resolve_ink_on_the_actual_rich_story_without_excusing_rgb(self):
        ink=stable('k');story_id=stable('story')
        frame=node('text','empty-capacity',18,20,90,100,storyFrame=dict(storyID=story_id))
        source=dict(id=story_id,text='Complete words',fillSwatchID=ink,textRuns=[dict(location=0,length=8,swatchID=ink)])
        verify_k_element(frame,ink,{story_id:source})
        self.assertNotIn('fillSwatchID',frame)
        for changed in [dict(source,fillSwatchID=None),dict(source,textRuns=[dict(location=0,length=8,swatchID=None)])]:
            with self.assertRaisesRegex(AssertionError,'processK'):verify_k_element(frame,ink,{story_id:changed})
        with self.assertRaisesRegex(AssertionError,'missing rich story'):verify_k_element(frame,ink,{})
        with self.assertRaisesRegex(AssertionError,'unpainted'):verify_k_element(dict(frame,text='Duplicated words'),ink,{story_id:source})
        with self.assertRaisesRegex(AssertionError,'processK'):verify_k_element(node('rectangle','rgb',18,18,30,40),ink,{})

    def test_resume_checks_exact_project_source_hash_membership_and_editorial_story_sources(self):
        project_id=stable('project');publication=stable('publication')
        pages=[stable('resume-page-'+str(i)) for i in range(52)]
        snapshot=dict(id=project_id,objects=[],publications=[dict(id=publication,pages=[dict(objectID=p) for p in pages])])
        report=dict(project_id=project_id,publication_id=publication,page_ids=pages,placements=[{}]*110,
                    stories=[dict(key=s['key'],source_sha256=s['source_sha256']) for s in self.plan.stories])
        expected=digest(canonical(snapshot))
        self.assertEqual(verify_resume_source(report,snapshot,self.plan,project_id,expected),expected)
        changed=copy.deepcopy(snapshot);changed['objects']=[dict(id=stable('unexpected'))]
        with self.assertRaisesRegex(AssertionError,'hash'):verify_resume_source(report,changed,self.plan,project_id,expected)
        with self.assertRaisesRegex(AssertionError,'UUID'):verify_resume_source(report,snapshot,self.plan,stable('other-project'),expected)
        changed_report=copy.deepcopy(report);changed_report['stories'][0]['source_sha256']='0'*64
        with self.assertRaisesRegex(AssertionError,'editorial'):verify_resume_source(changed_report,snapshot,self.plan,project_id,expected)

    def test_prior_export_report_can_resume_an_explicitly_reviewed_native_fit_snapshot(self):
        project_id=stable('reviewed-project');publication=stable('reviewed-publication')
        pages=[stable('reviewed-page-'+str(i)) for i in range(52)]
        image=node('image','reviewed-wide-photo',80.5,22,54.9,84,asset='same-project-owned.png',
                   imageCrop=dict(x=.23857142857142857,y=0,width=.5228571428571429,height=1))
        before=dict(id=project_id,objects=[dict(id=pages[47],artwork=dict(elements=[image]))],
                    publications=[dict(id=publication,pages=[dict(objectID=p) for p in pages])])
        report=dict(project_id=project_id,publication_id=publication,page_ids=pages,placements=[{}]*110,
                    stories=[dict(key=s['key'],source_sha256=s['source_sha256']) for s in self.plan.stories],
                    canonical_source_sha256=digest(canonical(before)))
        reviewed=copy.deepcopy(before);actual=reviewed['objects'][0]['artwork']['elements'][0]
        actual.update(x=80.5,y=42.04,width=54.9,height=43.92);actual.pop('imageCrop')
        current_hash=digest(canonical(reviewed))
        self.assertNotEqual(current_hash,report['canonical_source_sha256'])
        self.assertEqual(verify_resume_source(report,reviewed,self.plan,project_id,current_hash),current_hash)
        with self.assertRaisesRegex(AssertionError,'hash'):
            verify_resume_source(report,reviewed,self.plan,project_id,report['canonical_source_sha256'])
        self.assertEqual(before['objects'][0]['artwork']['elements'][0]['asset'],actual['asset'])

    def test_resuming_with_new_app_requires_its_explicit_verified_binary_hash(self):
        import hashlib
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder)/'LAB.app';binary=app/'Contents/MacOS/LAB';binary.parent.mkdir(parents=True);binary.write_bytes(b'prior verified binary')
            old=hashlib.sha256(binary.read_bytes()).hexdigest();report=dict(app=str(app),app_sha256=old)
            self.assertFalse(verify_resume_app(report,app)['explicit_verified_update'])
            binary.write_bytes(b'new separately verified binary');new=hashlib.sha256(binary.read_bytes()).hexdigest()
            with self.assertRaisesRegex(AssertionError,'verified SHA256'):verify_resume_app(report,app)
            with self.assertRaisesRegex(AssertionError,'verified SHA256'):verify_resume_app(report,app,'0'*64)
            accepted=verify_resume_app(report,app,new)
            self.assertEqual(accepted['prior_app_sha256'],old);self.assertEqual(accepted['app_sha256'],new)
            self.assertTrue(accepted['explicit_verified_update']);self.assertEqual(report['app_sha256'],old)

    def test_verify_export_resume_rejects_authoring_before_any_helper_call(self):
        class FakeSession:
            def __init__(self):self.calls=[]
            def call(self,name,args):self.calls.append((name,args));return {'read':True}
        author=object.__new__(MagazineAuthor);author.resuming=True;author.report={'project_id':stable('project')};author.session=FakeSession()
        for name,args in [('form_add_object',{}),('form_story',dict(command='edit')),('form_open_project',dict(project_id=stable('wrong'))),('form_set_view',dict(view='studio'))]:
            with self.assertRaisesRegex(AssertionError,'refuses authoring'):author.call(name,**args)
        self.assertEqual(author.session.calls,[])
        self.assertEqual(author.call('form_story',command='get',story_id=stable('story')),{'read':True})
        self.assertEqual(len(author.session.calls),1)

    def test_real_frame_mask_bounds_overflow_without_trimming_editable_words(self):
        source=node('text','oversized-poster',0,0,500,100,'SLOW / DOWN',size=95)
        placement=dict(key='poster-proof',box_mm=[18,22,80,40])
        art=remap_vector(dict(elements=[source]),placement,stable('k'))
        root=art[0];mask=next(e for e in art if e['id']==root['clipID']);copy_node=next(e for e in art if e.get('parentID')==root['id'])
        self.assertEqual([mask[k] for k in ('x','y','width','height')],placement['box_mm'])
        self.assertEqual(mask.get('parentID'),root.get('parentID'));self.assertFalse(mask['fillEnabled'])
        self.assertNotIn('stroke',mask);self.assertNotIn('fillSwatchID',mask)
        self.assertEqual(copy_node['text'],source['text']);self.assertEqual(copy_node['width'],500)
        self.assertGreater(root['x']+copy_node['width']*root['width']/100,mask['x']+mask['width'])
        for element in art:verify_k_element(element,stable('k'),{})
        painted=copy.deepcopy(copy_node);painted['fillSwatchID']=None
        with self.assertRaisesRegex(AssertionError,'processK'):verify_k_element(painted,stable('k'),{})

    def test_existing_vector_repair_changes_only_selected_root_clip_and_new_mask(self):
        placement=next(p for p in self.plan.visuals if p['logical_page'] in self.plan.black_pages)
        key=placement['key'];original=remap_vector(dict(elements=[node('text','native-edited',0,0,400,100,'Keep native words')]),placement,stable('k'))
        root=original[0];mask_id=root.pop('clipID');original=[e for e in original if e['id']!=mask_id]
        object_id=stable('repair-page');other=node('text','caption',18,240,150,20,'Keep the exact native caption')
        project=dict(id=stable('repair-project'),objects=[dict(id=object_id,artwork=dict(elements=original+[other],backgroundOpacity=0))],
                     textStories=[dict(id=stable('unrelated-story'),text='Complete original story')],studioPresentation=dict(scenes=[dict(id=stable('scene'))]))
        before=copy.deepcopy(project)
        report=dict(placements=[dict(placement,actual_kind='vector',object_id=object_id,element_ids=[e['id'] for e in original])])
        candidate,changes=clipped_vector_repair(project,report,self.plan,[key])
        self.assertEqual(project,before);self.assertEqual(candidate['textStories'],project['textStories'])
        self.assertEqual(candidate['studioPresentation'],project['studioPresentation'])
        elements=candidate['objects'][0]['artwork']['elements']
        self.assertEqual(next(e for e in elements if e['id']==other['id']),other)
        self.assertEqual(next(e for e in elements if e.get('parentID')==root['id'])['text'],'Keep native words')
        self.assertEqual(next(e for e in elements if e['id']==root['id'])['clipID'],mask_id)
        self.assertEqual(len(elements),len(original)+2);self.assertEqual(len(changes),1)
        bad=copy.deepcopy(project);bad['objects'][0]['artwork']['elements'][0]['clipID']=stable('native-clip')
        with self.assertRaisesRegex(AssertionError,'native clip'):clipped_vector_repair(bad,report,self.plan,[key])
        self.assertEqual(project,before)

    def test_exported_artwork_keeps_stock_nonprinting_and_safe_guides_editable(self):
        author=object.__new__(MagazineAuthor);author.ink=stable('ink');author.ink_color='#171717';author.profile=None
        art=author.artwork([node('text','source',18,18,50,10,'A clear source')],position=(100,200))
        self.assertEqual(art['backgroundOpacity'],0)
        self.assertEqual(art['bleed'],0)
        self.assertEqual(art['safeInset'],18)
        self.assertFalse(art['snapEnabled'])
        self.assertEqual(art['canvasPosition'],dict(x=100,y=200))
        self.assertEqual(art['elements'][0]['fillSwatchID'],author.ink)


if __name__=='__main__':unittest.main()
