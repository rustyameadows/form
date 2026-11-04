import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from verify_cycles_app import Check, verify_runtime_provenance


class BoundedProjectFixture:
    def __init__(self):
        self.project = dict(id='review', name='Review', camera={'azimuth': .7},
                            objects=[{'id': str(i), 'cloth': {'mesh': {'restPositionsMm': [i, i+.5]}}} for i in range(3)],
                            materials=[{'id': 'cotton', 'roughness': .8}], recipes=[{'id': 'surface'}],
                            notes=[{'text': 'First'}, {'text': 'Second'}],
                            studioPresentation={'shots': [{'id': 'shot', 'visibleObjectIDs': ['0', '1', '2']}]})
        self.calls = []
        self.revision = 'session:1'
        self.transform = None

    def call(self, name, arguments):
        self.calls.append((name, copy.deepcopy(arguments)))
        if name not in ('form_get_project', 'form_open_project') or arguments.get('view') not in ('summary', 'scoped'):
            raise AssertionError('An unbounded or mutating operation was attempted')
        if name == 'form_open_project':
            if 'expected_revision' in arguments:
                raise AssertionError('Open cannot use the previous project revision')
            self.project['id'] = arguments['project_id']
        if 'expected_revision' in arguments and arguments['expected_revision'] != self.revision:
            raise RuntimeError('Project read revision changed')
        section = 'objects' if arguments['view'] == 'summary' else arguments['sections'][0]
        value = copy.deepcopy(self.project[section])
        if section == 'objects' and arguments['view'] == 'summary':
            value = [{'id': item['id'], 'details_complete': False} for item in value]
        if isinstance(value, list):
            offset = arguments.get('offset', 0)
            rows = value[offset:offset+1]  # Byte packing may shorten every page below limit.
            end = offset+len(rows)
            page = dict(offset=offset, returned=len(rows), total=len(value), has_more=end < len(value),
                        next_offset=end if end < len(value) else None, complete=offset == 0 and end == len(value))
            value = rows
        else:
            page = dict(kind='scalar', complete=True)
        response = dict(view=arguments['view'], revision=self.revision,
                        project={key: copy.deepcopy(self.project[key]) for key in ('id', 'name', 'camera')},
                        response_complete=False, sections={section: value}, pages={section: page},
                        object_count=len(self.project['objects']), selected_object_count=len(self.project['objects']))
        return self.transform(response) if self.transform else response

    def check(self):
        value = Check.__new__(Check)
        value.call = self.call
        return value


class LifecycleProjectReadTests(unittest.TestCase):
    def testProtectedSnapshotRetainsExactDenseObjectsAndStudioAcrossShortPages(self):
        fixture = BoundedProjectFixture()
        snapshot = fixture.check().protected_project()
        for key in ('objects', 'materials', 'recipes', 'notes', 'camera', 'studioPresentation'):
            self.assertEqual(snapshot[key], fixture.project[key], key)
            self.assertIn(key, snapshot['_project_read']['complete_sections'])
        self.assertTrue(snapshot['_project_read']['object_details_complete'])
        for name, arguments in fixture.calls[1:]:
            self.assertEqual(name, 'form_get_project')
            self.assertEqual(arguments['expected_revision'], 'session:1')
        self.assertTrue(any(arguments.get('offset') == 2 for _, arguments in fixture.calls))

    def testProtectedStudioRejectsChangedRevisionOrIncompleteScalar(self):
        for failure in ('revision', 'incomplete'):
            with self.subTest(failure=failure):
                fixture = BoundedProjectFixture()
                def corrupt(response):
                    if 'studioPresentation' in response['sections']:
                        if failure == 'revision':
                            response['revision'] = 'session:2'
                        else:
                            response['pages']['studioPresentation']['complete'] = False
                    return response
                fixture.transform = corrupt
                with self.assertRaises(RuntimeError):
                    fixture.check().protected_project()

    def testIdentityChecksAndSwitchesUseOnlySummary(self):
        fixture = BoundedProjectFixture()
        check = fixture.check()
        self.assertEqual(check.current_project_id(), 'review')
        check.open_project('other')
        self.assertEqual(check.current_project_id(), 'other')
        check.open_project('review')
        self.assertEqual(check.current_project_id(), 'review')
        self.assertEqual(len(fixture.calls), 5)
        for _, arguments in fixture.calls:
            self.assertEqual(arguments['view'], 'summary')
            self.assertEqual(arguments['limit'], 1)
            self.assertNotIn('expected_revision', arguments)

    def testOpenRejectsMismatchedTargetIdentity(self):
        fixture = BoundedProjectFixture()
        def wrong_target(response):
            response['project']['id'] = 'unexpected'
            return response
        fixture.transform = wrong_target
        with self.assertRaisesRegex(RuntimeError, 'explicit target'):
            fixture.check().open_project('other')


class ExportRuntimeProvenanceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cycles-export-identity-')
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / 'Ordinary.app'
        self.files = {
            'Contents/MacOS/LAB': b'actual signed app',
            'Contents/Helpers/lab-cycles-render': b'actual signed helper',
            'Contents/Resources/LABBuild.json': json.dumps(dict(format_version=1, build_id='sha256:build', app_pre_package_signing_sha256='different-before-signing')).encode(),
            'Contents/Resources/Cycles/LAB-sRGB-v1.json': json.dumps(dict(id='LAB-sRGB-v1', loadedByRenderer=False)).encode()}
        engine = dict(source_commit='same-pinned-cycles', dependency_commit='dependencies', protocol_version=1,
                      source_inputs={'Native/LabCycles/LAB-sRGB-v1.json': hashlib.sha256(self.files['Contents/Resources/Cycles/LAB-sRGB-v1.json']).hexdigest()})
        self.files['Contents/Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json'] = json.dumps(engine).encode()
        for relative, data in self.files.items():
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        def identity(relative):
            data = self.files[relative]
            return dict(sha256=hashlib.sha256(data).hexdigest(), size_bytes=len(data))
        build = identity('Contents/Resources/LABBuild.json')
        build.update(status='available', metadata=json.loads(self.files['Contents/Resources/LABBuild.json']))
        provenance = identity('Contents/Resources/ThirdPartyNotices/Cycles/LAB-CYCLES-PROVENANCE.json')
        provenance.update(status='available', source_commit=engine['source_commit'], dependency_commit=engine['dependency_commit'], protocol_version=1)
        display = identity('Contents/Resources/Cycles/LAB-sRGB-v1.json')
        display.update(status='available', id='LAB-sRGB-v1')
        self.record = dict(engine_revision=engine['source_commit'], display_transform='LAB-sRGB-v1', runtime_provenance=dict(version=1,
            application=dict(executable=identity('Contents/MacOS/LAB'), packaged_build=build),
            renderer=dict(helper=identity('Contents/Helpers/lab-cycles-render'), engine_provenance=provenance, display_transform=display)))

    def testExactSignedIdentitiesRemainDistinctFromPrePackageMetadata(self):
        result = verify_runtime_provenance(self.record, self.app)
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(result['app_sha256'], hashlib.sha256(b'actual signed app').hexdigest())
        self.assertEqual(result['packaged_build_id'], 'sha256:build')

    def testChangedHelperRejectsEvenWithTheSameUpstreamEngineRevision(self):
        (self.app / 'Contents/Helpers/lab-cycles-render').write_bytes(b'new helper, same Cycles pin')
        with self.assertRaisesRegex(AssertionError, 'runtime binary differs'):
            verify_runtime_provenance(self.record, self.app)

    def testInstalledMissingMetadataAndIncorrectTransformIdentityReject(self):
        bad = copy.deepcopy(self.record)
        bad['runtime_provenance']['application']['packaged_build']['status'] = 'unavailable'
        with self.assertRaisesRegex(AssertionError, 'Installed metadata'):
            verify_runtime_provenance(bad, self.app)
        bad = copy.deepcopy(self.record)
        bad['runtime_provenance']['renderer']['display_transform']['sha256'] = 'invented'
        with self.assertRaisesRegex(AssertionError, 'metadata differs'):
            verify_runtime_provenance(bad, self.app)


if __name__ == '__main__':
    unittest.main()
