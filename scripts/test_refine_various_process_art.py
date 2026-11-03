"""Offline source-registration and ink-safety checks; no native app calls."""
import copy
import json
from pathlib import Path
import unittest

import refine_various_process_art as subject

ROOT=Path(__file__).resolve().parent.parent
REPORT=ROOT/'.local/validation/publications/various-assets-round2/visual-authoring-report.json'


@unittest.skipUnless(REPORT.exists(),'Retained native source evidence is required for this authoring-data check.')
class SourceDerivedTechnicalDrawingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.sources=json.loads(REPORT.read_text())['sources']

    def test_cup_plan_uses_actual_off_center_cavity_and_three_distinct_views(self):
        definition=self.sources['matter_study_05']['source_definition']
        front,side,plan=subject.cup_views(definition)
        center=lambda points:(min(p[0] for p in points)+max(p[0] for p in points))/2
        self.assertAlmostEqual(center(plan[0]),-10)
        self.assertAlmostEqual(center(plan[1]),-14)
        self.assertNotEqual(front,side);self.assertNotEqual(side,plan)
        art=subject.artwork_from_lines('matter_study_08',*subject.clay_lines('matter_study_08',definition))
        self.assertEqual(art['source_size_mm'],{'x':100,'y':28})
        self.assertIn('FRONT / SIDE / PLAN',art['elements'][-1]['text'])

    def test_bowl_section_retains_real_floor_and_has_no_artificial_center_seam(self):
        lines,_=subject.clay_lines('matter_study_03',self.sources['matter_study_03']['source_definition'])
        self.assertEqual(len(lines),1)
        self.assertIn((36,-6),lines[0]);self.assertIn((-36,-6),lines[0])
        self.assertNotIn((0,0),lines[0]);self.assertNotIn((0,-6),lines[0])
        self.assertEqual(lines[0][0],lines[0][-1])

    def test_native_proven_long_notes_fit_without_changing_words_frame_or_other_sizes(self):
        lines=[[(0,0),(20,30)]]
        for text in ('PARAMETER WIREFRAME / BEVELS OMITTED','WINDOW REFERENCE / TOP LIMB SECTION'):
            note=subject.artwork_from_lines('example',lines,text)['elements'][-1]
            self.assertEqual(note['text'],text)
            self.assertEqual((note['x'],note['y'],note['width'],note['height']),(8,94,90,6))
            self.assertEqual(note['fontSize'],10)
            self.assertAlmostEqual(note['typography']['leading'],11.6)
        short=subject.artwork_from_lines('example',lines,'DIAMETRAL SECTION')['elements'][-1]
        folded=subject.artwork_from_lines('example',lines,'NATIVE FOLDED STOCK / NOMINAL EDGES')['elements'][-1]
        wide=subject.artwork_from_lines('matter_study_08',lines,'FRONT / SIDE / PLAN — SAME SCALE')['elements'][-1]
        self.assertEqual(short['fontSize'],12);self.assertEqual(folded['fontSize'],12);self.assertEqual(wide['fontSize'],8)

    def test_derived_diagrams_are_black_editable_finite_and_register_to_native_corners(self):
        fold=self.sources['fold_bureau_01'];wire=subject.fold_wire(fold)
        self.assertEqual(wire[0][0],subject.project(fold['points'][0]))
        original=copy.deepcopy(fold)
        for source_key in ('index_works_01','index_works_02','index_works_04','common_current_03'):
            lines=subject.recipe_wire(self.sources[source_key]['source_definition'])
            drawing=subject.artwork_from_lines(source_key,lines,'NOMINAL PARAMETER WIREFRAME')
            for element in drawing['elements']:
                self.assertIn(element['kind'],('text','path'))
                self.assertEqual(element['color'],'#000000')
                self.assertFalse(any(element.get(k) for k in ('image','objectView','gradient','paintStack','effectStack','shadow')))
                if element.get('stroke'):self.assertEqual(element['stroke']['color'],'#000000')
                for contour in element.get('path',{}).get('contours',[]):
                    for node in contour['nodes']:
                        self.assertTrue(0<=node['anchor']['x']<=100)
                        self.assertTrue(0<=node['anchor']['y']<=100)
        self.assertEqual(original,fold)


if __name__=='__main__':unittest.main()
