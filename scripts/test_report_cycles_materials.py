import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import sys

spec = importlib.util.spec_from_file_location('report_cycles_materials', Path(__file__).with_name('report_cycles_materials.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
sys.path.insert(0,str(Path(__file__).parent))
import report_cycles_optics as optics


class MaterialReviewReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lab-material-report-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'Moved.form'
        self.state = {'project_id': 'p', 'cases': {'cotton': {'render_attempts': []}}}
        for view in report.VIEWS:
            folder = self.project / 'Exports' / (view + '.render')
            folder.mkdir(parents=True)
            png = folder / 'image.png'
            png.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
            (folder / 'render.json').write_text('{"renderer":"test fixture"}')
            self.state['cases']['cotton']['render_attempts'].append(dict(view=view, attempt=1, state='completed', png='/old/package/' + view + '.png',
                project_files={'png': 'Exports/' + folder.name + '/image.png', 'record': 'Exports/' + folder.name + '/render.json'}))
        self.observations = report.prepare_observations(self.state, {'version': 1, 'project_id': 'p', 'rounds': []}, self.project)
        self.corpus = {'cases': [{'id': 'cotton', 'title': 'Test case', 'photo_url': 'https://example.com/original.jpg', 'source_url': 'https://example.com/source',
            'spec_url': 'https://example.com/spec', 'specification': 'Explicit test fixture', 'geometry_variants': ['First', 'Second'], 'review': ['Inspect actual output']}]}

    def reviewed(self):
        value = copy.deepcopy(self.observations)
        for review in value['rounds']:
            review.update(outcome='accepted', reviewer='Unit-test reviewer', observations=['Explicit fixture review text'],
                          reference_urls=['https://example.com/original.jpg'], variant_indices=[0, 1])
        return value

    def testSuccessAloneNeverAcceptsAndReportIsPortableWithoutRemotePhotoCopies(self):
        output = self.root / 'standalone/index.html'
        summary = report.build_report(self.corpus, self.state, self.observations, output, self.project)
        self.assertEqual(summary['accepted_cases'], 0)
        body = output.read_text()
        self.assertIn('No visual observations', body) if not self.observations['rounds'] else self.assertIn('Recorded review:', body)
        self.assertIn('href="https://example.com/original.jpg"', body)
        self.assertNotIn('src="https://example.com', body)
        self.assertNotIn('/old/package/', body)
        self.assertTrue(list((output.parent / 'assets').glob('*.png')))
        self.assertTrue(list((output.parent / 'assets').glob('*.json')))

    def testAcceptanceRequiresExactPixelsAllViewsAndBothVariants(self):
        explicit = self.reviewed()
        reviews = report.validate_observations(self.state, explicit, self.project)
        self.assertEqual(report.case_status('cotton', report.attempts(self.state), reviews), 'accepted')
        one_variant = copy.deepcopy(explicit)
        for item in one_variant['rounds']:
            item['variant_indices'] = [0]
        reviews = report.validate_observations(self.state, one_variant, self.project)
        self.assertEqual(report.case_status('cotton', report.attempts(self.state), reviews), 'pending')
        for field, value in [('source_png_sha256', 'b' * 64), ('observations', []), ('reference_urls', []), ('reviewer', ''), ('discrepancies', ['Still wrong'])]:
            invalid = copy.deepcopy(explicit)
            invalid['rounds'][0][field] = value
            with self.assertRaises(ValueError):
                report.validate_observations(self.state, invalid, self.project)

    def testNewFailureRemainsVisibleAndInvalidatesOlderAcceptance(self):
        explicit = self.reviewed()
        self.state['cases']['cotton']['render_attempts'].append({'view': 'whole', 'attempt': 2, 'state': 'failed', 'failure': 'Actual helper failure'})
        output = self.root / 'report/index.html'
        summary = report.build_report(self.corpus, self.state, explicit, output, self.project)
        self.assertEqual(summary['cases']['cotton'], 'failed')
        self.assertIn('Actual helper failure', output.read_text())
        self.assertIn('Attempt 1', output.read_text())
        self.assertIn('Attempt 2', output.read_text())
        appended = report.prepare_observations(self.state, copy.deepcopy(explicit), self.project)
        self.assertEqual(appended['rounds'][:3], explicit['rounds'])
        self.assertEqual(appended['rounds'][-1]['outcome'], 'pending')
        self.assertEqual(appended['rounds'][-1]['observations'], [])

    def testOpticalControlReviewsNeedExactPixelsAndDoNotAcceptMaterialCases(self):
        self.state['diagnostics']={'reflection control':{'render_attempts':[copy.deepcopy(self.state['cases']['cotton']['render_attempts'][0])]}}
        value=optics.prepare(self.state,{},self.project)
        self.assertEqual(value['rounds'][0]['outcome'],'pending')
        value['rounds'][0].update(outcome='passed',reviewer='Unit-test reviewer',observations=['Explicit fixture comparison'])
        optics.validate(self.state,value,self.project)
        summary=report.build_report(self.corpus,self.state,self.observations,self.root/'report/index.html',self.project)
        self.assertEqual(summary['accepted_cases'],0)
        value['rounds'][0]['source_png_sha256']='a'*64
        with self.assertRaises(ValueError):optics.validate(self.state,value,self.project)


if __name__ == '__main__':
    unittest.main()
