import copy
import math
import unittest

from author_cycles_paper_followup import deboss_patches, edge_patch, shoulder_patches, translated_shot
from prepare_cycles_paper_edges import field


class PaperFollowupPlanTests(unittest.TestCase):
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
