#!/usr/bin/env python3
"""Author-side regression checks; native validation remains strict and authoritative."""
import copy
import unittest
import generate_starter as source

class StarterAuthoringTests(unittest.TestCase):
 def test_independent_board_variant_updates_owner_fallback_without_replacing_piece_stocks(self):
  original=source.build()
  changed=source.with_values(original,dict(linkedBoards=0,bFloorMM=2.8,lFloorMM=1.6))
  self.assertEqual(changed['stock']['thicknessMM'],2.8)
  self.assertEqual(original['stock']['thicknessMM'],2)
  self.assertEqual(changed['stock']['profile'],original['stock']['profile'])
  self.assertEqual([q['stock'] for q in changed['definition']['components']],
                   [q['stock'] for q in original['definition']['components']])
  source.validate(changed)
  invalid=copy.deepcopy(changed);invalid['stock']=copy.deepcopy(original['stock'])
  with self.assertRaisesRegex(AssertionError,'owner-stock-caliper'):source.validate(invalid)

 def test_root_caliper_edit_preserves_bonded_ply_ratio_ids_and_profiles(self):
  original=source.build()
  original['stock']['plies']=[dict(id=source.uid('test/back'),name='Back',color='#E0D7C1',thicknessMM=.5),
                            dict(id=source.uid('test/front'),name='Face',color='#8B887D',thicknessMM=1.5,profile=source.profile('#8B887D'))]
  changed=source.with_values(original,dict(linkedBoards=0,bFloorMM=3))
  self.assertEqual(changed['stock']['thicknessMM'],3)
  self.assertEqual([q['thicknessMM'] for q in changed['stock']['plies']],[.75,2.25])
  self.assertEqual([q['id'] for q in changed['stock']['plies']],[q['id'] for q in original['stock']['plies']])
  self.assertEqual(changed['stock']['plies'][1]['profile'],original['stock']['plies'][1]['profile'])
  self.assertEqual([q['thicknessMM'] for q in original['stock']['plies']],[.5,1.5])
  source.validate(changed)

if __name__=='__main__':unittest.main()
