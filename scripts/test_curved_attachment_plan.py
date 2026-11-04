import copy
import json
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).parent))
from author_cycles_curved_attachment import SOURCE, plan, patch_update


class CurvedAttachmentPlanTests(unittest.TestCase):
    def controls(self):
        return json.loads((SOURCE/'geometry/curved-embroidery-controls.json').read_text())

    def testCaliperGroundingCylindricalArcAndPhysicalContactOffset(self):
        controls=self.controls();mesh,result=plan(controls)
        p=controls['parent'];radius=p['radius_mm'];baseline=radius*math.cos(p['width_mm']/(2*radius))-p['caliper_mm']/2
        self.assertLessEqual(len(mesh['restPositionsMm']),4096)
        self.assertLessEqual(len(mesh['triangles']),8192)
        self.assertAlmostEqual(min(v['y'] for v in mesh['restPositionsMm']),p['caliper_mm']/2)
        for point,uv,mass in zip(mesh['restPositionsMm'],mesh['uv'],mesh['massesKg']):
            self.assertAlmostEqual(point['x']**2+(point['y']+baseline)**2,radius**2,places=7)
            self.assertGreater(mass,0)
            self.assertAlmostEqual(point['z'],(uv['y']-.5)*p['depth_mm'])
        self.assertEqual(set(mesh['panelIDs']),{0})
        self.assertAlmostEqual(result['normal_offset_mm']-controls['patch']['caliper_mm']/2,p['caliper_mm']/2)
        self.assertGreater(result['maximum_patch_arch_drop_mm'],10)
        self.assertGreater(min(result['panel_margin_mm']),15)
        self.assertAlmostEqual(result['mass_kg'],result['area_mm2']*p['gsm']/1e9,places=12)

    def testRejectsWholePatchLeavingItsPanelAndFoldedOverParent(self):
        for mutate in (lambda c:c['patch'].update(anchor_uv=[.9,.5]),lambda c:c['parent'].update(radius_mm=30)):
            controls=copy.deepcopy(self.controls());mutate(controls)
            with self.assertRaises(ValueError):plan(controls)

    def testResumePreservesVerifiedMaterialAnchorAndNeverSendsWorldPosition(self):
        controls=self.controls();mesh,diagnostic=plan(controls);parent=controls['parent'];patch=controls['patch']
        source={'process':{'threadDiameter':.22,'tieRepeats':1},'regions':[{'method':'fill','spacing':.24}]}
        independent={'id':'patch','textile':{'embroidery':copy.deepcopy(source)}}
        first=patch_update(independent,source,'parent',parent,patch,mesh,diagnostic['normal_offset_mm'])
        self.assertEqual(first['position'],parent['position_mm'])
        target=copy.deepcopy(independent)
        target['clothAttachment']={'surfaceObjectID':'parent','rotationDegrees':20,'anchor':{'triangle':1983,'weights':{'x':0,'y':0,'z':1},'normalOffsetMm':.45}}
        before=copy.deepcopy(target)
        resumed=patch_update(target,source,'parent',parent,patch,mesh,diagnostic['normal_offset_mm'])
        self.assertNotIn('position',resumed);self.assertEqual(resumed['embroidery'],source);self.assertEqual(target,before)
        self.assertEqual(resumed['parameters'],{'width':80,'depth':60,'height':.5})
        for mutate in (lambda t:t['clothAttachment'].update(surfaceObjectID='other'),lambda t:t['clothAttachment'].update(rotationDegrees=21),lambda t:t['clothAttachment']['anchor'].update(normalOffsetMm=.5),lambda t:t['clothAttachment']['anchor'].update(triangle=0)):
            changed=copy.deepcopy(target);mutate(changed)
            with self.assertRaises(ValueError):patch_update(changed,source,'parent',parent,patch,mesh,diagnostic['normal_offset_mm'])


if __name__=='__main__':unittest.main()
