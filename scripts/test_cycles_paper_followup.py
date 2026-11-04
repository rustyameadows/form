import copy
import math
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from author_cycles_paper_followup import PaperFollowup, deboss_patches, edge_macro_shot, edge_raking_shot, edge_patch, finish_patch_states, next_candidate_position, parse_reuse_views, require_exact_owner, selected_views, shoulder_patches, translated_shot
from prepare_cycles_paper_edges import field


class PaperFollowupPlanTests(unittest.TestCase):
    def test_raking_pair_keeps_camera_target_color_and_power(self):
        source=dict(camera=dict(distance=.15,target=dict(x=0,y=.005,z=.35)),renderSettings=dict(environmentStrength=.12,
            areaLights=[dict(positionMM=dict(x=-40,y=60,z=105),targetMM=dict(x=0,y=.5,z=35),sizeMM=dict(x=80,y=50),powerWatts=.04,color='#FFFFFF')]))
        before=copy.deepcopy(source);changed=edge_raking_shot(source);light=changed['renderSettings']['areaLights'][0]
        self.assertEqual(changed['camera'],source['camera']);self.assertEqual(source,before)
        self.assertEqual(light['positionMM'],dict(x=-60,y=60.5,z=55))
        self.assertEqual(light['targetMM'],dict(x=0,y=.5,z=35));self.assertEqual(light['powerWatts'],.04)
        self.assertEqual(light['color'],'#FFFFFF');self.assertEqual(light['sizeMM'],dict(x=20,y=12))
        self.assertEqual(changed['renderSettings']['environmentStrength'],.03)

    def test_revision_aliases_do_not_expand_physical_comparison_layout(self):
        records={key:dict(object_id=owner) for key,owner in [('edge.25','a'),('thin','b'),('shoulder.08','c')]}
        expected=next_candidate_position([0,0,1000],records)
        records.update({'edge1':dict(object_id='a'),'shoulder.16':dict(object_id='c')})
        self.assertEqual(next_candidate_position([0,0,1000],records),expected)
        self.assertEqual(expected,[510,0,1000])

    def test_view_subsets_and_slot_aliases_reject_ambiguous_input(self):
        self.assertEqual(selected_views('shoulder',['blind-relief','letterpress']),('letterpress','blind-relief'))
        self.assertEqual(parse_reuse_views(['new/blind=old/blind']),{'new/blind':'old/blind'})
        for invalid in (['missing'],['letterpress','letterpress']):
            with self.assertRaises(ValueError):selected_views('shoulder',invalid)
        for invalid in (['missing'],['=old'],['new='],['a=b','a=c']):
            with self.assertRaises(ValueError):parse_reuse_views(invalid)

    def test_old_final_label_cannot_render_a_revised_owner(self):
        recorded=dict(id='same-copy',name='earlier',position=dict(x=0,y=0,z=0),paperConstruction=dict(stock=dict(profile=dict(edgeAppearance=dict(normalStrength=.25)))))
        current=copy.deepcopy(recorded)
        require_exact_owner(current,recorded)
        current['paperConstruction']['stock']['profile']['edgeAppearance']['normalStrength']=1
        with self.assertRaises(RuntimeError):require_exact_owner(current,recorded)
        current=copy.deepcopy(recorded);current['position']['x']=1
        with self.assertRaises(RuntimeError):require_exact_owner(current,recorded)

    def test_reused_view_rejects_unrecorded_camera_change_before_render(self):
        old=dict(id='slot',camera=dict(distance=.15),renderSettings=dict(samples=512))
        client=PaperFollowup.__new__(PaperFollowup)
        client.args=SimpleNamespace(reuse_views={'new':'old'})
        client.review=dict(shots={'old':dict(id='slot',primary_object_id='copy',definition=old)})
        calls=[]
        def call(name,args):
            calls.append((name,args));actual=copy.deepcopy(old);actual['camera']['distance']=.2;return actual
        client.call=call
        with self.assertRaises(RuntimeError):client.capture_definition('new',{},dict(id='source'),dict(id='copy'),'original',[])
        self.assertEqual([name for name,_ in calls],['form_set_view'])
        self.assertEqual(calls[0][1]['studio_command'],'get')

    def test_portable_archive_is_immutable_and_does_not_rewrite_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            exports=Path(temporary)/'project.form'/'Exports';render=exports/'prior.render';render.mkdir(parents=True)
            client=PaperFollowup.__new__(PaperFollowup)
            client.state=dict(project_id='project');client.review=dict(attempts=[dict(state='completed',record=str(render/'render.json'))])
            calls=[];client.call=lambda name,args:calls.append((name,args)) or dict(id='note');client.save=lambda:None
            value=dict(id='copy',paperConstruction=dict(caliper=1))
            first=client.archive('before-object','edge-1',value)
            path=exports.parent/first['project_file'];original=path.read_bytes()
            self.assertEqual(client.archive('before-object','edge-1',value),first)
            self.assertEqual(len(calls),1)
            changed=copy.deepcopy(value);changed['paperConstruction']['caliper']=2
            second=client.archive('before-object','edge-2',changed)
            self.assertNotEqual(first['project_file'],second['project_file']);self.assertEqual(path.read_bytes(),original)
            path.write_bytes(b'corrupt')
            with self.assertRaises(RuntimeError):client.archive('before-object','edge-1',value)
            self.assertEqual(path.read_bytes(),b'corrupt')

    def test_edge_macro_changes_only_distance_and_keeps_matched_translation(self):
        source=dict(camera=dict(distance=.6,target=dict(x=.5,y=.01,z=2),azimuth=.2,elevation=.1),
            renderSettings=dict(renderer='cycles',samples=64,environmentStrength=.12,
                areaLights=[dict(positionMM=dict(x=100,y=80,z=250),targetMM=dict(x=50,y=1,z=200),powerWatts=.2)]))
        before=copy.deepcopy(source);macro=edge_macro_shot(source)
        self.assertAlmostEqual(macro['camera']['distance'],.2)
        unchanged=copy.deepcopy(macro);unchanged['camera']['distance']=source['camera']['distance']
        self.assertEqual(unchanged,source);self.assertEqual(source,before)
        translated=translated_shot(macro,[170,0,1000],'existing-copy',512,3000,2000)
        self.assertAlmostEqual(translated['camera']['distance'],.2)
        self.assertEqual(translated['camera']['target'],dict(x=2.2,y=.01,z=12))
        self.assertEqual(translated['renderSettings']['areaLights'][0]['positionMM'],dict(x=270,y=80,z=1250))
        self.assertEqual(translated['renderSettings']['environmentStrength'],.12)
        for invalid in (0,-1,math.inf,math.nan):
            bad=copy.deepcopy(source);bad['camera']['distance']=invalid
            with self.assertRaises(ValueError):edge_macro_shot(bad)

    def test_matched_translation_preserves_incidence_and_source(self):
        source=dict(id='saved',camera=dict(target=dict(x=1,y=.4,z=2),azimuth=.3,elevation=.7,distance=.6),
                    renderSettings=dict(renderer='cycles',samples=512,exposure=-.2,environmentStrength=.12,
                        areaLights=[dict(positionMM=dict(x=20,y=180,z=70),targetMM=dict(x=100,y=40,z=200),powerWatts=.1)]),
                    surface='Graphite',referenceAspect=4/3,visibility=dict(mode='objects',objectIDs=['original']),pixels=dict(width=3000,height=2000))
        before=copy.deepcopy(source)
        result=translated_shot(source,[400,0,80],'copy',64,2000,1500)
        self.assertEqual(source,before)
        self.assertEqual(result['camera']['target'],dict(x=5,y=.4,z=2.8))
        light=result['renderSettings']['areaLights'][0]
        for axis in ('x','y','z'):
            self.assertAlmostEqual(light['positionMM'][axis]-light['targetMM'][axis],
                before['renderSettings']['areaLights'][0]['positionMM'][axis]-before['renderSettings']['areaLights'][0]['targetMM'][axis])
        self.assertEqual(result['renderSettings']['exposure'],-.2)
        self.assertEqual(result['visibility']['objectIDs'],['copy'])
        self.assertEqual(result['referenceAspect'],source['referenceAspect'])

    def test_finish_comparison_cannot_change_foil_or_relief_depth(self):
        definition=dict(stock=dict(thicknessMM=1),finishes=[
            dict(id='ink',kind='letterpress',depthMM=.12,heightMM=0),
            dict(id='blind',kind='emboss',depthMM=0,heightMM=.24),
            dict(id='foil',kind='foil',heightMM=.02,appearance=dict(normalStrength=0)),
            dict(id='off',kind='deboss',enabled=False,depthMM=.4)])
        before=copy.deepcopy(definition)
        self.assertEqual(shoulder_patches(definition,.08),[
            dict(id='ink',shoulderRadiusMM=.08),dict(id='blind',shoulderRadiusMM=.08)])
        self.assertEqual(definition,before)
        for invalid in (-.01,math.nan,2.01):
            with self.assertRaises(ValueError):shoulder_patches(definition,invalid)

    def test_edge_only_patch_has_complete_independent_response(self):
        texture=dict(normal=dict(asset='Assets/edge.png',scaleMM=dict(x=8,y=2)))
        patch=edge_patch(texture,.25)
        self.assertEqual(set(patch),{'profile'})
        self.assertEqual(set(patch['profile']),{'edgeAppearance'})
        appearance=patch['profile']['edgeAppearance']
        self.assertEqual(appearance['normalStrength'],.25)
        self.assertEqual(appearance['displacementScaleMM'],0)
        self.assertEqual(appearance['transmission'],0)
        appearance['textures']['normal']['scaleMM']['x']=99
        self.assertEqual(texture['normal']['scaleMM']['x'],8)

    def test_blind_sign_comparison_preserves_magnitude_and_foil(self):
        value=dict(finishes=[dict(id='circle',kind='emboss',heightMM=.12,depthMM=0,shoulderRadiusMM=.08),
                             dict(id='foil',kind='foil',heightMM=.02),dict(id='ink',kind='letterpress',depthMM=.12)])
        before=copy.deepcopy(value)
        self.assertEqual(deboss_patches(value),[dict(id='circle',kind='deboss',heightMM=0,depthMM=.12)])
        self.assertEqual(value,before)
        with self.assertRaises(ValueError):deboss_patches(dict(finishes=[]))

    def test_sequential_finish_retry_resumes_only_an_exact_committed_prefix(self):
        baseline=dict(stock=dict(thicknessMM=1),finishes=[
            dict(id='ink',kind='letterpress',depthMM=.12),
            dict(id='blind',kind='emboss',heightMM=.12),dict(id='foil',kind='foil',heightMM=.02)])
        patches=shoulder_patches(baseline,.08);states=finish_patch_states(baseline,patches)
        owner=dict(id='copy',paperConstruction=copy.deepcopy(states[1]));calls=[]
        client=PaperFollowup.__new__(PaperFollowup)
        def call(name,args):
            calls.append((name,copy.deepcopy(args)))
            self.assertEqual(name,'form_paper')
            self.assertEqual(args['finish'],patches[1])
            owner['paperConstruction']=copy.deepcopy(states[2])
        client.call=call;client.full_object=lambda _:copy.deepcopy(owner)
        result=client.apply_finish_patches(owner,baseline,patches)
        self.assertEqual(len(calls),1);self.assertEqual(result['paperConstruction'],states[2])
        self.assertNotIn('shoulderRadiusMM',baseline['finishes'][0])
        client.apply_finish_patches(result,baseline,patches)
        self.assertEqual(len(calls),1)
        result['paperConstruction']['stock']['thicknessMM']=2
        with self.assertRaises(RuntimeError):client.apply_finish_patches(result,baseline,patches)
        self.assertEqual(len(calls),1)

    def test_procedural_data_is_deterministic_bounded_and_not_dark_grain(self):
        first,metadata=field(128,32,42)
        second,_=field(128,32,42)
        self.assertEqual(first,second)
        self.assertEqual(metadata['physical_repeat_mm'],[8,2])
        self.assertLess(metadata['maximum_slope'],.4)
        self.assertLess(metadata['rms_height_mm'],.002)
        self.assertGreaterEqual(min(first['baseColor']),252)
        self.assertGreaterEqual(min(first['roughness']),249)
        self.assertEqual(len(first['normal']),128*32*3)
        for i in range(0,len(first['normal']),3):
            n=[v/255*2-1 for v in first['normal'][i:i+3]]
            self.assertAlmostEqual(sum(v*v for v in n),1,delta=.012)


if __name__=='__main__':unittest.main()
