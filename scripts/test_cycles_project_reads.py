import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from author_cycles_materials import protected_signature
from cycles_project_reads import ProjectReader, ProjectReadRevisionChanged


class PublicReadFixture:
    """Different page widths model byte-budget truncation, not just limit=64."""
    def __init__(self):
        self.project = dict(id='project', name='Ordinary project', camera={'azimuth': .7},
                            conversationReference='unique interrupted-create marker',
                            objects=[dict(id='object-'+str(i), name='Object '+str(i), cloth={'mesh': {'restPositionsMm': [i, i+1]}}) for i in range(5)],
                            materials=[{'id': 'material'}], recipes=[{'id': 'recipe', 'parameters': [1, 2]}],
                            notes=[{'text': 'note '+str(i)} for i in range(4)])
        self.revision = 'session:1'
        self.calls = []
        self.transform = None

    def call(self, name, args):
        self.calls.append((name, copy.deepcopy(args)))
        if name not in ('form_get_project', 'form_open_project') or args.get('view') not in ('summary', 'scoped'):
            raise AssertionError('Unexpected unbounded operation')
        if name == 'form_open_project':
            if args['project_id'] != self.project['id']:
                raise AssertionError('Wrong explicit target')
            if 'expected_revision' in args:
                raise AssertionError('Open must not send a stale project revision')
        elif 'expected_revision' in args and args['expected_revision'] != self.revision:
            raise ProjectReadRevisionChanged('Project read revision changed')
        section = 'objects' if args['view'] == 'summary' else args['sections'][0]
        records = copy.deepcopy(self.project[section])
        if args['view'] == 'summary':
            records = [dict(id=o['id'], name=o['name'], details_complete=False) for o in records]
        start = args.get('offset', 0)
        width = 2 if section == 'objects' else 1
        returned = records[start:start+width]
        end = start+len(returned)
        result = dict(view=args['view'], revision=self.revision,
                      project={k: copy.deepcopy(self.project[k]) for k in ('id', 'name', 'camera', 'conversationReference')},
                      sections={section: returned},
                      pages={section: dict(offset=start, limit=64, returned=len(returned), total=len(records),
                                           has_more=end < len(records), next_offset=end if end < len(records) else None,
                                           complete=start == 0 and end == len(records))},
                      response_complete=False, object_count=len(self.project['objects']), selected_object_count=len(self.project['objects']))
        return self.transform(result) if self.transform else result


class ProjectReaderTests(unittest.TestCase):
    def testByteLimitedIndependentPagesAssembleExactProtectedFields(self):
        fixture = PublicReadFixture()
        snapshot = ProjectReader(fixture.call).open('project', protect=True)
        self.assertEqual(protected_signature(snapshot), protected_signature(fixture.project))
        self.assertEqual(snapshot['conversationReference'], fixture.project['conversationReference'])
        self.assertTrue(snapshot['_project_read']['object_details_complete'])
        self.assertTrue(any(a.get('offset') == 4 for _, a in fixture.calls))
        for name, args in fixture.calls[1:]:
            self.assertEqual(args['expected_revision'], 'session:1')
            self.assertEqual(name, 'form_get_project')

    def testLightweightInventoryIsCompleteButCannotProtectDenseObjectContents(self):
        fixture = PublicReadFixture()
        snapshot = ProjectReader(fixture.call).snapshot()
        self.assertEqual(len(snapshot['objects']), 5)
        self.assertNotIn('cloth', snapshot['objects'][0])
        self.assertEqual(snapshot['notes'], fixture.project['notes'])
        with self.assertRaisesRegex(RuntimeError, 'complete scoped records'):
            protected_signature(snapshot)

    def testRevisionChangeAndInconsistentCursorRejectWithoutPartialSnapshot(self):
        fixture = PublicReadFixture()
        ordinary = fixture.call
        def changed(name, args):
            if len(fixture.calls) == 1:
                fixture.revision = 'session:2'
            return ordinary(name, args)
        with self.assertRaisesRegex(RuntimeError, 'revision changed'):
            ProjectReader(changed).snapshot()
        fixture = PublicReadFixture()
        def stalled(response):
            response['pages']['objects']['next_offset'] = 0
            return response
        fixture.transform = stalled
        with self.assertRaisesRegex(RuntimeError, 'inconsistent project page'):
            ProjectReader(fixture.call).snapshot()

    def testIdentityChangeAndSilentCountTruncationReject(self):
        for field in ('identity', 'count'):
            with self.subTest(field=field):
                fixture = PublicReadFixture()
                def corrupt(response):
                    if len(fixture.calls) > 1 and field == 'identity':
                        response['project']['id'] = 'unrelated-project'
                    elif field == 'count':
                        response['object_count'] = 6
                    return response
                fixture.transform = corrupt
                with self.assertRaises(RuntimeError):
                    ProjectReader(fixture.call).snapshot()

    def testAdditionalScalarUsesTheSameRevisionAndRequiresExplicitCompleteness(self):
        fixture = PublicReadFixture()
        scalar = {'shots': [{'id': 'editable-shot', 'camera': {'distance': 4}}]}
        def call(name, args):
            if args.get('sections') == ['studioPresentation']:
                self.assertEqual(args['expected_revision'], fixture.revision)
                reference = fixture.call('form_get_project', dict(view='summary', expected_revision=fixture.revision))
                reference.update(view='scoped', sections={'studioPresentation': scalar},
                                 pages={'studioPresentation': {'kind': 'scalar', 'complete': True}})
                return reference
            return fixture.call(name, args)
        snapshot = ProjectReader(call).snapshot(protect=True, scalar_sections=('studioPresentation',))
        self.assertEqual(snapshot['studioPresentation'], scalar)
        self.assertIn('studioPresentation', snapshot['_project_read']['complete_sections'])
        self.assertEqual(protected_signature(snapshot), protected_signature(fixture.project))
        with self.assertRaisesRegex(RuntimeError, 'complete scalar'):
            ProjectReader(fixture.call).snapshot(scalar_sections=('recipes',))

    def testOpenRestartsWholeSnapshotAfterNativeRevisionChangeWithoutReopening(self):
        fixture=PublicReadFixture();ordinary=fixture.call
        def changed(name,args):
            if len(fixture.calls)==1:
                fixture.revision='session:2'
                fixture.project['objects'][0]['cloth']['mesh']['restPositionsMm']=[100,101]
            return ordinary(name,args)
        snapshot=ProjectReader(changed).open('project',protect=True)
        self.assertEqual(protected_signature(snapshot),protected_signature(fixture.project))
        self.assertEqual(snapshot['_project_read']['revision'],'session:2')
        self.assertEqual(sum(name=='form_open_project' for name,_ in fixture.calls),1)
        self.assertTrue(any(name=='form_get_project' and args.get('view')=='summary' and 'expected_revision' not in args for name,args in fixture.calls))

    def testOpenRetryNeverFollowsAnUnrelatedProject(self):
        fixture=PublicReadFixture();ordinary=fixture.call
        def changed(name,args):
            if len(fixture.calls)==1:
                fixture.revision='session:2';fixture.project['id']='unrelated'
            return ordinary(name,args)
        with self.assertRaisesRegex(RuntimeError,'explicit target'):
            ProjectReader(changed).open('project',protect=True)

    def testOpenMidReadRestartDiscardsEarlierObjectAndNotePages(self):
        fixture=PublicReadFixture();ordinary=fixture.call;changed_once=False
        def changed(name,args):
            nonlocal changed_once
            if not changed_once and args.get('sections')==['notes'] and args.get('offset')==1:
                changed_once=True;fixture.revision='session:2'
                fixture.project['objects'][0]['cloth']['mesh']['restPositionsMm']=[333,334]
                fixture.project['notes'][0]['text']='Changed after the previous note page'
            return ordinary(name,args)
        snapshot=ProjectReader(changed).open('project',protect=True)
        self.assertEqual(protected_signature(snapshot),protected_signature(fixture.project))
        object_starts=[a for _,a in fixture.calls if a.get('sections')==['objects'] and a.get('offset')==0]
        self.assertEqual([a['expected_revision'] for a in object_starts],['session:1','session:2'])

    def testOpenRetryExhaustsAndDoesNotRetryArbitraryErrors(self):
        fixture=PublicReadFixture();ordinary=fixture.call;serial=1
        def unstable(name,args):
            nonlocal serial
            if 'expected_revision' in args:
                serial+=1;fixture.revision='session:'+str(serial)
            return ordinary(name,args)
        with self.assertRaises(ProjectReadRevisionChanged):ProjectReader(unstable).open('project',protect=True)
        self.assertEqual(sum('expected_revision' in args for _,args in fixture.calls),3)
        fixture=PublicReadFixture();ordinary=fixture.call
        def unrelated_error(name,args):
            if 'expected_revision' in args:raise RuntimeError('Project read revision changed words embedded in a different failure')
            return ordinary(name,args)
        with self.assertRaisesRegex(RuntimeError,'different failure'):ProjectReader(unrelated_error).open('project',protect=True)
        self.assertEqual(len(fixture.calls),1)


if __name__ == '__main__':
    unittest.main()
