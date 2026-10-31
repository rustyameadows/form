#!/usr/bin/env python3
"""Pure data checks; no native app, library access, or renderer is launched."""
import copy
import unittest

from create_dispatch_studio_examples import alternate_artwork, bounds, scene_definitions


class DispatchStudioDataTests(unittest.TestCase):
    def setUp(self):
        self.a = dict(id='A', name='Dispatch A')
        self.b = dict(id='B', name='Dispatch B')
        self.height = 163.2

    def testAlignedStacksAreFiveRegularOccurrencesOfOneDesignWithUniqueIdentity(self):
        scenes = scene_definitions(self.a, self.b, self.height, 0)
        for _, instances, _ in scenes[:3]:
            self.assertEqual(len(instances), 5)
            self.assertEqual(len({i['id'] for i in instances}), 5)
            self.assertEqual(len({i['sourceObjectID'] for i in instances}), 1)
            self.assertEqual({(i['positionMM']['x'], i['positionMM']['z'], i['rotationDegrees']) for i in instances}, {(0, 0, 0)})
            for index, instance in enumerate(instances):
                self.assertAlmostEqual(instance['positionMM']['y'], index * self.height)
        self.assertEqual(scenes[0][1], scenes[1][1])
        self.assertNotEqual(scenes[0][2], scenes[1][2])
        self.assertEqual({i['sourceObjectID'] for i in scenes[2][1]}, {'B'})

    def testOffsetClusterRetainsVerticalContactWithoutChangingDesignSources(self):
        before = copy.deepcopy((self.a, self.b))
        _, instances, _ = scene_definitions(self.a, self.b, self.height, 0)[3]
        self.assertEqual(len({i['sourceObjectID'] for i in instances}), 1)
        self.assertGreater(len({i['rotationDegrees'] for i in instances}), 1)
        self.assertGreater(len({i['positionMM']['x'] for i in instances}), 1)
        for first, second in zip(instances, instances[1:]):
            self.assertAlmostEqual(first['positionMM']['y'] + self.height, second['positionMM']['y'])
        self.assertEqual((self.a, self.b), before)

    def testAlternateArtworkKeepsCanonicalIdentityWithAnIndependentNewComposition(self):
        source = dict(artwork=dict(background='#FFFFFF', backgroundOpacity=0, bleed=3, elements=[
            dict(id='front', kind='text', name='01-outside-front-title', text='Dispatch', color='#25392E', x=20, y=30),
            dict(id='back', kind='text', name='01-outside-back-brand', text='FIELD / 01', color='#25392E', x=400, y=30),
        ]))
        before = copy.deepcopy(source)
        art = alternate_artwork(source)
        self.assertEqual(source, before)
        self.assertEqual(art['background'], '#21478D')
        self.assertEqual(art['backgroundOpacity'], 1)
        self.assertEqual([e['id'] for e in art['elements']], ['front', 'back'])
        self.assertNotEqual([(e['x'], e['y']) for e in art['elements']], [(20, 30), (400, 30)])
        self.assertEqual(art['elements'][0]['text'], 'NIGHT\nSHIFT')
        self.assertEqual(art['elements'][0]['typography']['fontName'], 'HelveticaNeue-Bold')
        self.assertEqual(art['elements'][0]['height'], 82)
        self.assertEqual(art['elements'][1]['text'], 'DISPATCH  /  B')
        self.assertEqual({e['color'] for e in art['elements']}, {'#F4EBD8'})

    def testBoundsIncludeCaliperAndGroundOffsetIsAppliedToAllOccurrences(self):
        low, high = bounds([[-131.6, -1.6, -91.6], [131.6, 161.6, 91.6]])
        height = high[1] - low[1]
        instances = scene_definitions(self.a, self.b, height, -low[1])[0][1]
        self.assertAlmostEqual(instances[0]['positionMM']['y'] + low[1], 0)
        self.assertAlmostEqual(instances[-1]['positionMM']['y'] + high[1], 5 * height)


if __name__ == '__main__':
    unittest.main()
